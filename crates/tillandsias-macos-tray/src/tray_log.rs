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
//!
//! ORDER 1479-9hx6 — EVERY LINE IS TIMESTAMPED. tray.log lines used to be
//! "[tillandsias-tray] <message>" with no time (only the launch banner had an
//! epoch), so "seconds from sign-in to the handle in the menu" (1453-bnmt)
//! could not be read from the log. Now stdout and stderr go into a PIPE that
//! one relay thread reads line by line, writing each line to the file as
//! `<ISO-8601 UTC, ms> <line>`: no call site changes, and the
//! `[tillandsias-tray]` prefix and content are untouched after the stamp.
//! A pipe can lose buffered lines when the process dies, so: a panic hook
//! writes the panic message straight to the file (stamped), and an atexit
//! handler closes the pipe's write ends and waits for the relay to drain.

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

/// `2026-09-29T03:25:01.123Z` for `epoch_ms` milliseconds since the epoch
/// (UTC, proleptic Gregorian). Pure, so the format is unit-tested; no date
/// crate needed.
pub fn iso8601_utc_ms(epoch_ms: u64) -> String {
    let secs = epoch_ms / 1000;
    let ms = epoch_ms % 1000;
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let (h, m, sec) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    // civil_from_days (Howard Hinnant)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(mo <= 2);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{m:02}:{sec:02}.{ms:03}Z")
}

/// The line as written to tray.log: the stamp, one space, the line unchanged.
pub fn stamp_line(epoch_ms: u64, line: &str) -> String {
    format!("{} {line}", iso8601_utc_ms(epoch_ms))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

static RELAY: std::sync::Mutex<Option<std::thread::JoinHandle<()>>> = std::sync::Mutex::new(None);

extern "C" fn drain_relay_at_exit() {
    // Close our write ends (point 1 and 2 at /dev/null) so the relay sees EOF,
    // then wait for it to write out what is still buffered in the pipe.
    // SAFETY: plain fd operations on the process's standard descriptors.
    unsafe {
        let null = libc::open(c"/dev/null".as_ptr(), libc::O_WRONLY);
        if null >= 0 {
            libc::dup2(null, libc::STDOUT_FILENO);
            libc::dup2(null, libc::STDERR_FILENO);
            libc::close(null);
        }
    }
    if let Ok(mut slot) = RELAY.lock()
        && let Some(h) = slot.take()
    {
        let _ = h.join();
    }
}

/// Route stdout and stderr through a pipe whose relay thread stamps every line
/// into `path`. Falls back to [`redirect_std_streams_to`] (unstamped) if the
/// pipe or thread cannot be set up, so logging never stops the tray.
pub fn redirect_std_streams_stamped(path: &Path) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    rotate_if_over(path, MAX_BYTES)?;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    let mut fds = [0 as libc::c_int; 2];
    // SAFETY: pipe() fills two fds on success.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        drop(file);
        return redirect_std_streams_to(path);
    }
    let (read_fd, write_fd) = (fds[0], fds[1]);
    // SAFETY: we own read_fd; File takes it over and closes it on drop.
    let reader = unsafe { <std::fs::File as std::os::fd::FromRawFd>::from_raw_fd(read_fd) };
    let mut out = file.try_clone()?;
    let relay = std::thread::Builder::new()
        .name("tray-log-relay".into())
        .spawn(move || {
            use std::io::BufRead;
            let mut lines = std::io::BufReader::new(reader);
            let mut buf = Vec::new();
            loop {
                buf.clear();
                match lines.read_until(b'\n', &mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {
                        let text = String::from_utf8_lossy(&buf);
                        let text = text.strip_suffix('\n').unwrap_or(&text);
                        let _ = writeln!(out, "{}", stamp_line(now_ms(), text));
                    }
                }
            }
            let _ = out.flush();
        })?;
    for target in [libc::STDOUT_FILENO, libc::STDERR_FILENO] {
        // SAFETY: dup2 onto the standard descriptors; write_fd is valid.
        if unsafe { libc::dup2(write_fd, target) } < 0 {
            return Err(std::io::Error::last_os_error());
        }
    }
    // SAFETY: the duplicates on 1 and 2 keep the pipe open; drop the original.
    unsafe { libc::close(write_fd) };
    if let Ok(mut slot) = RELAY.lock() {
        *slot = Some(relay);
    }
    // SAFETY: registering a plain extern "C" fn.
    unsafe { libc::atexit(drain_relay_at_exit) };

    // A panic's message must not die in the pipe with the process: write it
    // straight to the file, stamped, then run the default hook (which writes
    // to the pipe as well).
    let direct = std::sync::Mutex::new(file);
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if let Ok(mut f) = direct.lock() {
            let _ = writeln!(
                f,
                "{}",
                stamp_line(now_ms(), &format!("[tillandsias-tray] PANIC: {info}"))
            );
            let _ = f.flush();
        }
        default_hook(info);
    }));
    Ok(())
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
    if redirect_std_streams_stamped(&path).is_ok() {
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

    /// 1479-9hx6: ISO-8601 UTC with milliseconds, checked against known
    /// instants (the epoch, a leap day, and today's measurement).
    #[test]
    fn iso8601_utc_ms_matches_known_instants() {
        assert_eq!(iso8601_utc_ms(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso8601_utc_ms(951_782_400_000), "2000-02-29T00:00:00.000Z");
        // 2026-09-29T01:43:23.456Z
        assert_eq!(
            iso8601_utc_ms(1_790_646_203_456),
            "2026-09-29T01:43:23.456Z"
        );
    }

    /// End to end in a CHILD process (the relay rewires fds 1/2 for the whole
    /// process): normal lines, a line written just before exit, and a panic
    /// must all reach the file, stamped.
    #[test]
    fn relay_stamps_every_line_and_loses_nothing_at_exit_or_panic() {
        if std::env::var_os("TRAY_LOG_RELAY_CHILD").is_some() {
            let path = std::path::PathBuf::from(std::env::var("TRAY_LOG_RELAY_CHILD").unwrap());
            redirect_std_streams_stamped(&path).expect("redirect");
            println!("[tillandsias-tray] first line");
            eprintln!("[tillandsias-tray] second line");
            if std::env::var_os("TRAY_LOG_RELAY_PANIC").is_some() {
                panic!("boom-for-the-log");
            }
            eprintln!("[tillandsias-tray] last line before exit");
            std::process::exit(0);
        }
        for (tag, panic) in [("exit", false), ("panic", true)] {
            let dir =
                std::env::temp_dir().join(format!("tray-log-relay-{tag}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            let log = dir.join("tray.log");
            let mut cmd = std::process::Command::new(std::env::current_exe().unwrap());
            cmd.args([
                "tray_log::tests::relay_stamps_every_line_and_loses_nothing_at_exit_or_panic",
                "--exact",
                "--nocapture",
            ])
            .env("TRAY_LOG_RELAY_CHILD", &log);
            if panic {
                cmd.env("TRAY_LOG_RELAY_PANIC", "1");
            }
            let _ = cmd.output().expect("child runs");
            let text = std::fs::read_to_string(&log).expect("log written");
            let stamped = |needle: &str| {
                text.lines().any(|l| {
                    l.len() > 25
                        && l.as_bytes()[4] == b'-'
                        && l[..24].ends_with('Z')
                        && l[25..].contains(needle)
                })
            };
            assert!(stamped("[tillandsias-tray] first line"), "{tag}: {text}");
            assert!(stamped("[tillandsias-tray] second line"), "{tag}: {text}");
            if panic {
                assert!(
                    stamped("PANIC: ") && text.contains("boom-for-the-log"),
                    "{tag}: {text}"
                );
            } else {
                assert!(stamped("last line before exit"), "{tag}: {text}");
            }
            let _ = std::fs::remove_dir_all(&dir);
        }
    }

    /// The stamp precedes the line and the line is otherwise untouched, so
    /// greps for "[tillandsias-tray] github-login" keep matching.
    #[test]
    fn stamped_line_keeps_the_prefix_and_content() {
        let l = stamp_line(0, "[tillandsias-tray] github-login: menu_state updated");
        assert_eq!(
            l,
            "1970-01-01T00:00:00.000Z [tillandsias-tray] github-login: menu_state updated"
        );
    }

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
