//! Build lock coordination to prevent duplicate concurrent image builds.
//!
//! Uses a PID lock file at `$XDG_RUNTIME_DIR/tillandsias/build-<image>.lock`.
//! Same pattern as the singleton guard but scoped per image name.

use std::fs;
use std::path::PathBuf;

/// Get the lock file path for a given image name.
fn lock_path(image: &str) -> PathBuf {
    let dir = if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
        PathBuf::from(xdg).join("tillandsias")
    } else {
        std::env::temp_dir().join("tillandsias-build")
    };
    dir.join(format!("build-{image}.lock"))
}

/// Check if a PID is alive and belongs to a tillandsias-related process.
fn is_alive(pid: u32) -> bool {
    let comm_path = format!("/proc/{pid}/comm");
    // Just check if the process exists. The PID could be tillandsias-tray,
    // nix, bash (running build-image.sh), etc.
    fs::read_to_string(comm_path).is_ok()
}

/// Try to acquire the build lock for an image.
/// Returns `Ok(())` if acquired, `Err("already running")` if another build is active.
pub fn acquire(image: &str) -> Result<(), String> {
    let path = lock_path(image);

    // Check for existing lock
    if let Ok(content) = fs::read_to_string(&path) {
        if let Ok(pid) = content.trim().parse::<u32>() {
            if is_alive(pid) {
                return Err(format!("Build already running (PID {pid})"));
            }
            // Stale lock — take over
        }
    }

    // Write our PID
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).ok();
    }
    fs::write(&path, format!("{}", std::process::id()))
        .map_err(|e| format!("Cannot write build lock: {e}"))
}

/// Release the build lock for an image.
pub fn release(image: &str) {
    let path = lock_path(image);
    // Only remove if it's our PID
    if let Ok(content) = fs::read_to_string(&path) {
        if let Ok(pid) = content.trim().parse::<u32>() {
            if pid == std::process::id() {
                let _ = fs::remove_file(&path);
            }
        }
    }
}

/// Check if a build is currently running for an image.
pub fn is_running(image: &str) -> bool {
    let path = lock_path(image);
    if let Ok(content) = fs::read_to_string(&path) {
        if let Ok(pid) = content.trim().parse::<u32>() {
            return is_alive(pid);
        }
    }
    false
}

/// Wait for an in-progress build to complete, polling every 2 seconds.
/// Returns `Ok(())` when the lock is released, or `Err` on timeout (60s).
pub fn wait_for_build(image: &str) -> Result<(), String> {
    let max_wait = 60 * 5; // 5 minutes max
    let mut waited = 0;

    while is_running(image) {
        if waited >= max_wait {
            return Err(format!(
                "Timed out waiting for {image} build ({}s)",
                max_wait
            ));
        }
        std::thread::sleep(std::time::Duration::from_secs(2));
        waited += 2;
        if waited % 10 == 0 {
            eprint!(".");
        }
    }

    Ok(())
}
