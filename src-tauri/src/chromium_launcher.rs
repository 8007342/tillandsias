//! Chromium window spawning for browser isolation.
//!
//! Provides `spawn_chromium_window()` which launches a Chromium container
//! with the appropriate security hardening and window type configuration.
//!
//! @trace spec:browser-isolation-core

use std::path::PathBuf;
use std::process::{Command, Stdio};
use tracing::{debug, error, info};

/// Spawn a Chromium window in a container.
///
/// # Arguments
///
/// * `project` - The project name (used for container naming)
/// * `url` - The URL to open in the browser
/// * `window_type` - Either "open_safe_window" or "open_debug_window"
/// * `version` - Version string for versioned image tags (e.g., "0.1.160"), or "latest"
///
/// # Returns
///
/// * `Ok(container_id)` - The container ID on success
/// * `Err(error_message)` - Error message on failure
///
/// @trace spec:browser-isolation-core
pub fn spawn_chromium_window(
    project: &str,
    url: &str,
    window_type: &str,
    version: &str,
) -> Result<String, String> {
    // Validate window type (safe or debug)
    if window_type != "open_safe_window" && window_type != "open_debug_window" {
        return Err(format!(
            "Invalid window_type: '{}'. Expected 'open_safe_window' or 'open_debug_window'",
            window_type
        ));
    }

    // Get the launch script path
    let script_path = get_launch_script_path()?;

    info!(
        spec = "browser-isolation-core",
        project = %project,
        url = %url,
        window_type = %window_type,
        version = %version,
        "Spawning Chromium window"
    );

    // Determine port (default to 9222 for debugging)
    let debug_port = 9222u16;

    // Build the command arguments for launch-chromium.sh
    // Script usage: launch-chromium.sh <project> <url> [port] [window_type] [version]
    // @trace spec:browser-isolation-core
    let mut cmd = Command::new(&script_path);
    cmd.arg(project)
        .arg(url)
        .arg(debug_port.to_string())
        .arg(window_type) // Pass window type to script
        .arg(version) // Pass version for versioned image tags
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    // Spawn the process
    let child = cmd.spawn().map_err(|e| {
        format!(
            "Failed to spawn Chromium launch script '{}': {}",
            script_path.display(),
            e
        )
    })?;

    let pid = child.id();
    debug!(
        spec = "browser-isolation-core",
        pid = %pid,
        "Chromium launch script spawned"
    );

    // Wait for the script to complete and capture output
    let output = child
        .wait_with_output()
        .map_err(|e| format!("Failed to wait for Chromium launch script: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        error!(
            spec = "browser-isolation-core",
            exit_code = ?output.status.code(),
            stderr = %stderr,
            "Chromium launch script failed"
        );
        return Err(format!(
            "Chromium launch script failed with exit code {:?}: {}",
            output.status.code(),
            stderr
        ));
    }

    let container_id = String::from_utf8_lossy(&output.stdout).trim().to_string();

    if container_id.is_empty() {
        return Err("Chromium launch script returned empty container ID".to_string());
    }

    info!(
        spec = "browser-isolation-core",
        container_id = %container_id,
        project = %project,
        window_type = %window_type,
        "Chromium window spawned successfully"
    );

    Ok(container_id)
}

/// Get the path to the launch-chromium.sh script.
///
/// Searches for the script in the following order:
/// 1. Next to the executable (for installed builds)
/// 2. In the project's scripts/ directory (for development)
///
/// @trace spec:browser-isolation-core
fn get_launch_script_path() -> Result<PathBuf, String> {
    // Try next to the executable first
    if let Ok(exe_path) = std::env::current_exe() {
        let exe_dir = exe_path.parent().unwrap_or(std::path::Path::new("."));
        let script_path = exe_dir.join("scripts").join("launch-chromium.sh");
        if script_path.exists() {
            return Ok(script_path);
        }
    }

    // Try the project's scripts directory
    let project_script = std::path::Path::new("scripts/launch-chromium.sh");
    if project_script.exists() {
        return Ok(project_script.to_path_buf());
    }

    // Try absolute path from project root
    let abs_path =
        std::path::Path::new("/var/home/machiyotl/src/tillandsias/scripts/launch-chromium.sh");
    if abs_path.exists() {
        return Ok(abs_path.to_path_buf());
    }

    Err("Could not find launch-chromium.sh script".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_window_type_validation() {
        // These will fail in test environment without the script
        // but we can test the validation logic
        assert!(
            spawn_chromium_window("test", "http://localhost:3000", "invalid", "0.1.160").is_err()
        );
        assert!(
            spawn_chromium_window(
                "test",
                "http://localhost:3000",
                "open_safe_window",
                "0.1.160"
            )
            .is_err()
        ); // Will fail without script
    }
}
