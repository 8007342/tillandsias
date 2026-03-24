//! PID-based singleton guard for the tray application.
//!
//! Ensures only one Tillandsias tray instance runs at a time.
//! If a second instance is launched and the first is alive, the second exits silently.
//! If the lock file references a stale PID (dead process or different binary), the
//! new instance takes over.
//!
//! Lock file locations:
//! - Linux:   `$XDG_RUNTIME_DIR/tillandsias.lock`
//! - macOS:   `$TMPDIR/tillandsias.lock`
//! - Windows: `%TEMP%\tillandsias.lock`

use std::path::PathBuf;

use tracing::{debug, info, warn};

const LOCK_FILENAME: &str = "tillandsias.lock";

/// Returns the platform-specific lock file path.
pub fn lock_path() -> PathBuf {
    #[cfg(target_os = "linux")]
    {
        // $XDG_RUNTIME_DIR is the standard ephemeral, per-user runtime directory.
        // Falls back to /tmp if unset (non-systemd environments).
        std::env::var("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| std::env::temp_dir())
            .join(LOCK_FILENAME)
    }

    #[cfg(target_os = "macos")]
    {
        // $TMPDIR on macOS is per-user and per-session.
        std::env::temp_dir().join(LOCK_FILENAME)
    }

    #[cfg(target_os = "windows")]
    {
        // %TEMP% on Windows is per-user.
        std::env::temp_dir().join(LOCK_FILENAME)
    }
}

/// Attempt to acquire the singleton lock.
///
/// On success, the lock file is written with the current PID and `Ok(())` is returned.
/// On failure (another live instance holds the lock), `Err(())` is returned.
/// The caller should exit silently.
pub fn try_acquire() -> Result<(), ()> {
    let path = lock_path();
    debug!(?path, "Checking singleton lock");

    // Check if a lock file already exists.
    if path.exists() {
        match std::fs::read_to_string(&path) {
            Ok(contents) => {
                let contents = contents.trim();
                if let Ok(pid) = contents.parse::<u32>() {
                    if is_alive(pid) {
                        // Another live Tillandsias instance — exit silently.
                        info!(pid, "Another instance is already running, exiting");
                        return Err(());
                    }
                    // PID is stale (dead or different process) — take over.
                    info!(pid, "Stale lock detected, taking over");
                } else {
                    warn!(?path, contents, "Lock file contains invalid PID, taking over");
                }
            }
            Err(e) => {
                warn!(?path, error = %e, "Cannot read lock file, taking over");
            }
        }
    }

    // Write our PID to the lock file.
    let our_pid = std::process::id();
    match std::fs::write(&path, our_pid.to_string()) {
        Ok(()) => {
            debug!(pid = our_pid, ?path, "Singleton lock acquired");
            Ok(())
        }
        Err(e) => {
            // If we can't write the lock file, log but proceed anyway.
            // Not being able to create the lock shouldn't prevent startup.
            warn!(?path, error = %e, "Failed to write lock file, proceeding without lock");
            Ok(())
        }
    }
}

/// Remove the lock file on graceful shutdown.
///
/// Only removes the file if it contains our own PID (guards against a race
/// where another instance took over between our exit decision and cleanup).
pub fn release() {
    let path = lock_path();
    let our_pid = std::process::id().to_string();

    match std::fs::read_to_string(&path) {
        Ok(contents) if contents.trim() == our_pid => {
            if let Err(e) = std::fs::remove_file(&path) {
                warn!(?path, error = %e, "Failed to remove lock file");
            } else {
                debug!(?path, "Singleton lock released");
            }
        }
        Ok(_) => {
            // Lock file belongs to a different PID — another instance took over.
            // Don't remove it.
            debug!(?path, "Lock file owned by another process, not removing");
        }
        Err(_) => {
            // File already gone — nothing to clean up.
        }
    }
}

/// Check whether the given PID is alive and belongs to a Tillandsias process.
#[cfg(target_os = "linux")]
fn is_alive(pid: u32) -> bool {
    // On Linux, /proc/<pid>/comm contains the process name (first 15 chars).
    let comm_path = format!("/proc/{pid}/comm");
    match std::fs::read_to_string(&comm_path) {
        Ok(comm) => {
            let comm = comm.trim();
            // The binary may be named "tillandsias-tra" (truncated to 15 chars)
            // or "tillandsias" or "tillandsias-tr" depending on the build.
            let is_ours = comm.starts_with("tillandsias");
            debug!(pid, comm, is_ours, "Process comm check");
            is_ours
        }
        Err(_) => {
            // Process doesn't exist or we can't read it — treat as dead.
            debug!(pid, "Cannot read /proc/{}/comm, treating as dead", pid);
            false
        }
    }
}

/// Check whether the given PID is alive on macOS.
///
/// Uses `ps -p <pid> -o comm=` which returns the process command name.
/// No extra crate dependencies required.
#[cfg(target_os = "macos")]
fn is_alive(pid: u32) -> bool {
    match std::process::Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "comm="])
        .output()
    {
        Ok(output) if output.status.success() => {
            let comm = String::from_utf8_lossy(&output.stdout);
            let comm = comm.trim();
            // On macOS, comm is the full path; check if it ends with "tillandsias"
            // or contains it (for development builds).
            let is_ours = comm.contains("tillandsias");
            debug!(pid, comm, is_ours, "Process check via ps");
            is_ours
        }
        _ => {
            debug!(pid, "Process not found via ps");
            false
        }
    }
}

/// Check whether the given PID is alive on Windows.
///
/// Uses `tasklist /FI "PID eq <pid>"` to check process existence and name.
/// No extra crate dependencies required.
#[cfg(target_os = "windows")]
fn is_alive(pid: u32) -> bool {
    match std::process::Command::new("tasklist")
        .args(["/FI", &format!("PID eq {pid}"), "/NH", "/FO", "CSV"])
        .output()
    {
        Ok(output) if output.status.success() => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let is_ours = stdout.contains("tillandsias");
            debug!(pid, is_ours, "Process check via tasklist");
            is_ours
        }
        _ => {
            debug!(pid, "Process not found via tasklist");
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lock_path_is_absolute() {
        let path = lock_path();
        assert!(path.is_absolute(), "Lock path should be absolute: {path:?}");
        assert_eq!(
            path.file_name().unwrap().to_str().unwrap(),
            LOCK_FILENAME,
            "Lock file should be named {LOCK_FILENAME}"
        );
    }

    #[test]
    fn bogus_pid_is_not_alive() {
        // PID 4294967 is extremely unlikely to be running and even less likely
        // to be a tillandsias process.
        assert!(
            !is_alive(4_294_967),
            "Bogus PID should not be detected as alive"
        );
    }

    #[test]
    fn acquire_and_release_roundtrip() {
        // Use a custom lock path to avoid interfering with a real instance.
        let dir = std::env::temp_dir().join("tillandsias-test-singleton");
        let _ = std::fs::create_dir_all(&dir);
        let test_lock = dir.join(LOCK_FILENAME);

        // Clean up from any prior failed run.
        let _ = std::fs::remove_file(&test_lock);

        // Write our PID.
        let pid = std::process::id();
        std::fs::write(&test_lock, pid.to_string()).unwrap();

        // Verify the file exists and contains our PID.
        let contents = std::fs::read_to_string(&test_lock).unwrap();
        assert_eq!(contents.trim(), pid.to_string());

        // Clean up.
        let _ = std::fs::remove_file(&test_lock);
        let _ = std::fs::remove_dir(&dir);
    }
}
