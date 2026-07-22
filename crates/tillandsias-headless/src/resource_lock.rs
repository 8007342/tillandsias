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

/// Lock-file name prefix/suffix shared by `lock_path` and the
/// `held_resources_with_prefix` scanner so the two cannot drift apart.
const LOCK_FILE_PREFIX: &str = "resource-";
const LOCK_FILE_SUFFIX: &str = ".lock";

fn lock_path(resource: &str) -> PathBuf {
    // Resource names are internal constants ("proxy", "image-forge"); keep
    // the file name shape obvious for operators inspecting the lock dir.
    lock_dir().join(format!("{LOCK_FILE_PREFIX}{resource}{LOCK_FILE_SUFFIX}"))
}

/// Lock mode: exclusive for check+act mutators, shared for operations that
/// only require the resource to REMAIN STABLE while they run (order 235:
/// vault exec readers/writers hold shared; a vault recreate holds exclusive,
/// so it waits for in-flight lease holders and vice versa — flock(2) LOCK_SH
/// vs LOCK_EX gives exactly read/write-lock semantics across processes).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LockMode {
    Exclusive,
    Shared,
}

#[cfg(unix)]
fn try_lock(file: &File, mode: LockMode) -> Result<bool, String> {
    use std::os::unix::io::AsRawFd;
    let op = match mode {
        LockMode::Exclusive => libc::LOCK_EX,
        LockMode::Shared => libc::LOCK_SH,
    };
    let rc = unsafe { libc::flock(file.as_raw_fd(), op | libc::LOCK_NB) };
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
fn try_lock(_file: &File, _mode: LockMode) -> Result<bool, String> {
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
    acquire_mode(resource, LockMode::Exclusive, timeout, debug)
}

/// Shared-mode acquire (order 235): concurrent shared holders coexist; an
/// exclusive holder excludes them all and vice versa.
pub fn acquire_shared(
    resource: &str,
    timeout: Duration,
    debug: bool,
) -> Result<ResourceLockGuard, String> {
    acquire_mode(resource, LockMode::Shared, timeout, debug)
}

/// Non-blocking probe: is `resource` currently held (in EITHER mode) by any
/// process — including this one via another fd?
///
/// Order 443 slice 3: launch-in-flight markers are advisory flocks a launch
/// holds across its pre-create window (no container exists yet for `podman
/// ps` to see). The shared-stack teardown probes them here before deciding
/// "no forge anywhere → tear down". flock(2) is per open-file-description,
/// so probing on a FRESH fd never releases (or is satisfied by) a lock held
/// on another fd — even one owned by the calling process itself.
///
/// A missing lock file means "never acquired on this boot" → not held. Any
/// OTHER error (unreadable dir, flock failure) counts as HELD: the callers
/// use this to gate destructive teardown, and a wrong "held" merely leaks a
/// container while a wrong "free" tears the stack out from under a live
/// sibling's launch (leak-not-destroy bias, same as order 233).
pub fn is_held(resource: &str) -> bool {
    let path = lock_path(resource);
    let file = match File::options().write(true).open(&path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return false,
        Err(_) => return true,
    };
    match try_lock(&file, LockMode::Exclusive) {
        // Acquired instantly → nobody held it. The probe lock releases when
        // `file` drops at the end of this function.
        Ok(acquired) => !acquired,
        Err(_) => true,
    }
}

/// Resource names starting with `prefix` whose advisory locks are currently
/// HELD, discovered by scanning the lock directory.
///
/// Lock files are deliberately never unlinked (unlink + re-create races a
/// concurrent acquirer onto a different inode, making a held lock invisible
/// to probers), so the directory accumulates released files; `is_held`
/// filters those out. A missing/unreadable lock dir yields an empty list —
/// nothing could have acquired a lock through it either (acquire fails loud
/// on an unwritable dir).
pub fn held_resources_with_prefix(prefix: &str) -> Vec<String> {
    let dir = lock_dir();
    let entries = match fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(_) => return Vec::new(),
    };
    let mut held = Vec::new();
    for entry in entries.flatten() {
        let file_name = entry.file_name();
        let Some(file_name) = file_name.to_str() else {
            continue;
        };
        let Some(resource) = file_name
            .strip_prefix(LOCK_FILE_PREFIX)
            .and_then(|name| name.strip_suffix(LOCK_FILE_SUFFIX))
        else {
            continue;
        };
        if resource.starts_with(prefix) && is_held(resource) {
            held.push(resource.to_string());
        }
    }
    held.sort();
    held
}

fn acquire_mode(
    resource: &str,
    mode: LockMode,
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
        if try_lock(&file, mode)? {
            return Ok(ResourceLockGuard { _file: file });
        }
        if !reported_contention {
            reported_contention = true;
            if debug {
                eprintln!(
                    "[tillandsias] waiting for '{resource}' lock ({mode:?}; held by another tillandsias process)"
                );
            }
        }
        if start.elapsed() >= timeout {
            return Err(format!(
                "resource-lock: timed out after {}s waiting for '{resource}' ({mode:?}; held by another tillandsias process; see {})",
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

    // ── Shared/exclusive semantics (order 235, R7) ──────────────────────────

    /// Two shared holders coexist without waiting.
    #[test]
    fn shared_holders_coexist() {
        let resource = format!("test-sh-coexist-{}", std::process::id());
        let _a = acquire_shared(&resource, Duration::from_secs(5), false).unwrap();
        let started = Instant::now();
        let _b = acquire_shared(&resource, Duration::from_millis(500), false)
            .expect("second shared holder must not wait");
        assert!(started.elapsed() < Duration::from_millis(400));
    }

    // ── Held-probe semantics (order 443 slice 3) ────────────────────────────

    /// `is_held` tracks the lock lifecycle: free before acquire, held while
    /// a guard lives (even when the prober is the SAME process — flock is
    /// per open-file-description), free again after the guard drops.
    #[test]
    fn is_held_reflects_lock_lifecycle() {
        let resource = format!("test-held-{}", std::process::id());
        assert!(!is_held(&resource), "never-acquired resource must be free");
        let guard = acquire(&resource, Duration::from_secs(5), false).unwrap();
        assert!(
            is_held(&resource),
            "held resource must probe as held from the same process"
        );
        drop(guard);
        assert!(!is_held(&resource), "dropped guard must release the probe");
    }

    /// The prefix scanner returns only currently-HELD resources matching the
    /// prefix: released locks and other prefixes are invisible.
    #[test]
    fn held_resources_with_prefix_lists_only_live_matching_locks() {
        let pid = std::process::id();
        let prefix = format!("test-launch-{pid}-");
        let held_name = format!("{prefix}alpha");
        let released_name = format!("{prefix}beta");
        let other_name = format!("test-other-{pid}-gamma");

        let _held = acquire(&held_name, Duration::from_secs(5), false).unwrap();
        drop(acquire(&released_name, Duration::from_secs(5), false).unwrap());
        let _other = acquire(&other_name, Duration::from_secs(5), false).unwrap();

        let listed = held_resources_with_prefix(&prefix);
        assert_eq!(
            listed,
            vec![held_name.clone()],
            "scanner must list exactly the live lock with the prefix"
        );
        drop(_held);
        assert!(
            held_resources_with_prefix(&prefix).is_empty(),
            "released locks must vanish from the scan"
        );
    }

    /// An exclusive holder excludes shared acquirers (recreate blocks new
    /// lease holders) and a shared holder excludes exclusive (recreate waits
    /// for in-flight lease holders).
    #[test]
    fn exclusive_and_shared_mutually_exclude() {
        let resource = format!("test-rw-excl-{}", std::process::id());
        {
            let _ex = acquire(&resource, Duration::from_secs(5), false).unwrap();
            let err = acquire_shared(&resource, Duration::from_millis(250), false)
                .expect_err("shared must wait behind exclusive");
            assert!(err.contains("timed out"), "{err}");
        }
        {
            let _sh = acquire_shared(&resource, Duration::from_secs(5), false).unwrap();
            let err = acquire(&resource, Duration::from_millis(250), false)
                .expect_err("exclusive must wait behind shared");
            assert!(err.contains("timed out"), "{err}");
        }
        // Both released — either mode acquires immediately again.
        assert!(acquire(&resource, Duration::from_millis(500), false).is_ok());
    }
}
