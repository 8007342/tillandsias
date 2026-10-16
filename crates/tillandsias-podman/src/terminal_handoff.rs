//! ORDER 1741-xq7d — once an attached agent owns the terminal, this process
//! stops writing to it.
//!
//! THE DEFECT. The operator's lakanoa report (2026-10-15): while a Codex forge
//! ran, `[tillandsias] …` lines landed inside the Codex TUI and stayed there
//! until a window resize made Codex redraw. The forge image was not the writer
//! (its background jobs already log to /tmp/forge-lifecycle.log). The launcher
//! was: the CLI lane that runs `podman run -it` in the terminal ALSO serves the
//! lane's MCP socket from a thread (`prepare_forge_ram_workspace` →
//! `start_mcp_socket_server_for_lane`), so every publish_local / browser_open /
//! toolchain call the agent makes runs host code whose `eprintln!` — and whose
//! child `podman` invocations, which inherit stderr — write straight onto the
//! screen the agent is drawing.
//!
//! WHY THE FILE DESCRIPTORS, NOT THE WRITERS. There are over a hundred
//! `[tillandsias]` writers in the headless crate, plus the inherited stderr of
//! every child they spawn. Routing each one is a whack-a-mole the next writer
//! loses, and it cannot reach a child process at all. Pointing fd 1 and fd 2 at
//! a log file covers every writer, every thread and every child spawned during
//! the session, and it is undone in one place.
//!
//! THE ORDER MATTERS. The attached child is spawned FIRST, so it inherits the
//! real terminal; only then is this process's own stdout/stderr diverted. The
//! child keeps its own descriptors — a later dup2 in the parent does not touch
//! them. When the guard drops, the saved terminal descriptors come back, so the
//! post-session report (`exited`, `swap: stopped`, the failure diagnosis) is
//! printed where the user can read it.
//!
//! NOTHING IS LOST. The diverted bytes go to `log_dir()/attached-sessions/
//! <container>.log` (append), and [`TerminalHandoff::restore`] reports the path
//! once if anything was written.
//!
//! ONLY A TERMINAL IS DIVERTED. A stream that is a pipe or a file has a machine
//! reading it (the litmus runner, the delegated `codex exec` lane, a captured
//! smoke), and those readers rely on seeing these lines. A descriptor that is
//! not a TTY is left exactly as it was.
//!
//! Unix only: Windows attaches through a different console model and has no
//! equivalent of the shared-fd bleed; there the guard is a no-op.

use std::path::{Path, PathBuf};

/// The log a diverted session's host output goes to.
pub fn attached_session_log_path(container_name: &str) -> PathBuf {
    tillandsias_core::config::log_dir()
        .join("attached-sessions")
        .join(format!("{container_name}.log"))
}

/// While alive, this process's terminal stdout/stderr point at a log file.
/// Dropping it puts the terminal back.
#[must_use = "the terminal is handed back when the guard drops"]
pub struct TerminalHandoff {
    #[cfg(unix)]
    saved: Vec<(libc::c_int, libc::c_int)>,
    log: PathBuf,
    start_len: u64,
}

impl TerminalHandoff {
    /// Divert whichever of stdout/stderr is a terminal into `log`.
    ///
    /// Returns `None`, having changed nothing, when neither is a terminal, on
    /// a non-unix host, or when any step fails — a launch is never refused
    /// because its log could not be opened; the old behaviour is the fallback.
    pub fn divert(log: &Path) -> Option<Self> {
        Self::divert_fds(log, &[1, 2])
    }

    #[cfg(unix)]
    fn divert_fds(log: &Path, targets: &[i32]) -> Option<Self> {
        use std::os::fd::AsRawFd;

        // SAFETY: isatty only inspects the descriptor.
        let ttys: Vec<i32> = targets
            .iter()
            .copied()
            .filter(|fd| unsafe { libc::isatty(*fd) } == 1)
            .collect();
        if ttys.is_empty() {
            return None;
        }
        if let Some(dir) = log.parent() {
            std::fs::create_dir_all(dir).ok()?;
        }
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(log)
            .ok()?;
        let start_len = file.metadata().map(|m| m.len()).unwrap_or(0);

        // Flush what Rust still buffers for the terminal before the fd moves.
        use std::io::Write;
        let _ = std::io::stdout().flush();
        let _ = std::io::stderr().flush();

        let mut saved = Vec::with_capacity(ttys.len());
        for fd in ttys {
            // SAFETY: dup/dup2 on descriptors this process owns; every saved
            // copy is either restored and closed in Drop or closed here.
            let copy = unsafe { libc::dup(fd) };
            if copy < 0 || unsafe { libc::dup2(file.as_raw_fd(), fd) } < 0 {
                if copy >= 0 {
                    unsafe { libc::close(copy) };
                }
                // Undo what was already diverted, then fall back.
                drop(Self {
                    saved,
                    log: log.to_path_buf(),
                    start_len,
                });
                return None;
            }
            saved.push((fd, copy));
        }
        Some(Self {
            saved,
            log: log.to_path_buf(),
            start_len,
        })
    }

    #[cfg(not(unix))]
    fn divert_fds(_log: &Path, _targets: &[i32]) -> Option<Self> {
        None
    }

    /// Hand the terminal back and, if the session wrote anything, say where
    /// it went — on the terminal, now that the agent no longer owns it.
    pub fn restore(self) {
        let log = self.log.clone();
        let start_len = self.start_len;
        drop(self);
        let written = std::fs::metadata(&log)
            .map(|m| m.len().saturating_sub(start_len))
            .unwrap_or(0);
        if written > 0 {
            eprintln!(
                "[tillandsias] messages from during the session were kept out of it: {}",
                log.display()
            );
        }
    }
}

impl Drop for TerminalHandoff {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::io::Write;
            let _ = std::io::stdout().flush();
            let _ = std::io::stderr().flush();
            for (fd, copy) in self.saved.drain(..).rev() {
                // SAFETY: `copy` is the dup taken in divert_fds and is closed
                // exactly once, here.
                unsafe {
                    libc::dup2(copy, fd);
                    libc::close(copy);
                }
            }
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::io::Read;
    use std::os::fd::FromRawFd;
    use std::process::{Command, Stdio};

    const CHILD_ENV: &str = "TILLANDSIAS_TEST_TERMINAL_HANDOFF_CHILD";
    const CLIENT_FRAME: &str = "FAKE-CLIENT-FRAME";
    const CLIENT_DONE: &str = "FAKE-CLIENT-DONE";

    /// The host side of the fixture, run in a child process whose stdio is a
    /// real PTY. It does what the CLI lane does: spawn the attached client on
    /// the inherited terminal, hand the terminal off, keep emitting the host's
    /// messages from threads AND from a child process while the client runs,
    /// then take the terminal back.
    #[test]
    fn handoff_child_process() {
        let Ok(log) = std::env::var(CHILD_ENV) else {
            return; // only meaningful when launched by the fixture below
        };
        // Two FIFOs make the interleaving deterministic without sleeping: the
        // client says when it has drawn, the host says when it is done
        // writing, so every host line falls between FRAME and DONE.
        let dir = Path::new(&log).parent().expect("log has a parent");
        let (drawn, host_done) = (dir.join("drawn.fifo"), dir.join("host-done.fifo"));
        for fifo in [&drawn, &host_done] {
            let c = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
            // SAFETY: mkfifo on a fresh path in the fixture's scratch dir.
            assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0, "mkfifo");
        }
        // A fake full-screen client: enters the alternate screen, draws a
        // frame, holds the screen while the host is busy, then finishes.
        let mut client = Command::new("sh")
            .arg("-c")
            .arg(format!(
                "printf '\\033[?1049h{CLIENT_FRAME}\\n'; echo > \"$1\"; read _ < \"$2\"; printf '{CLIENT_DONE}\\n'"
            ))
            .arg("fake-client")
            .arg(&drawn)
            .arg(&host_done)
            .spawn()
            .expect("spawn fake client");
        // Blocks until the client has drawn its frame.
        std::fs::read(&drawn).expect("client signals it has drawn");
        // Option, not expect: with no handoff (today's behaviour) the fixture
        // must go red on the BLEED, in the parent's assertion.
        let handoff = TerminalHandoff::divert(Path::new(&log));

        // The writers 1741-xq7d names: progress (stdout), lock and
        // remote-project messages (stderr), from other threads, plus a child
        // process that inherits stderr the way the handlers' podman calls do.
        let threads: Vec<_> = [
            "progress: Getting your workspace ready… (1 of 5)",
            "waiting for 'forge-image' lock",
            "remote-projects: refreshed 3 projects",
        ]
        .into_iter()
        .map(|msg| {
            std::thread::spawn(move || {
                for _ in 0..3 {
                    if msg.starts_with("progress") {
                        println!("[tillandsias] {msg}");
                    } else {
                        eprintln!("[tillandsias] {msg}");
                    }
                }
            })
        })
        .collect();
        let _ = Command::new("sh")
            .arg("-c")
            .arg("echo '[tillandsias] from a handler child process' >&2")
            .status();
        for t in threads {
            t.join().expect("emitter thread");
        }
        std::fs::write(&host_done, b"\n").expect("release the client");
        client.wait().expect("fake client exits");
        if let Some(handoff) = handoff {
            handoff.restore();
        }
        eprintln!("[tillandsias] AFTER-SESSION");
    }

    /// 1741-xq7d exit criteria: the client's PTY receives no `[tillandsias]`
    /// byte while the client owns the screen, every message reaches the log,
    /// and the terminal is handed back afterwards.
    #[test]
    fn attached_client_pty_receives_no_host_lines_and_the_log_keeps_them() {
        let scratch = std::env::temp_dir().join(format!(
            "tillandsias-handoff-{}-{}",
            std::process::id(),
            chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
        ));
        std::fs::create_dir_all(&scratch).unwrap();
        let log = scratch.join("session.log");

        let (mut master, mut slave) = (0, 0);
        // SAFETY: openpty fills two fresh descriptors.
        let rc = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(rc, 0, "openpty failed");
        // SAFETY: each Stdio takes its own dup of the slave.
        let stdio = |fd: i32| unsafe { Stdio::from_raw_fd(libc::dup(fd)) };
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "terminal_handoff::tests::handoff_child_process",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(CHILD_ENV, &log)
            .stdin(stdio(slave))
            .stdout(stdio(slave))
            .stderr(stdio(slave))
            .spawn()
            .expect("spawn host side");
        unsafe { libc::close(slave) };

        // Read the PTY until the child closes it (EIO on Linux once the
        // slave side is gone).
        // SAFETY: master is ours and is owned by this File from here on.
        let mut master = unsafe { std::fs::File::from_raw_fd(master) };
        let mut bytes = Vec::new();
        let mut buf = [0u8; 4096];
        loop {
            match master.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => bytes.extend_from_slice(&buf[..n]),
            }
        }
        let status = child.wait().unwrap();
        let screen = String::from_utf8_lossy(&bytes).to_string();
        let logged = std::fs::read_to_string(&log).unwrap_or_default();
        let _ = std::fs::remove_dir_all(&scratch);
        assert!(status.success(), "host side failed; pty:\n{screen}");

        let start = screen
            .find(CLIENT_FRAME)
            .unwrap_or_else(|| panic!("the client never drew; pty:\n{screen}"));
        let end = screen
            .find(CLIENT_DONE)
            .unwrap_or_else(|| panic!("the client never finished; pty:\n{screen}"));
        let session = &screen[start..end];
        assert!(
            !session.contains("[tillandsias]"),
            "host lines reached the attached client's screen:\n{session}"
        );
        for msg in [
            "Getting your workspace ready",
            "waiting for 'forge-image' lock",
            "remote-projects: refreshed",
            "from a handler child process",
        ] {
            assert!(
                logged.contains(msg),
                "{msg:?} was lost — not in the session log:\n{logged}"
            );
        }
        let after = &screen[end..];
        assert!(
            after.contains("[tillandsias] AFTER-SESSION"),
            "the terminal was not handed back:\n{after}"
        );
        assert!(
            after.contains("kept out of it"),
            "restore did not say where the session's messages went:\n{after}"
        );
    }

    /// The fixture above proves the guard; this pins that the ONE attach path
    /// every interactive agent launch goes through actually holds it, and
    /// takes it only after the child has the terminal.
    #[test]
    fn the_attached_launch_hands_the_terminal_off_after_spawning() {
        // source-pin-ok: the ORDER spawn -> divert -> wait is the contract,
        // and it is only observable with a real podman attach; the PTY
        // fixture above is this test's behavioural negative control.
        let src = include_str!("client.rs");
        let body = src
            .split("pub async fn run_container_attached_status(")
            .nth(1)
            .expect("run_container_attached_status exists")
            .split("\n    pub ")
            .next()
            .unwrap();
        let spawn = body
            .find("cmd.spawn()")
            .expect("the attached child is spawned, not .status()'d");
        let divert = body
            .find("TerminalHandoff::divert(")
            .expect("the attached launch diverts the launcher's terminal output");
        let wait = body.find("child.wait()").expect("the child is awaited");
        assert!(
            spawn < divert && divert < wait,
            "spawn, then divert, then wait"
        );
        assert!(
            body.contains("handoff.restore()"),
            "the terminal is handed back"
        );
    }

    #[test]
    fn a_non_terminal_stream_is_left_alone() {
        // Under cargo test, fd 1/2 are pipes or files, never this PTY; a
        // machine reader keeps every line.
        let log = std::env::temp_dir().join(format!(
            "tillandsias-handoff-none-{}.log",
            std::process::id()
        ));
        // SAFETY: isatty only inspects.
        if unsafe { libc::isatty(1) } == 0 && unsafe { libc::isatty(2) } == 0 {
            assert!(TerminalHandoff::divert(&log).is_none());
            assert!(!log.exists(), "no log is created when nothing is diverted");
        }
    }
}
