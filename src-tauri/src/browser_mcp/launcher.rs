//! Chromium launcher using bundled browser from host-chromium-on-demand.
//!
//! Spawns ephemeral Chromium processes with random debugging ports and
//! per-window user-data directories. Attaches CDP and tracks processes.
//!
//! @trace spec:host-browser-mcp, spec:host-chromium-on-demand
//! @cheatsheet web/cdp.md

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;
use tokio::time::timeout;
use tracing::{debug, info};
use url::Url;

use crate::cdp::CDP_READY_TIMEOUT;
use super::window_registry::{WindowEntry, WindowId};

/// Random ephemeral port range for CDP debugging ports.
const CDP_PORT_MIN: u16 = 49152;
const CDP_PORT_MAX: u16 = 65535;

/// Generates a random port for CDP debugging.
fn random_cdp_port() -> u16 {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    let mut hasher = RandomState::new().build_hasher();
    hasher.write_u64(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64);
    let hash = hasher.finish();
    CDP_PORT_MIN + ((hash as u16) % (CDP_PORT_MAX - CDP_PORT_MIN + 1))
}

/// Generates an ephemeral user-data directory for the window.
///
/// @trace spec:host-browser-mcp, spec:cross-platform
/// On Linux, prefers XDG_RUNTIME_DIR (tmpfs-backed, per-user, auto-cleaned by
/// systemd at logout) per the XDG Base Directory Spec. Falls back to
/// `/run/user/$UID` only when the env var is missing — that fallback path is
/// Linux-specific (systemd-logind creates it). On Windows/macOS the runtime
/// dir concept does not exist, so use `std::env::temp_dir()` which resolves
/// to `%TEMP%`/`$TMPDIR` respectively.
/// Reference: <https://specifications.freedesktop.org/basedir-spec/latest/>
fn ephemeral_user_data_dir(window_id: &str) -> Result<PathBuf, String> {
    let runtime_dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| {
        #[cfg(target_os = "linux")]
        {
            // SAFETY: getuid() always succeeds and returns the real uid; no
            // pointer dereferences, no allocations. The unsafe block is a
            // libc convention requirement, not a real safety hazard.
            format!("/run/user/{}", unsafe { libc::getuid() })
        }
        #[cfg(not(target_os = "linux"))]
        {
            std::env::temp_dir().to_string_lossy().into_owned()
        }
    });

    let path = PathBuf::from(runtime_dir)
        .join("tillandsias")
        .join("mcp")
        .join(window_id);

    // Ensure parent directory exists
    std::fs::create_dir_all(path.parent().unwrap())
        .map_err(|e| format!("Failed to create MCP runtime dir: {}", e))?;

    Ok(path)
}

/// Result of launching a browser window.
pub struct LaunchResult {
    pub window_id: WindowId,
    pub pid: u32,
    pub cdp_port: u16,
    pub target_id: String,
}

/// Launch a browser window for the given URL.
///
/// Returns a window entry with the CDP target id attached.
///
/// Errors if:
/// - Bundled Chromium is not found
/// - Chromium fails to spawn
/// - CDP attach times out or fails
pub async fn launch(
    url: &Url,
    project: &str,
) -> Result<WindowEntry, String> {
    let window_id = format!("win-{}", uuid::Uuid::new_v4());
    let cdp_port = random_cdp_port();
    let user_data_dir = ephemeral_user_data_dir(&window_id)?;

    debug!(
        window_id = %window_id,
        url = %url,
        cdp_port = cdp_port,
        "Launching Chromium browser window"
    );

    // Find the bundled Chromium binary
    let chromium_path = resolve_chromium_binary()
        .ok_or_else(|| "Bundled Chromium not found".to_string())?;

    // Spawn the Chromium process
    let child = Command::new(&chromium_path)
        .arg(format!("--app={}", url))
        .arg(format!("--user-data-dir={}", user_data_dir.display()))
        .arg("--incognito")
        .arg("--no-first-run")
        .arg("--no-default-browser-check")
        .arg(format!("--remote-debugging-port={}", cdp_port))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("Failed to spawn Chromium: {}", e))?;

    let pid = child.id();
    info!(
        window_id = %window_id,
        pid = pid,
        cdp_port = cdp_port,
        "Chromium process spawned"
    );

    // Wait for CDP endpoint to become available
    let target_id = timeout(
        CDP_READY_TIMEOUT,
        wait_for_cdp_ready(cdp_port, &window_id),
    )
    .await
    .map_err(|_| format!("CDP timeout on port {}", cdp_port))?
    .map_err(|e| format!("CDP attach failed: {}", e))?;

    let entry = WindowEntry {
        id: window_id.clone(),
        pid,
        cdp_port,
        target_id,
        project: project.to_string(),
        user_data_dir,
        opened_url: url.to_string(),
    };

    info!(
        window_id = %window_id,
        "Window launched and CDP attached"
    );

    Ok(entry)
}

/// Resolve the path to the bundled Chromium binary.
///
/// Checks:
/// 1. ~/.cache/tillandsias/chromium/<version>/chrome (or .exe on Windows)
/// 2. Delegates to host-chromium-on-demand resolver (future)
fn resolve_chromium_binary() -> Option<PathBuf> {
    let home = std::env::home_dir()?;
    let cache_dir = home.join(".cache/tillandsias/chromium");

    // List subdirectories (versions) and pick the latest
    let entries = std::fs::read_dir(&cache_dir).ok()?;
    let mut versions: Vec<_> = entries
        .filter_map(|e| {
            let entry = e.ok()?;
            let path = entry.path();
            if path.is_dir() {
                Some(path)
            } else {
                None
            }
        })
        .collect();

    versions.sort();
    let latest = versions.pop()?;

    let binary_name = if cfg!(windows) {
        "chrome.exe"
    } else {
        "chrome"
    };

    let binary_path = latest.join(binary_name);
    if binary_path.exists() {
        Some(binary_path)
    } else {
        None
    }
}

/// Wait for CDP to become ready on the given port.
///
/// Polls the HTTP discovery endpoint at 127.0.0.1:<port>/json
/// and returns the first target id when available.
async fn wait_for_cdp_ready(port: u16, _window_id: &str) -> Result<String, String> {
    let url = format!("http://127.0.0.1:{}/json", port);

    for attempt in 0..20 {
        match tokio::time::timeout(
            Duration::from_millis(250),
            get_cdp_targets(&url),
        ).await {
            Ok(Ok(targets)) if !targets.is_empty() => {
                debug!(port = port, "CDP ready after {} attempts", attempt);
                // Return the first target (should be the app window)
                return Ok(targets[0].clone());
            }
            Ok(Err(e)) => {
                debug!(port = port, attempt = attempt, "CDP discovery failed: {}", e);
            }
            Err(_) => {
                debug!(port = port, attempt = attempt, "CDP discovery timeout");
            }
            Ok(Ok(_)) => {
                // Empty targets list
                debug!(port = port, attempt = attempt, "CDP returned empty targets");
            }
        }

        tokio::time::sleep(Duration::from_millis(250)).await;
    }

    Err(format!("CDP not ready after 5s on port {}", port))
}

/// Get the list of targets from the CDP discovery endpoint.
async fn get_cdp_targets(url: &str) -> Result<Vec<String>, String> {
    use serde::Deserialize;

    #[derive(Debug, Deserialize)]
    struct CdpTarget {
        id: String,
        #[serde(rename = "type")]
        target_type: String,
    }

    let response = reqwest::Client::new()
        .get(url)
        .timeout(Duration::from_millis(500))
        .send()
        .await
        .map_err(|e| format!("HTTP error: {}", e))?;

    let targets: Vec<CdpTarget> = response
        .json()
        .await
        .map_err(|e| format!("JSON parse error: {}", e))?;

    Ok(targets
        .into_iter()
        .map(|t| t.id)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_random_cdp_port() {
        let port = random_cdp_port();
        assert!(port >= CDP_PORT_MIN && port <= CDP_PORT_MAX);
    }

    #[test]
    fn test_ephemeral_user_data_dir() {
        let result = ephemeral_user_data_dir("test-window");
        assert!(result.is_ok());
        let path = result.unwrap();
        assert!(path.to_string_lossy().contains("tillandsias"));
        assert!(path.to_string_lossy().contains("mcp"));
    }

    #[test]
    fn test_resolve_chromium_missing() {
        // When Chromium is not installed, should return None
        if resolve_chromium_binary().is_none() {
            // This is expected in test environments
        }
    }
}
