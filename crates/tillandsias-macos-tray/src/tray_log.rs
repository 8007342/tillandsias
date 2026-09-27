//! ORDER 1420-inak — the macOS tray writes a log a user can send.
//!
//! Until this module the tray wrote NO log file. It ships as an LSUIElement
//! .app launched from Finder, `open -a` or a LaunchAgent, so it has no
//! controlling terminal; every `eprintln!` went nowhere, and the failure menu's
//! "Open log" opened `~/Library/Logs/Tillandsias`, a directory nothing wrote to.
//! A user's clean MacBook failed first provisioning on 2026-09-27 and there was
//! nothing to ask them for.
//!
//! In GUI mode (stderr is not a terminal) the tray now points its stdout and
//! stderr at `~/Library/Logs/Tillandsias/tray.log`, so every existing
//! `eprintln!` lands there without touching a call site. Bounded like
//! console.log: past [`MAX_BYTES`] the file rotates to `tray.log.1` at startup,
//! two generations total. Run from a terminal, nothing is redirected.

use std::io::{IsTerminal, Write};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

/// Rotate at startup once the log exceeds this many bytes.
pub const MAX_BYTES: u64 = 4 * 1024 * 1024;

/// `~/Library/Logs/Tillandsias/tray.log`, or `None` without a HOME.
pub fn tray_log_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Logs/Tillandsias/tray.log"))
}

/// Move `path` to `<path>.1` (replacing an older `.1`) when it is larger than
/// `max`. Returns whether it rotated. A missing file is not an error.
pub fn rotate_if_over(path: &Path, max: u64) -> std::io::Result<bool> {
    match std::fs::metadata(path) {
        Ok(m) if m.len() > max => {
            let mut prev = path.as_os_str().to_owned();
            prev.push(".1");
            std::fs::rename(path, PathBuf::from(prev))?;
            Ok(true)
        }
        Ok(_) => Ok(false),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

/// Open `path` for append and make it the process's stdout and stderr.
pub fn redirect_std_streams_to(path: &Path) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    rotate_if_over(path, MAX_BYTES)?;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    let fd = file.as_raw_fd();
    // SAFETY: dup2 onto the standard descriptors; `fd` is valid for the call and
    // the duplicates outlive `file`, which is then dropped (closing only `fd`).
    for target in [libc::STDOUT_FILENO, libc::STDERR_FILENO] {
        if unsafe { libc::dup2(fd, target) } < 0 {
            return Err(std::io::Error::last_os_error());
        }
    }
    Ok(())
}

/// GUI-mode entry point: redirect when stderr is not a terminal, then write a
/// header so each launch is findable in the file. Best-effort: a logging
/// failure must never stop the tray.
pub fn install_for_gui_mode(version_line: &str) {
    if std::io::stderr().is_terminal() {
        return;
    }
    let Some(path) = tray_log_path() else { return };
    if redirect_std_streams_to(&path).is_ok() {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let _ = writeln!(
            std::io::stderr(),
            "\n[tillandsias-tray] ===== launch epoch={now} {version_line} ====="
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotates_only_past_the_limit_and_keeps_two_generations() {
        let dir = std::env::temp_dir().join(format!("tray-log-rot-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("tray.log");
        assert!(
            !rotate_if_over(&log, 10).unwrap(),
            "a missing log is not rotated"
        );
        std::fs::write(&log, b"0123456789").unwrap();
        assert!(
            !rotate_if_over(&log, 10).unwrap(),
            "exactly at the limit stays"
        );
        std::fs::write(&log, b"0123456789AB").unwrap();
        assert!(rotate_if_over(&log, 10).unwrap(), "past the limit rotates");
        assert!(!log.exists());
        assert_eq!(
            std::fs::read(dir.join("tray.log.1")).unwrap(),
            b"0123456789AB"
        );
        std::fs::write(&log, b"newer-and-longer").unwrap();
        assert!(rotate_if_over(&log, 10).unwrap());
        assert_eq!(
            std::fs::read(dir.join("tray.log.1")).unwrap(),
            b"newer-and-longer",
            "an older .1 is replaced: two generations, never unbounded"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_log_lives_where_open_log_looks() {
        let p = tray_log_path().expect("HOME is set in tests");
        assert!(
            p.ends_with("Library/Logs/Tillandsias/tray.log"),
            "{}",
            p.display()
        );
    }
}
