// @trace order:2407-aana
//! Scratch directories for tests, removed when the test process exits. Public so every crate that
//! depends on tillandsias-core uses the one hook (tillandsias-headless, tillandsias-podman); it is
//! inert until called, and nothing outside tests calls it.
//!
//! WHY (2407-aana). The crate's tests made `std::env::temp_dir()/<prefix>-<pid>[-<n>]` dirs
//! and left them: one `cargo test` run left 70 entries, and under nextest (one process per
//! test) the per-process ones leaked once per test. /tmp is a tmpfs with a fixed inode count;
//! on 2026-11-26 it reached 98% of 1,048,576 from about 99,000 such dirs, and the land queue
//! read the resulting ENOSPC as merge conflicts and evicted 19 PRs.
//!
//! A `tempfile::TempDir` is the usual answer and is right for a dir whose life is one scope.
//! Two shapes here have no such scope: a dir shared by every test in the process (the msg
//! store, the lock dir), and a helper that returns a plain path the caller keeps
//! (`test_cache_root`, where an early-dropping TempDir was the defect it fixed). So every dir
//! made through [`dir`] is recorded, and an `atexit` hook removes the recorded dirs when the
//! process exits. The libtest harness ends with `exit()`, so the hook runs after a failing
//! test too; only a SIGKILL (a nextest timeout) skips it.

use std::path::{Path, PathBuf};
use std::sync::{Mutex, Once};

static DIRS: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());
static HOOK: Once = Once::new();

extern "C" fn remove_recorded() {
    if let Ok(dirs) = DIRS.lock() {
        for d in dirs.iter() {
            let _ = std::fs::remove_dir_all(d);
        }
    }
}

/// Record `path` for removal at process exit (idempotent per path).
pub fn remember(path: &Path) {
    HOOK.call_once(|| {
        // SAFETY: registers a plain `extern "C" fn()` with the C runtime; it touches only
        // its own static and the filesystem.
        unsafe {
            libc::atexit(remove_recorded);
        }
    });
    if let Ok(mut dirs) = DIRS.lock()
        && !dirs.iter().any(|d| d == path)
    {
        dirs.push(path.to_path_buf());
    }
}

/// `temp_dir()/<name>`, created, and removed when the test process exits.
pub fn dir(name: impl AsRef<Path>) -> PathBuf {
    let d = std::env::temp_dir().join(name);
    let _ = std::fs::create_dir_all(&d);
    remember(&d);
    d
}

/// `temp_dir()/<name>` without creating it (for a caller that creates it, or a socket path),
/// removed at exit all the same.
pub fn path(name: impl AsRef<Path>) -> PathBuf {
    let d = std::env::temp_dir().join(name);
    remember(&d);
    d
}

#[cfg(test)]
mod tests {
    /// The hook is the part that matters, so it is exercised in a CHILD process: the child
    /// makes a recorded dir and exits; the parent sees it gone. An unrecorded control in the
    /// same child stays, so "gone" is the hook's doing, not a cleanup by the child.
    #[test]
    fn a_recorded_dir_is_removed_when_the_process_exits() {
        if std::env::var_os("TEST_SCRATCH_CHILD").is_some() {
            let tag = std::env::var("TEST_SCRATCH_CHILD").unwrap();
            super::dir(format!("tl-scratch-recorded-{tag}"));
            std::fs::create_dir_all(std::env::temp_dir().join(format!("tl-scratch-control-{tag}")))
                .unwrap();
            return;
        }
        let tag = format!("{}", std::process::id());
        let exe = std::env::current_exe().unwrap();
        let st = std::process::Command::new(exe)
            .args([
                "--exact",
                "test_scratch::tests::a_recorded_dir_is_removed_when_the_process_exits",
                "--test-threads=1",
            ])
            .env("TEST_SCRATCH_CHILD", &tag)
            .output()
            .unwrap();
        assert!(
            st.status.success(),
            "child: {}",
            String::from_utf8_lossy(&st.stdout)
        );
        let recorded = std::env::temp_dir().join(format!("tl-scratch-recorded-{tag}"));
        let control = std::env::temp_dir().join(format!("tl-scratch-control-{tag}"));
        let control_there = control.exists();
        let _ = std::fs::remove_dir_all(&control);
        assert!(
            control_there,
            "the unrecorded control should survive the child's exit"
        );
        assert!(
            !recorded.exists(),
            "a recorded dir survived the process that made it"
        );
    }
}
