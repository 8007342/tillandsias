//! Advisory per-resource file locks serializing container check+act sections.
//!
//! Order 232 (R4 of the race-safeguards ratification, order 160): two parallel
//! tillandsias processes (a user launch + the vsock liveness probe, or two
//! cloud launches) could both observe "proxy not running" and both `podman run
//! --name tillandsias-proxy`, one losing with "name already in use". Every
//! shared-resource ensure path now takes an exclusive advisory flock across
//! its whole check+act window: one process wins, the loser waits (bounded) and
//! then observes the winner's result idempotently.
//!
//! Locks live under `$XDG_RUNTIME_DIR/tillandsias-locks/` (same directory the
//! smoke lock uses) so they vanish on reboot and never outlive the user
//! session; the fallback for sessions without a runtime dir is a per-uid
//! directory under the system temp dir. `flock(2)` releases on fd close, so
//! a killed process can never leave a stale lock.
//!
//! @trace plan/issues/race-safeguards-research-2026-07-02.md (R4)

use std::fs::{self, File};
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// How often a waiter re-polls a contended lock. Coarse on purpose — these
/// sections are seconds-to-minutes long (podman run / image build), so a
/// 100ms poll adds negligible latency while keeping the loop cheap.
const CONTENTION_POLL: Duration = Duration::from_millis(100);

/// RAII guard: the advisory lock is held for the guard's lifetime and
/// released when the guard (and its fd) drops — including on panic or kill.
#[derive(Debug)]
pub struct ResourceLockGuard {
    _file: File,
}

fn lock_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        let trimmed = dir.trim();
        if !trimmed.is_empty() {
            return PathBuf::from(trimmed).join("tillandsias-locks");
        }
    }
    // No user runtime dir (rare: system services, stripped CI sandboxes).
    // Per-uid suffix keeps multi-user hosts from sharing a lock namespace.
    #[cfg(unix)]
    let uid = unsafe { libc::getuid() };
    #[cfg(not(unix))]
    let uid = 0u32;
    std::env::temp_dir().join(format!("tillandsias-locks-{uid}"))
}

fn lock_path(resource: &str) -> PathBuf {
    // Resource names are internal constants ("proxy", "image-forge"); keep
    // the file name shape obvious for operators inspecting the lock dir.
    lock_dir().join(format!("resource-{resource}.lock"))
}

#[cfg(unix)]
fn try_exclusive(file: &File) -> Result<bool, String> {
    use std::os::unix::io::AsRawFd;
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc == 0 {
        return Ok(true);
    }
    let err = std::io::Error::last_os_error();
    if err.raw_os_error() == Some(libc::EWOULDBLOCK) {
        Ok(false)
    } else {
        Err(format!("flock: {err}"))
    }
}

#[cfg(not(unix))]
fn try_exclusive(_file: &File) -> Result<bool, String> {
    // Non-unix hosts do not run the podman ensure paths these locks protect
    // (the Windows host manages containers inside the WSL2 Linux guest, where
    // the unix implementation is active). Degrade to no serialization rather
    // than failing compilation.
    Ok(true)
}

/// Acquire the exclusive advisory lock for `resource`, waiting up to
/// `timeout` on contention. Returns a guard that releases on drop.
///
/// The wait is a bounded LOCK_NB poll (flock(2) has no native timeout).
/// Timing out is a loud error — it means another tillandsias process has
/// held the resource for the whole window (wedged build, hung podman), and
/// proceeding unserialized would recreate the exact race this lock exists
/// to prevent.
pub fn acquire(
    resource: &str,
    timeout: Duration,
    debug: bool,
) -> Result<ResourceLockGuard, String> {
    let dir = lock_dir();
    fs::create_dir_all(&dir)
        .map_err(|e| format!("resource-lock: create lock dir {}: {e}", dir.display()))?;
    let path = lock_path(resource);
    let file = File::options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .map_err(|e| format!("resource-lock: open {}: {e}", path.display()))?;

    let start = Instant::now();
    let mut reported_contention = false;
    loop {
        if try_exclusive(&file)? {
            return Ok(ResourceLockGuard { _file: file });
        }
        if !reported_contention {
            reported_contention = true;
            if debug {
                eprintln!(
                    "[tillandsias] waiting for '{resource}' lock (held by another tillandsias process)"
                );
            }
        }
        if start.elapsed() >= timeout {
            return Err(format!(
                "resource-lock: timed out after {}s waiting for '{resource}' (held by another tillandsias process; see {})",
                timeout.as_secs(),
                path.display()
            ));
        }
        std::thread::sleep(CONTENTION_POLL);
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    /// Two threads contending for the same resource serialize: the critical
    /// sections never overlap.
    #[test]
    fn same_resource_serializes_check_and_act() {
        let resource = format!("test-serialize-{}", std::process::id());
        let inside = Arc::new(AtomicBool::new(false));
        let overlaps = Arc::new(AtomicUsize::new(0));
        let mut handles = Vec::new();
        for _ in 0..4 {
            let resource = resource.clone();
            let inside = Arc::clone(&inside);
            let overlaps = Arc::clone(&overlaps);
            handles.push(std::thread::spawn(move || {
                let _g = acquire(&resource, Duration::from_secs(10), false)
                    .expect("acquire within timeout");
                if inside.swap(true, Ordering::SeqCst) {
                    overlaps.fetch_add(1, Ordering::SeqCst);
                }
                std::thread::sleep(Duration::from_millis(30));
                inside.store(false, Ordering::SeqCst);
            }));
        }
        for h in handles {
            h.join().unwrap();
        }
        assert_eq!(
            overlaps.load(Ordering::SeqCst),
            0,
            "critical sections overlapped despite the resource lock"
        );
    }

    /// Distinct resources do not serialize against each other: a held lock
    /// on resource A never blocks resource B.
    #[test]
    fn distinct_resources_do_not_contend() {
        let pid = std::process::id();
        let a = format!("test-distinct-a-{pid}");
        let b = format!("test-distinct-b-{pid}");
        let _ga = acquire(&a, Duration::from_secs(5), false).unwrap();
        // Must succeed immediately despite `a` being held.
        let started = Instant::now();
        let _gb = acquire(&b, Duration::from_secs(5), false).unwrap();
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "distinct resource contended unexpectedly"
        );
    }

    /// A contended lock times out loudly instead of proceeding unserialized.
    #[test]
    fn contended_lock_times_out_loudly() {
        let resource = format!("test-timeout-{}", std::process::id());
        let _held = acquire(&resource, Duration::from_secs(5), false).unwrap();
        // flock is per open-file-description: a second open in the SAME
        // process contends exactly like another process would.
        let err = acquire(&resource, Duration::from_millis(250), false)
            .expect_err("second acquire must time out while held");
        assert!(
            err.contains("timed out") && err.contains(&resource),
            "timeout error must name the resource: {err}"
        );
    }

    /// Dropping the guard releases the lock for the next waiter.
    #[test]
    fn drop_releases_for_next_acquirer() {
        let resource = format!("test-release-{}", std::process::id());
        let guard = acquire(&resource, Duration::from_secs(5), false).unwrap();
        drop(guard);
        let reacquired = acquire(&resource, Duration::from_millis(500), false);
        assert!(reacquired.is_ok(), "lock not released on guard drop");
    }
}
