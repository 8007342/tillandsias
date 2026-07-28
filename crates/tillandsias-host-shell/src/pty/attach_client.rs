//! In-terminal attach client — the process that OWNS the operator-facing
//! terminal for a tray PTY attach.
//!
//! The working platforms delegate the whole terminal contract to a real
//! client living inside the window (Linux native: podman inherits the
//! emulator's tty; Windows: wt.exe + wsl.exe bridge ConPTY events). The
//! macOS tray used to interpose `screen <slave>` — a serial-line attach
//! with no winsize concept, no resize forwarding, and no mode hygiene —
//! which is why terminal management never traveled the macOS chain
//! (plan/issues/macos-terminal-management-audit-2026-07-27.md, D1/D4).
//!
//! This module is that missing client. Terminal.app runs
//! `tillandsias-tray --attach-pty <slave> --session-sock <sock>`, which:
//!
//! 1. saves + `cfmakeraw`s its OWN controlling tty (the sanctioned place
//!    for host-side raw mode — the conduit; the guest keeps `ISIG` and owns
//!    signals), restoring on exit;
//! 2. pumps `/dev/tty` ↔ the tray's PTY slave byte-transparently;
//! 3. sends `Hello{rows,cols}` on the session socket at startup (the tray
//!    gates `PtyOpen` on it — event-driven initial geometry, no seed poll)
//!    and, on each real `SIGWINCH`, stamps `TIOCSWINSZ` on the slave and
//!    sends `Resize{rows,cols}` (event-driven live resize, no poll);
//! 4. emits a scoped mode reset (mouse reporting off, alt-screen off,
//!    cursor visible) at entry and exit so a crashed TUI's modes never
//!    leak across sessions;
//! 5. exits on slave EOF (session over) or tty EOF/HUP (window closed) —
//!    the socket disconnect is the tray's detach signal to `PtyClose` the
//!    guest child (no orphaned harnesses).
//!
//! The 5-byte session-socket protocol and the reset string are pure
//! functions compiled on every target so the Linux dev box and the Windows
//! probe build unit-test them; only the engine is `cfg(unix)`.
//!
//! No polling anywhere: geometry moves on `SIGWINCH` events, teardown on
//! EOF — per the no-polling policy (podman-idiomatic-patterns no-polling@v1,
//! no-terminal-flicker Req 7).
//!
//! @trace spec:macos-native-tray.lifecycle.terminal-attach@v2,
//!        spec:macos-native-tray.invariant.terminal-attach-no-ssh,
//!        plan/issues/macos-terminal-management-audit-2026-07-27.md

// ─── session-socket protocol (pure; compiled + tested on every target) ────

/// Fixed length of every session-socket message: 1 tag byte + rows u16 BE
/// + cols u16 BE. Fixed-size framing keeps both ends trivially correct.
pub const SESSION_MSG_LEN: usize = 5;

const TAG_HELLO: u8 = b'H';
const TAG_RESIZE: u8 = b'R';

/// A message from the attach client to the tray on the per-session socket.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionMsg {
    /// Sent exactly once at startup: the terminal's true geometry. The tray
    /// gates `PtyOpen` on this (replacing the former 100ms seed poll).
    Hello { rows: u16, cols: u16 },
    /// Sent per `SIGWINCH`: the terminal's new geometry. The tray forwards
    /// it as a wire `PtyResize` (replacing the former 400ms winsize poll).
    Resize { rows: u16, cols: u16 },
}

/// Encode a [`SessionMsg::Hello`].
pub fn encode_hello(rows: u16, cols: u16) -> [u8; SESSION_MSG_LEN] {
    encode(TAG_HELLO, rows, cols)
}

/// Encode a [`SessionMsg::Resize`].
pub fn encode_resize(rows: u16, cols: u16) -> [u8; SESSION_MSG_LEN] {
    encode(TAG_RESIZE, rows, cols)
}

fn encode(tag: u8, rows: u16, cols: u16) -> [u8; SESSION_MSG_LEN] {
    let r = rows.to_be_bytes();
    let c = cols.to_be_bytes();
    [tag, r[0], r[1], c[0], c[1]]
}

/// Decode one fixed-size session-socket message. `None` = protocol
/// violation (unknown tag); the tray treats that as a detach.
pub fn decode_session_msg(buf: &[u8; SESSION_MSG_LEN]) -> Option<SessionMsg> {
    let rows = u16::from_be_bytes([buf[1], buf[2]]);
    let cols = u16::from_be_bytes([buf[3], buf[4]]);
    match buf[0] {
        TAG_HELLO => Some(SessionMsg::Hello { rows, cols }),
        TAG_RESIZE => Some(SessionMsg::Resize { rows, cols }),
        _ => None,
    }
}

/// Scoped terminal-state reset emitted at the attach/detach boundaries:
/// mouse reporting off (DECRST 1000/1002/1003/1006/1007), leave the
/// alternate screen (DECRST 1049), cursor visible (DECSET 25). This is the
/// prior-art PRIMARY fix for the scroll→arrow-key spill enabler — scoped to
/// boundaries only, so interactive TUIs re-enable their own modes
/// (plan/issues/macos-tray-scroll-arrowkey-spill-during-build-2026-07-23.md;
/// blanket `ti@:te@` stays rejected).
pub const MODE_RESET: &str =
    "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?1007l\u{1b}[?1049l\u{1b}[?25h";

// ─── engine (unix-only: termios/ioctl/SIGWINCH) ───────────────────────────

#[cfg(unix)]
pub use engine::run;

#[cfg(unix)]
mod engine {
    use super::*;
    use crate::pty::unix::{
        fd_restore_termios, fd_save_termios, fd_set_raw, fd_set_winsize, fd_winsize,
    };
    use std::io::{Read, Write};
    use std::os::unix::fs::OpenOptionsExt;
    use std::os::unix::io::AsRawFd;

    /// `O_NOCTTY`: never acquire the opened tty as our controlling terminal
    /// — the client's controlling tty must stay the Terminal.app window so
    /// SIGWINCH keeps flowing to us, not to the slave session.
    #[cfg(target_os = "macos")]
    const O_NOCTTY: i32 = 0x2_0000;
    #[cfg(not(target_os = "macos"))]
    const O_NOCTTY: i32 = 0o400;

    /// Why the byte pumps stopped — decides the operator-facing exit note.
    enum PumpEnd {
        /// Slave EOF/EIO: the tray closed the master — session over.
        SessionOver,
        /// Terminal tty EOF/error: the window is going away.
        TerminalGone,
    }

    /// Run the attach client until the session ends. Returns the process
    /// exit code. Blocking by design — the caller is a dedicated CLI mode.
    pub fn run(slave_path: &str, sock_path: &str) -> i32 {
        // The controlling tty: fd 0 for termios/winsize ioctls (per-device,
        // not per-fd), fresh /dev/tty handles for the byte pumps.
        let tty_fd = std::io::stdin().as_raw_fd();
        let initial = match fd_winsize(tty_fd) {
            Ok(sz) => sz,
            Err(e) => {
                eprintln!("tillandsias attach-pty: stdin is not a terminal ({e})");
                return 2;
            }
        };

        let mut slave_w = match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(O_NOCTTY)
            .open(slave_path)
        {
            Ok(f) => f,
            Err(e) => {
                eprintln!("tillandsias attach-pty: cannot open {slave_path}: {e}");
                return 2;
            }
        };
        let mut slave_r = match slave_w.try_clone() {
            Ok(f) => f,
            Err(e) => {
                eprintln!("tillandsias attach-pty: fd clone failed: {e}");
                return 2;
            }
        };
        let slave_fd = slave_w.as_raw_fd();

        // Session socket: geometry events out, disconnect = detach signal.
        // A missing tray listener degrades to a pump-only session (bytes
        // still flow; the tray falls back to its bounded Hello timeout).
        // Writes carry a bounded timeout: this socket is written from the
        // event loop, and an unbounded blocking write against a wedged
        // tray would freeze SIGWINCH + teardown handling (review F3) —
        // a timed-out/failed write demotes to pump-only instead.
        let mut sock = match std::os::unix::net::UnixStream::connect(sock_path) {
            Ok(s) => {
                let _ = s.set_write_timeout(Some(std::time::Duration::from_secs(1)));
                Some(s)
            }
            Err(e) => {
                eprintln!(
                    "tillandsias attach-pty: session socket unavailable ({e}); resize events disabled"
                );
                None
            }
        };

        // Initial geometry: stamp the pair, tell the tray (gates PtyOpen).
        let _ = fd_set_winsize(slave_fd, initial.0, initial.1);
        let hello_failed = sock
            .as_mut()
            .is_some_and(|s| s.write_all(&encode_hello(initial.0, initial.1)).is_err());
        if hello_failed {
            sock = None;
        }

        let mut tty_out = match std::fs::OpenOptions::new().write(true).open("/dev/tty") {
            Ok(f) => f,
            Err(e) => {
                eprintln!("tillandsias attach-pty: /dev/tty open failed: {e}");
                return 2;
            }
        };
        let tty_in = match std::fs::OpenOptions::new().read(true).open("/dev/tty") {
            Ok(f) => f,
            Err(e) => {
                eprintln!("tillandsias attach-pty: /dev/tty open failed: {e}");
                return 2;
            }
        };

        // Boundary hygiene BEFORE raw mode: clear any leftover mouse/alt-
        // screen state from a previous occupant of this window.
        let _ = tty_out.write_all(MODE_RESET.as_bytes());
        let _ = tty_out.flush();

        // Raw mode on OUR tty — the transparent-conduit end. Ctrl+C is a
        // 0x03 byte here; the guest line discipline (which keeps ISIG) owns
        // turning it into SIGINT for the harness.
        let saved = match fd_save_termios(tty_fd) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("tillandsias attach-pty: tcgetattr failed: {e}");
                return 2;
            }
        };
        if let Err(e) = fd_set_raw(tty_fd) {
            eprintln!("tillandsias attach-pty: raw mode failed: {e}");
            return 2;
        }

        // Byte pumps. Detached threads; the process exits when either side
        // ends, which tears the other down with it.
        let (done_tx, mut done_rx) = tokio::sync::mpsc::unbounded_channel::<PumpEnd>();

        let done_in = done_tx.clone();
        let mut tty_in = tty_in;
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match tty_in.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if slave_w.write_all(&buf[..n]).is_err() {
                            let _ = done_in.send(PumpEnd::SessionOver);
                            return;
                        }
                    }
                }
            }
            let _ = done_in.send(PumpEnd::TerminalGone);
        });

        let done_out = done_tx;
        let mut pump_out = match tty_out.try_clone() {
            Ok(f) => f,
            Err(e) => {
                let _ = fd_restore_termios(tty_fd, &saved);
                eprintln!("tillandsias attach-pty: fd clone failed: {e}");
                return 2;
            }
        };
        std::thread::spawn(move || {
            let mut buf = [0u8; 16 * 1024];
            loop {
                match slave_r.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if pump_out.write_all(&buf[..n]).is_err() || pump_out.flush().is_err() {
                            let _ = done_out.send(PumpEnd::TerminalGone);
                            return;
                        }
                    }
                }
            }
            let _ = done_out.send(PumpEnd::SessionOver);
        });

        // Event loop: SIGWINCH → stamp + notify; pump end → clean exit.
        // A current-thread runtime purely for the signal driver — no timers,
        // no polling.
        let rt = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(e) => {
                let _ = fd_restore_termios(tty_fd, &saved);
                eprintln!("tillandsias attach-pty: runtime: {e}");
                return 2;
            }
        };
        let end = rt.block_on(async {
            let mut winch =
                match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change())
                {
                    Ok(w) => w,
                    Err(_) => {
                        // No signal driver: live resize degrades, bytes still flow.
                        return done_rx.recv().await.unwrap_or(PumpEnd::SessionOver);
                    }
                };
            // TOCTOU catch-up (review F7): a SIGWINCH delivered between the
            // Hello snapshot and the registration above was discarded by the
            // default disposition — one event-driven re-read closes the gap
            // (Terminal.app often settles its window geometry asynchronously
            // right after `do script`).
            match fd_winsize(tty_fd) {
                Ok((rows, cols)) if (rows, cols) != initial && rows > 0 && cols > 0 => {
                    let _ = fd_set_winsize(slave_fd, rows, cols);
                    let tray_gone = sock
                        .as_mut()
                        .is_some_and(|s| s.write_all(&encode_resize(rows, cols)).is_err());
                    if tray_gone {
                        sock = None;
                    }
                }
                _ => {}
            }
            loop {
                tokio::select! {
                    _ = winch.recv() => {
                        if let Ok((rows, cols)) = fd_winsize(tty_fd) {
                            let _ = fd_set_winsize(slave_fd, rows, cols);
                            let tray_gone = sock
                                .as_mut()
                                .is_some_and(|s| s.write_all(&encode_resize(rows, cols)).is_err());
                            if tray_gone {
                                sock = None; // tray gone; keep pumping bytes
                            }
                        }
                    }
                    end = done_rx.recv() => {
                        return end.unwrap_or(PumpEnd::SessionOver);
                    }
                }
            }
        });

        // Teardown: cooked tty back, boundary reset, one clean newline so
        // the wrapper's end-of-session banner starts at column 0.
        let _ = fd_restore_termios(tty_fd, &saved);
        let _ = tty_out.write_all(MODE_RESET.as_bytes());
        let _ = tty_out.write_all(b"\r\n");
        let _ = tty_out.flush();
        match end {
            PumpEnd::SessionOver | PumpEnd::TerminalGone => 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Hello/Resize survive an encode→decode roundtrip at boundary values.
    #[test]
    fn session_msg_roundtrip() {
        for (rows, cols) in [(24u16, 80u16), (1, 1), (u16::MAX, u16::MAX), (30, 120)] {
            assert_eq!(
                decode_session_msg(&encode_hello(rows, cols)),
                Some(SessionMsg::Hello { rows, cols })
            );
            assert_eq!(
                decode_session_msg(&encode_resize(rows, cols)),
                Some(SessionMsg::Resize { rows, cols })
            );
        }
    }

    /// Unknown tags are a protocol violation, not a panic — the tray maps
    /// `None` to detach.
    #[test]
    fn unknown_tag_decodes_to_none() {
        assert_eq!(decode_session_msg(&[b'X', 0, 24, 0, 80]), None);
        assert_eq!(decode_session_msg(&[0, 0, 0, 0, 0]), None);
    }

    /// The boundary reset must clear every mouse-reporting mode, leave the
    /// alternate screen, and re-show the cursor — and nothing else (no
    /// blanket alt-screen disable; TUIs re-enable their own modes).
    #[test]
    fn mode_reset_covers_mouse_altscreen_cursor() {
        for seq in [
            "\u{1b}[?1000l",
            "\u{1b}[?1002l",
            "\u{1b}[?1003l",
            "\u{1b}[?1006l",
            "\u{1b}[?1007l",
            "\u{1b}[?1049l",
            "\u{1b}[?25h",
        ] {
            assert!(MODE_RESET.contains(seq), "missing {seq:?} in MODE_RESET");
        }
        // Scoped reset only: never permanently disable modes (no DECSET of
        // mouse modes, no termcap surgery).
        assert!(!MODE_RESET.contains("1049h"), "must not ENTER alt-screen");
    }

    /// Messages are fixed-size — both ends rely on it for framing.
    #[test]
    fn messages_are_fixed_size() {
        assert_eq!(encode_hello(24, 80).len(), SESSION_MSG_LEN);
        assert_eq!(encode_resize(50, 200).len(), SESSION_MSG_LEN);
    }
}
