//! Singleton enforcement via file locking (flock).
//! @trace spec:singleton-guard, spec:graceful-shutdown

use fs2::FileExt;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::process;
use std::time::Duration;
#[cfg(unix)]
use std::time::Instant;
#[cfg(unix)]
use tracing::info;
use tracing::{debug, warn};

/// A guard that ensures only one instance of the application is running.
pub struct SingletonGuard {
    _file: File,
}

impl SingletonGuard {
    /// Acquire an exclusive lock on the singleton lockfile.
    ///
    /// If the lock is already held by another process:
    /// 1. Attempt to signal the existing process to exit.
    /// 2. Wait up to `timeout` for it to exit.
    /// 3. If it doesn't exit, forcefully terminate it.
    /// 4. Acquire the lock and write our own PID.
    pub fn acquire(name: &str, timeout: Duration) -> Result<Self, String> {
        if std::env::var("TILLANDSIAS_NO_SINGLETON").is_ok() {
            return Ok(Self {
                _file: OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create(true)
                    .truncate(false)
                    .open("/dev/null")
                    .unwrap(),
            });
        }
        let name = std::env::var("TILLANDSIAS_LOCK_NAME").unwrap_or_else(|_| name.to_string());
        let lock_dir = dirs::runtime_dir()
            .or_else(dirs::cache_dir)
            .ok_or_else(|| "Could not determine runtime/cache directory".to_string())?
            .join("tillandsias");

        std::fs::create_dir_all(&lock_dir).map_err(|e| {
            format!(
                "Failed to create lock directory {}: {e}",
                lock_dir.display()
            )
        })?;

        let lock_path = lock_dir.join(format!("{}.lock", name));

        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&lock_path)
            .map_err(|e| format!("Failed to open lockfile {}: {e}", lock_path.display()))?;

        // Try to acquire lock non-blocking first
        if let Err(_e) = file.try_lock_exclusive() {
            debug!(target: "tillandsias_core", path = %lock_path.display(), "lockfile is busy; attempting to terminate owner");

            // Read PID from lockfile
            let mut pid_str = String::new();
            let _ = file.read_to_string(&mut pid_str);
            let owner_pid = pid_str.trim().parse::<i32>().ok();

            if let Some(pid) = owner_pid.filter(|&pid| pid != process::id() as i32) {
                Self::terminate_process(pid, timeout);
            }

            // Now block until we get the lock
            file.lock_exclusive()
                .map_err(|e| format!("Failed to acquire exclusive lock: {e}"))?;
        }

        // Truncate and write own PID
        file.set_len(0)
            .map_err(|e| format!("Failed to truncate lockfile: {e}"))?;
        file.seek(SeekFrom::Start(0))
            .map_err(|e| format!("Failed to seek lockfile: {e}"))?;
        write!(file, "{}", process::id())
            .map_err(|e| format!("Failed to write PID to lockfile: {e}"))?;
        file.flush()
            .map_err(|e| format!("Failed to flush lockfile: {e}"))?;

        Ok(Self { _file: file })
    }

    #[allow(unused_variables)]
    fn terminate_process(pid: i32, timeout: Duration) {
        #[cfg(unix)]
        {
            unsafe {
                // 1. Signal SIGTERM
                debug!(target: "tillandsias_core", %pid, "sending SIGTERM to existing instance");
                if libc::kill(pid, libc::SIGTERM) != 0 {
                    let err = std::io::Error::last_os_error();
                    if err.kind() != std::io::ErrorKind::NotFound {
                        warn!(target: "tillandsias_core", %pid, error = %err, "failed to send SIGTERM");
                    }
                    return;
                }

                // 2. Wait
                let start = Instant::now();
                while start.elapsed() < timeout {
                    // Check if process is still alive (0 means still alive, -1 and ESRCH means it's gone)
                    if libc::kill(pid, 0) != 0 {
                        info!(target: "tillandsias_core", %pid, "existing instance exited gracefully");
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }

                // 3. SIGKILL
                warn!(target: "tillandsias_core", %pid, "existing instance did not exit; sending SIGKILL");
                let _ = libc::kill(pid, libc::SIGKILL);
            }
        }

        #[cfg(windows)]
        {
            // Windows implementation using windows-sys or winapi
            warn!(target: "tillandsias_core", pid, "cross-process termination not yet implemented on Windows");
        }
    }
}
