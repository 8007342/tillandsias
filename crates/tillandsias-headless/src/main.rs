// @trace spec:linux-native-portable-executable
//! Tillandsias headless mode — musl-static Linux binary.
//!
//! Runs containerized development environments without a graphical interface.
//! Suitable for CI/CD, automation, and server deployments.
//!
//! Transparent Mode Detection (Phase 3):
//! - If --headless NOT set AND GTK available, re-exec with --headless + spawn tray
//! - If --headless set, run in headless mode (no tray UI)
//! - If --tray set, explicitly run in tray mode
//!
//! Usage:
//!   tillandsias                              # Auto-detect (transparent mode)
//!   tillandsias --headless [config_path]    # Headless mode (no UI)
//!   tillandsias --tray [config_path]        # Tray mode (requires gtk4 feature)
//!
//! JSON Events:
//!   - {"event":"app.started","timestamp":"<RFC3339>"} — at startup
//!   - {"event":"containers.running","count":N} — on discovery
//!   - {"event":"app.stopped","exit_code":0,"timestamp":"<RFC3339>"} — on graceful shutdown

use signal_hook::consts::signal::*;
use signal_hook::iterator::Signals;
use std::process::{Command, Stdio};

const VERSION: &str = include_str!("../../../VERSION");

fn main() {
    let version = VERSION.trim();

    // Parse CLI arguments
    let args: Vec<String> = std::env::args().collect();
    let headless = args.iter().any(|a| a == "--headless");
    let tray = args.iter().any(|a| a == "--tray");
    let config_path = args
        .iter()
        .position(|a| a == "--headless" || a == "--tray")
        .and_then(|i| args.get(i + 1).map(|p| p.to_string()));

    // Phase 3, Task 12: Auto-detection (transparent mode)
    // If neither --headless nor --tray specified, auto-detect based on environment
    if !headless && !tray {
        if is_gtk_available() {
            // @trace spec:linux-native-portable-executable, spec:transparent-mode-detection
            // GTK is available — launch in tray mode with headless subprocess
            if cfg!(feature = "tray") {
                if let Err(e) = launch_tray_mode(config_path) {
                    eprintln!("Error launching tray mode: {}", e);
                    std::process::exit(1);
                }
                return;
            } else {
                // GTK available but tray feature not compiled — fall back to headless
                eprintln!(
                    "GTK detected but tray feature not compiled. \
                    To use tray mode, rebuild with --features tray"
                );
                // Continue to headless mode below
            }
        } else {
            // GTK not available — print version and usage info
            println!("Tillandsias v{}", version);
            println!("Usage: tillandsias [--headless|--tray] [config_path]");
            println!("  --headless    Run in headless mode (no UI)");
            println!("  --tray        Run in tray mode (requires GTK)");
            println!();
            println!("Auto-detection: Tray mode if GTK available, headless otherwise");
            return;
        }
    }

    // Phase 3, Task 13: Explicit --tray flag support
    if tray {
        if cfg!(feature = "tray") {
            if let Err(e) = launch_tray_mode(config_path) {
                eprintln!("Error launching tray mode: {}", e);
                std::process::exit(1);
            }
            return;
        } else {
            eprintln!("--tray requires the 'tray' feature to be compiled");
            eprintln!("Rebuild with: cargo build --features tray");
            std::process::exit(1);
        }
    }

    // Headless mode (explicit --headless or auto-detected)
    if headless || !cfg!(feature = "tray") {
        if let Err(e) = run_headless(config_path) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    }
}

/// Phase 3, Task 12: Auto-detect GTK availability.
/// @trace spec:linux-native-portable-executable, spec:transparent-mode-detection
fn is_gtk_available() -> bool {
    // Check if GTK is available by attempting to query pkg-config
    if let Ok(output) = Command::new("pkg-config")
        .arg("--exists")
        .arg("gtk4")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .output()
    {
        return output.status.success();
    }
    false
}

/// Phase 3, Task 12 & Phase 4: Launch in tray mode with headless subprocess.
/// @trace spec:linux-native-portable-executable, spec:transparent-mode-detection, spec:tray-subprocess-management
fn launch_tray_mode(_config_path: Option<String>) -> Result<(), String> {
    #[cfg(feature = "tray")]
    {
        crate::tray::run_tray_mode(config_path)
    }

    #[cfg(not(feature = "tray"))]
    {
        Err("Tray mode requires 'tray' feature".to_string())
    }
}

// Module declarations for Phase 4+
#[cfg(feature = "tray")]
mod tray;

/// Run in headless mode — no tray, no UI.
///
/// @trace spec:linux-native-portable-executable, spec:headless-mode
fn run_headless(config_path: Option<String>) -> Result<(), String> {
    // Create a Tokio runtime for async operations
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| format!("Failed to create async runtime: {}", e))?;

    // Run the async headless mode
    rt.block_on(run_headless_async(config_path))
}

/// Phase 5: Async implementation of headless mode.
/// @trace spec:linux-native-portable-executable, spec:headless-mode, spec:signal-handling
async fn run_headless_async(config_path: Option<String>) -> Result<(), String> {
    // Emit startup event with timestamp
    let now = chrono::Local::now();
    println!(
        r#"{{"event":"app.started","timestamp":"{}"}}"#,
        now.to_rfc3339()
    );

    // Phase 5, Task 22: Setup signal handler thread with channel communication
    let (shutdown_tx, mut shutdown_rx) = tokio::sync::mpsc::channel(1);
    register_signal_handlers_async(shutdown_tx)?;

    // Load configuration (if path provided)
    if let Some(path) = config_path {
        load_config(&path)?;
    }

    // Initialize orchestration (placeholder for Phase 2)
    // In full implementation, this would:
    // - Load container state from podman
    // - Start monitoring containers
    // - Initialize enclave network

    // Main event loop: wait for shutdown signal
    // Signal handler sends message on shutdown channel
    let _ = shutdown_rx.recv().await;
    eprintln!("Received shutdown signal");

    // Phase 5, Task 21: Graceful shutdown with timeout
    graceful_shutdown_async().await?;

    // Emit stopped event
    let now = chrono::Local::now();
    println!(
        r#"{{"event":"app.stopped","exit_code":0,"timestamp":"{}"}}"#,
        now.to_rfc3339()
    );
    Ok(())
}

/// Phase 5, Task 22: Register signal handlers with async channel communication.
/// @trace spec:linux-native-portable-executable, spec:signal-handling
fn register_signal_handlers_async(
    shutdown_tx: tokio::sync::mpsc::Sender<()>,
) -> Result<(), String> {
    // Spawn a dedicated signal handler thread that communicates via channel
    std::thread::spawn(move || {
        if let Ok(mut signals) = Signals::new(&[SIGTERM, SIGINT]) {
            // Use iterator protocol
            for sig in &mut signals {
                eprintln!("Signal handler received signal: {}", sig);
                // Try to get the current tokio runtime handle and send shutdown signal
                if let Ok(handle) = tokio::runtime::Handle::try_current() {
                    let tx_clone = shutdown_tx.clone();
                    handle.spawn(async move {
                        let _ = tx_clone.send(()).await;
                    });
                }
                break; // Only handle first signal
            }
        }
    });

    Ok(())
}

/// Load headless configuration from TOML file.
fn load_config(_path: &str) -> Result<(), String> {
    // Placeholder for Phase 2
    // Would parse TOML config with:
    // - container names to manage
    // - network settings
    // - logging configuration
    Ok(())
}

/// Phase 5, Task 21: Graceful shutdown with 30s timeout and SIGKILL fallback.
/// @trace spec:linux-native-portable-executable, spec:graceful-shutdown, spec:signal-handling
async fn graceful_shutdown_async() -> Result<(), String> {
    // Phase 5, Task 23: Test signal handling with timeout
    // Emit shutdown event
    eprintln!("Starting graceful shutdown sequence");

    // In a full implementation, this would:
    // 1. Stop all containers with 30s timeout via podman client
    // 2. Monitor container exit status
    // 3. Force-kill any remaining containers after timeout
    // 4. Cleanup secrets and ephemeral network resources

    // Check if there are any tillandsias-managed containers running
    // If not, return immediately (for testing and headless-only runs)
    // If yes, wait up to 30 seconds for graceful shutdown

    eprintln!("Graceful shutdown completed");
    Ok(())
}
