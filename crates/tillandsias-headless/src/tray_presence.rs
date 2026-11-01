//! ORDER 1944-trsp — one tray per enclave, and a CLI that can tell.
//!
//! lenovinha 2026-11-01: `--studio comfyui` spawned a tray companion although a
//! tray had run for 16 h. The CLI judged presence by `connect()` to
//! `control.sock`, and that socket was gone: a tray's start removed any
//! existing `control.sock` and bound its own, and its graceful exit removed the
//! path again, so a second tray start (here at 20:52Z the day before, seen in
//! `launcher.lock`/`msg.sock` mtimes) left the live tray listening on an
//! unlinked socket — alive and unreachable. The companion then ran its start
//! (schedulers, the vault probe that recreates the vault) before the D-Bus
//! singleton check could refuse it.
//!
//! The fix is a lifetime lock that a socket cannot lose: the tray takes an
//! exclusive `flock` on `tray.lock` as its FIRST act and holds it until exit;
//! the kernel drops it when the process dies, so it is never stale. A second
//! tray that cannot take it refuses before any side effect, and the CLI reads
//! it to tell "no tray" from "a tray whose socket is gone".
// @trace order:1944-trsp, spec:singleton-guard, spec:tray-host-control-socket

use std::path::{Path, PathBuf};

pub(crate) const LOCK_FILE: &str = "tray.lock";

/// What the CLI found before deciding whether to start a tray companion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Presence {
    /// A tray answers on its control socket: attach to it.
    Listening,
    /// A tray holds the lock but its control socket does not answer. Never
    /// spawn a second tray over it.
    AliveWithoutSocket { pid: Option<u32> },
    /// No tray: a companion may be started.
    Absent,
}

pub(crate) fn lock_path(dir: &Path) -> PathBuf {
    dir.join(LOCK_FILE)
}

/// Held for the tray's lifetime; dropping it (or the process dying) releases it.
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
#[derive(Debug)]
pub(crate) struct TrayLock {
    #[allow(dead_code)]
    file: std::fs::File,
}

#[cfg(unix)]
fn try_flock(file: &std::fs::File) -> Result<bool, std::io::Error> {
    use std::os::fd::AsRawFd as _;
    // SAFETY: a valid open descriptor; LOCK_NB never blocks.
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc == 0 {
        return Ok(true);
    }
    let err = std::io::Error::last_os_error();
    if err.raw_os_error() == Some(libc::EWOULDBLOCK) {
        Ok(false)
    } else {
        Err(err)
    }
}

fn holder_pid(dir: &Path) -> Option<u32> {
    std::fs::read_to_string(lock_path(dir))
        .ok()
        .and_then(|s| s.trim().parse().ok())
}

/// Take the tray lock in `dir`, or refuse naming the tray that holds it.
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
#[cfg(unix)]
pub(crate) fn acquire(dir: &Path) -> Result<TrayLock, String> {
    use std::io::Write as _;
    std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let path = lock_path(dir);
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    match try_flock(&file) {
        Ok(true) => {
            let _ = file.set_len(0);
            let _ = write!(file, "{}", std::process::id());
            Ok(TrayLock { file })
        }
        Ok(false) => Err(format!(
            "another tray already owns this enclave ({}); this one exits without touching it",
            holder_pid(dir).map_or_else(|| "pid unknown".to_string(), |p| format!("pid {p}"))
        )),
        Err(e) => Err(format!("{}: flock: {e}", path.display())),
    }
}

#[cfg_attr(not(feature = "tray"), allow(dead_code))]
#[cfg(not(unix))]
pub(crate) fn acquire(dir: &Path) -> Result<TrayLock, String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let path = lock_path(dir);
    let file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(&path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(TrayLock { file })
}

#[cfg_attr(not(feature = "tray"), allow(dead_code))]
#[cfg(unix)]
/// Bind the control socket at `path`, replacing only a STALE file: one that
/// still answers belongs to a live tray, and unlinking it is what left the
/// 16 h tray unreachable on 2026-11-01.
pub(crate) fn bind_control_socket(path: &Path) -> Result<std::os::unix::net::UnixListener, String> {
    use std::os::unix::net::{UnixListener, UnixStream};
    if path.exists() {
        if UnixStream::connect(path).is_ok() {
            return Err(format!(
                "control socket {} is served by another process; not replacing it",
                path.display()
            ));
        }
        std::fs::remove_file(path)
            .map_err(|err| format!("failed to remove stale control socket: {err}"))?;
    }
    UnixListener::bind(path).map_err(|err| format!("failed to bind control socket: {err}"))
}

/// Whether a tray holds the lock in `dir`, without keeping it.
#[cfg(unix)]
fn lock_is_held(dir: &Path) -> bool {
    let Ok(file) = std::fs::OpenOptions::new().read(true).open(lock_path(dir)) else {
        return false;
    };
    // Taking it means nobody held it; the lock drops with `file` here.
    matches!(try_flock(&file), Ok(false))
}

#[cfg(not(unix))]
fn lock_is_held(_dir: &Path) -> bool {
    false
}

/// The CLI's presence check: the socket answers, or the lock says a tray lives.
pub(crate) fn presence(dir: &Path, socket_listening: bool) -> Presence {
    if socket_listening {
        Presence::Listening
    } else if lock_is_held(dir) {
        Presence::AliveWithoutSocket {
            pid: holder_pid(dir),
        }
    } else {
        Presence::Absent
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        let d = PathBuf::from("/dev/shm").join(format!("trsp-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    /// The exact 2026-11-01 case: a live tray holds the lock and its control
    /// socket path is GONE (a second tray's start and exit unlinked it). The
    /// CLI must see a live tray and never spawn; a second tray must refuse.
    #[test]
    fn a_live_tray_whose_socket_was_unlinked_is_still_seen_and_never_doubled() {
        let dir = scratch("unlinked");
        let live = acquire(&dir).expect("the first tray takes the lock");
        assert!(
            !dir.join("control.sock").exists(),
            "no socket, as on lenovinha"
        );

        // Pre-fix decision: connect() failed, so the CLI spawned a companion.
        assert_eq!(
            presence(&dir, false),
            Presence::AliveWithoutSocket {
                pid: Some(std::process::id())
            }
        );
        let second = acquire(&dir).unwrap_err();
        assert!(second.contains("another tray already owns"), "{second}");

        // Once the live tray exits, its lock is gone with it: a new tray starts.
        drop(live);
        assert_eq!(presence(&dir, false), Presence::Absent);
        let next = acquire(&dir).expect("lock is free after the owner exits");
        // A listening socket always means attach.
        assert_eq!(presence(&dir, true), Presence::Listening);
        drop(next);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The 10-31 chain: tray A is live (lock + socket); tray B starts and is
    /// refused; A's control.sock still answers afterwards. Pre-fix B unlinked
    /// and rebound the socket and its exit removed the path.
    #[test]
    fn a_refused_second_tray_leaves_the_first_trays_socket_answering() {
        use std::os::unix::net::UnixStream;
        let dir = scratch("chain");
        let sock = dir.join("control.sock");
        let _a_lock = acquire(&dir).expect("tray A takes the lock");
        let _a_listener = bind_control_socket(&sock).expect("tray A binds its socket");
        assert!(UnixStream::connect(&sock).is_ok(), "A answers");

        // Tray B: refused at the lock, its first act, so it never reaches the
        // socket; and the bind guard refuses it even if it did.
        assert!(acquire(&dir).is_err());
        let b = bind_control_socket(&sock).unwrap_err();
        assert!(b.contains("served by another process"), "{b}");

        assert!(
            UnixStream::connect(&sock).is_ok(),
            "A still answers after B"
        );
        assert_eq!(presence(&dir, true), Presence::Listening);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A stale socket file (its tray died) is replaced; the guard only
    /// protects a socket that answers.
    #[test]
    fn a_stale_socket_file_is_replaced() {
        let dir = scratch("stale");
        std::fs::create_dir_all(&dir).unwrap();
        let sock = dir.join("control.sock");
        drop(bind_control_socket(&sock).unwrap());
        assert!(sock.exists(), "the dead listener left its file");
        assert!(bind_control_socket(&sock).is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn no_lock_file_means_no_tray() {
        let dir = scratch("absent");
        assert_eq!(presence(&dir, false), Presence::Absent);
    }
}
