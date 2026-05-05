//! Auto-updater module for Tillandsias.
//!
//! Provides silent background update checks on app launch (after a 5-second
//! delay) and periodic checks at a configurable interval (default 6 hours).
//! Uses Tauri's built-in updater plugin with mandatory Ed25519 signature
//! verification. Never blocks the main event loop or the tray UI thread.
//!
//! @trace spec:update-system, spec:download-telemetry

use std::sync::Arc;

use tauri::AppHandle;
use tauri_plugin_updater::UpdaterExt;
use tillandsias_core::config::load_global_config;
use tillandsias_podman::PodmanClient;
use tokio::sync::Mutex;
use tracing::{debug, error, info, warn};

use crate::update_log;

/// Shared state for tracking whether an update is available across tray
/// menu rebuilds and user interactions.
#[derive(Debug, Clone)]
pub struct UpdateState {
    /// The new version string (e.g., "0.2.0") when an update is available.
    pub available_version: Arc<Mutex<Option<String>>>,
    /// Whether an update download/install is currently in progress.
    pub in_progress: Arc<Mutex<bool>>,
}

impl Default for UpdateState {
    fn default() -> Self {
        Self {
            available_version: Arc::new(Mutex::new(None)),
            in_progress: Arc::new(Mutex::new(false)),
        }
    }
}

/// Spawn the background update check tasks. Called once during app setup.
///
/// This spawns two async tasks:
/// 1. A one-shot check after a 5-second post-startup delay (if `check_on_launch` is true).
/// 2. A periodic check at the configured interval (default 6 hours).
///
/// Both tasks run entirely in the background and never block the UI.
// @trace spec:update-system
pub fn spawn_update_tasks(app: &AppHandle, update_state: UpdateState) {
    let config = load_global_config();
    let updates_config = config.updates;

    // Task 1: Initial check after startup delay
    if updates_config.check_on_launch {
        let app_handle = app.clone();
        let state = update_state.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            check_for_update(&app_handle, &state).await;
        });
    }

    // Task 2: Periodic check
    let app_handle = app.clone();
    let state = update_state;
    let interval_hours = updates_config.check_interval_hours.max(1);
    tauri::async_runtime::spawn(async move {
        let interval = std::time::Duration::from_secs(interval_hours * 3600);
        loop {
            tokio::time::sleep(interval).await;
            check_for_update(&app_handle, &state).await;
        }
    });
}

/// Perform a single update check. Errors are caught and logged without
/// surfacing any dialogs to the user.
async fn check_for_update(app: &AppHandle, state: &UpdateState) {
    debug!("Checking for updates...");

    let updater = match app.updater() {
        Ok(updater) => updater,
        Err(e) => {
            warn!(error = %e, "Failed to get updater handle");
            return;
        }
    };

    let update = match updater.check().await {
        Ok(Some(update)) => update,
        Ok(None) => {
            debug!("No update available");
            return;
        }
        Err(e) => {
            // Silent failure: network errors, DNS failures, rate limits, etc.
            debug!(error = %e, "Update check failed (will retry at next interval)");
            return;
        }
    };

    let new_version = update.version.clone();
    info!(version = %new_version, "Update available");

    // Store the available version for tray menu display
    {
        let mut version = state.available_version.lock().await;
        if version.as_deref() == Some(new_version.as_str()) {
            // Already notified about this version during this session
            return;
        }
        *version = Some(new_version.clone());
    }

    // Audit log: background updater detected a new version.
    let current = env!("CARGO_PKG_VERSION");
    update_log::append_entry(&format!(
        "UPDATE CHECK: v{current} \u{2192} v{new_version} available (background)"
    ));

    // Fire a system notification on first detection
    send_update_notification(app, &new_version);
}

/// Send a platform-native system notification about the available update.
fn send_update_notification(app: &AppHandle, version: &str) {
    use tauri::Emitter;
    // Emit an event that the tray menu builder can listen to for rebuilding.
    // Also attempt a system notification via the app's event system.
    if let Err(e) = app.emit("update-available", version) {
        warn!(error = %e, "Failed to emit update-available event");
    }
    info!(version, "Emitted update-available notification");
}

/// Install an available update. Called when the user clicks the tray menu item.
///
/// This function:
/// 1. Checks if containers are running and stops them gracefully.
/// 2. Downloads and installs the update (signature is verified by the plugin).
/// 3. Restarts the application.
///
/// On failure (e.g., network loss mid-download), the tray menu reverts to
/// showing "Update available" so the user can retry.
// @trace spec:update-system
#[allow(dead_code)]
pub async fn install_update(app: &AppHandle, state: &UpdateState) {
    // Guard against duplicate installs
    {
        let mut in_progress = state.in_progress.lock().await;
        if *in_progress {
            debug!("Update already in progress, ignoring duplicate request");
            return;
        }
        *in_progress = true;
    }

    // Emit progress event for tray menu
    if let Err(e) = tauri::Emitter::emit(app, "update-downloading", ()) {
        warn!(error = %e, "Failed to emit update-downloading event");
    }

    // Step 1: Stop all managed containers gracefully
    if let Err(e) = stop_all_containers().await {
        warn!(error = %e, "Some containers may not have stopped cleanly");
    }

    // Step 2: Download and install
    let updater = match app.updater() {
        Ok(u) => u,
        Err(e) => {
            error!(error = %e, "Failed to get updater handle for install");
            reset_progress(app, state).await;
            return;
        }
    };

    let update = match updater.check().await {
        Ok(Some(update)) => update,
        Ok(None) => {
            warn!("Update no longer available");
            reset_progress(app, state).await;
            return;
        }
        Err(e) => {
            error!(error = %e, "Update check failed during install");
            reset_progress(app, state).await;
            return;
        }
    };

    // Download and install — signature verification is mandatory and handled
    // by the Tauri updater plugin. If the signature does not match the
    // compiled-in public key, this call will fail and no binary replacement
    // occurs.
    let new_version = update.version.clone();
    if let Err(e) = update.download_and_install(|_, _| {}, || {}).await {
        error!(error = %e, "Update download/install failed");
        update_log::append_entry(&format!("ERROR: background update install failed: {e}"));
        reset_progress(app, state).await;
        return;
    }

    update_log::append_entry(&format!(
        "APPLIED: background updater installed v{new_version}"
    ));
    info!("Update installed successfully, restarting...");

    // Step 3: Restart the application
    app.restart();
}

/// Stop all managed tillandsias containers gracefully.
/// SIGTERM -> 10s grace -> SIGKILL
async fn stop_all_containers() -> Result<(), String> {
    let client = PodmanClient::new();

    let containers = client
        .list_containers("tillandsias-")
        .await
        .map_err(|e| format!("Failed to list containers: {e}"))?;

    for container in containers {
        if container.state == "running" {
            info!(name = %container.name, "Stopping container before update");
            if let Err(e) = client.stop_container(&container.name, 10).await {
                warn!(
                    name = %container.name,
                    error = %e,
                    "Failed to stop container gracefully, force killing"
                );
                let _ = client.kill_container(&container.name, None).await;
            }
        }
    }

    Ok(())
}

/// Reset progress state and emit event so the tray menu reverts to
/// "Update available" for retry.
async fn reset_progress(app: &AppHandle, state: &UpdateState) {
    *state.in_progress.lock().await = false;
    if let Err(e) = tauri::Emitter::emit(app, "update-failed", ()) {
        warn!(error = %e, "Failed to emit update-failed event");
    }
}
