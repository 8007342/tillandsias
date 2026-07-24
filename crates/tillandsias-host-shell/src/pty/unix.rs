//! Unix `openpty(3)` backend for the host-side PTY (`control-wire-pty-attach`
//! §3.2). Shared by macOS (AppKit Terminal) and any future Linux native-tray
//! variant that needs a host PTY — both kernels expose the same syscall, so
//! this backend is `#[cfg(unix)]` rather than `#[cfg(target_os = "macos")]`.
//!
//! Counterpart to `pty::windows::ConPtyMaster` (the ConPTY backend). The
//! Unix path is markedly simpler: `openpty` returns a (master, slave) fd
//! pair, the master goes into a `tokio::io::unix::AsyncFd` for reactor
//! readiness, and `split()` hands out two halves that share an
//! `Arc<AsyncFd<…>>` for concurrent read+write on the same fd. The slave
//! fd is kept alive on the master struct so the PTY pair doesn't EOF when
//! the caller hands off the slave path to a child process (or the macOS
//! tray's Terminal.app wrapper).
//!
//! @trace openspec/changes/control-wire-pty-attach/proposal.md, spec:vsock-transport

#![cfg(unix)]

use std::io;
use std::os::raw::{c_char, c_int};
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf, unix::AsyncFd};

/// `openpty(3)` errors plus our own slave-path query failures.
#[derive(Debug)]
pub enum UnixPtyError {
    OpenPty(io::Error),
    Fcntl(io::Error),
    Ptsname(io::Error),
    Utf8(std::str::Utf8Error),
}

impl std::fmt::Display for UnixPtyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::OpenPty(e) => write!(f, "openpty(3) failed: {e}"),
            Self::Fcntl(e) => write!(f, "fcntl(O_NONBLOCK) failed: {e}"),
            Self::Ptsname(e) => write!(f, "ptsname failed: {e}"),
            Self::Utf8(e) => write!(f, "slave path is not valid UTF-8: {e}"),
        }
    }
}

impl std::error::Error for UnixPtyError {}

/// Host-side Unix PTY master + retained slave. The slave fd is held so the
/// kernel keeps the PTY pair open even after the master is split — the
/// caller (e.g. the macOS tray's `terminal_attach`) hands the slave's
/// `/dev/ttys*` path to Terminal.app via a small wrapper that re-opens it.
pub struct UnixPtyMaster {
    /// Shared so `split()` can hand both halves concurrent access. AsyncFd
    /// itself only needs `&self` for poll_read_ready / poll_write_ready.
    master: Arc<AsyncFd<FdHolder>>,
    /// Retained slave fd. Drop the master object to close BOTH ends.
    _slave: OwnedFd,
    /// `/dev/ttys*` path of the slave side. Set on construction so the
    /// caller can open it again to attach a terminal app or child process.
    slave_path: String,
}

/// Non-owning `AsRawFd` for `AsyncFd`. The underlying fd's actual lifetime
/// is governed by the master `OwnedFd` we wrap in `Arc<AsyncFd<FdHolder>>`
/// — see notes on `transport_macos::FdHolder`.
struct FdHolder {
    owned: OwnedFd,
}

impl AsRawFd for FdHolder {
    fn as_raw_fd(&self) -> RawFd {
        self.owned.as_raw_fd()
    }
}

impl UnixPtyMaster {
    /// Allocate a new PTY pair, set the master non-blocking, and return a
    /// handle ready to be `split()` into `PtyMaster` halves.
    ///
    /// `rows` and `cols` set the initial window size; sender should also
    /// call `PtySession::resize` on the wire so the in-VM child gets
    /// matching SIGWINCH on the guest side.
    pub fn open(rows: u16, cols: u16) -> Result<Self, UnixPtyError> {
        let mut master_fd: c_int = -1;
        let mut slave_fd: c_int = -1;
        let mut winsize = WinSize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // openpty(amaster, aslave, name, termp, winp). NULL termios → kernel
        // default (cooked mode). We immediately switch to raw mode below —
        // passing NULL here avoids an extra zeroed-termios init dance.
        let rc = unsafe {
            openpty(
                &mut master_fd,
                &mut slave_fd,
                std::ptr::null_mut(),
                std::ptr::null(),
                &mut winsize,
            )
        };
        if rc != 0 {
            return Err(UnixPtyError::OpenPty(io::Error::last_os_error()));
        }
        // SAFETY: the kernel just handed us fresh fds; ownership transfers
        // to OwnedFd which will close them on Drop.
        let master_owned = unsafe { OwnedFd::from_raw_fd(master_fd) };
        let slave_owned = unsafe { OwnedFd::from_raw_fd(slave_fd) };

        // Raw mode: disable all line-discipline processing on the host PTY.
        //
        // The host PTY bridges guest↔Terminal.app over vsock via pump_io.
        // With cooked (default) termios the line discipline corrupts the
        // stream in ways that crash TUI apps:
        //
        //   • ECHO: bytes pump_io writes to the master (guest output) are
        //     echoed back, so pump_io reads its own writes and re-sends them
        //     to the guest as keystrokes — a byte-level feedback loop.
        //
        //   • ISIG: byte 0x03 (ETX / Ctrl-C) in any guest output (common in
        //     ANSI escape sequences and container init noise) triggers
        //     SIGINT on the `screen` process → [screen is terminating].
        //
        //   • ONLCR / ICRNL: LF↔CR translation corrupts ncurses / TUI
        //     cursor-movement sequences (Claude, OpenCode, Codex all need
        //     exact CR/LF bytes).
        //
        //   • ICANON: line-buffers until '\n'; keystrokes aren't forwarded
        //     to the guest until Enter, breaking single-keystroke apps.
        //
        // cfmakeraw clears all of the above flags and makes the PTY a
        // transparent byte conduit. The in-VM guest manages its own line
        // discipline; we must not double-process here.
        unsafe {
            // 128 bytes is an over-allocation for struct termios on both
            // macOS aarch64 (≈72 bytes) and Linux aarch64 (≈60 bytes).
            let mut t = [0u8; 128];
            let t_ptr = t.as_mut_ptr() as *mut std::ffi::c_void;
            if tcgetattr(slave_fd, t_ptr) == 0 {
                cfmakeraw(t_ptr);
                let _ = tcsetattr(slave_fd, TCSANOW, t_ptr);
            }
        }

        set_nonblocking(master_owned.as_raw_fd())?;

        let slave_path = ptsname_of(master_owned.as_raw_fd())?;

        let async_fd = AsyncFd::new(FdHolder {
            owned: master_owned,
        })
        .map_err(UnixPtyError::OpenPty)?;
        Ok(Self {
            master: Arc::new(async_fd),
            _slave: slave_owned,
            slave_path,
        })
    }

    /// `/dev/ttys*` path of the slave side. Hand this to a child process
    /// or a Terminal.app wrapper that re-opens it as its controlling tty.
    pub fn slave_path(&self) -> &str {
        &self.slave_path
    }

    /// Resize the PTY window — caller invokes when the local terminal app
    /// reports a SIGWINCH. The in-VM child will see its own SIGWINCH via
    /// a separate `PtyResize` envelope on the wire (see `pty::mod.rs`).
    pub fn resize(&self, rows: u16, cols: u16) -> io::Result<()> {
        let ws = WinSize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let rc = unsafe {
            ioctl(
                self.master.get_ref().as_raw_fd(),
                TIOCSWINSZ,
                &ws as *const WinSize,
            )
        };
        if rc < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    /// A detachable reader of the PTY master's current window size. It clones
    /// the shared master fd, so it stays usable AFTER the `UnixPtyMaster` is
    /// moved into `pump_io`. The tray is a GUI process with no controlling tty
    /// and never receives SIGWINCH, so the resize watcher reads this to learn
    /// the real terminal size that `screen`/Terminal.app apply to the slave
    /// after attach (and on every later window resize).
    pub fn winsize_reader(&self) -> PtyWinsizeReader {
        PtyWinsizeReader {
            fd: self.master.clone(),
        }
    }
}

/// Detachable `TIOCGWINSZ` reader — see [`UnixPtyMaster::winsize_reader`].
pub struct PtyWinsizeReader {
    fd: Arc<AsyncFd<FdHolder>>,
}

impl PtyWinsizeReader {
    /// Current `(rows, cols)` from the PTY master via `TIOCGWINSZ`. Returns an
    /// error once the underlying fd is closed (session ended).
    pub fn get(&self) -> io::Result<(u16, u16)> {
        let mut ws = WinSize {
            ws_row: 0,
            ws_col: 0,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let rc = unsafe {
            ioctl(
                self.fd.get_ref().as_raw_fd(),
                TIOCGWINSZ,
                &mut ws as *mut WinSize,
            )
        };
        if rc < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok((ws.ws_row, ws.ws_col))
        }
    }
}

/// Read half handed out by `split()`. Wraps `Arc<AsyncFd>` so both halves
/// share the same kqueue registration.
pub struct UnixPtyReader(Arc<AsyncFd<FdHolder>>, Option<OwnedFd>);

/// Write half handed out by `split()`.
pub struct UnixPtyWriter(Arc<AsyncFd<FdHolder>>);

impl AsyncRead for UnixPtyReader {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        loop {
            let mut guard = match self.0.poll_read_ready(cx) {
                Poll::Ready(Ok(g)) => g,
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending => return Poll::Pending,
            };
            let unfilled = unsafe { buf.unfilled_mut() };
            let fd = guard.get_ref().as_raw_fd();
            match guard.try_io(|_| unsafe { read_fd(fd, unfilled) }) {
                Ok(Ok(n)) => {
                    unsafe { buf.assume_init(n) };
                    buf.advance(n);
                    return Poll::Ready(Ok(()));
                }
                Ok(Err(e)) => return Poll::Ready(Err(e)),
                Err(_would_block) => continue,
            }
        }
    }
}

impl AsyncWrite for UnixPtyWriter {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        loop {
            let mut guard = match self.0.poll_write_ready(cx) {
                Poll::Ready(Ok(g)) => g,
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending => return Poll::Pending,
            };
            let fd = guard.get_ref().as_raw_fd();
            match guard.try_io(|_| unsafe { write_fd(fd, buf) }) {
                Ok(Ok(n)) => return Poll::Ready(Ok(n)),
                Ok(Err(e)) => return Poll::Ready(Err(e)),
                Err(_would_block) => continue,
            }
        }
    }
    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

impl super::PtyMaster for UnixPtyMaster {
    type Reader = UnixPtyReader;
    type Writer = UnixPtyWriter;

    fn split(self) -> (UnixPtyReader, UnixPtyWriter) {
        let r = UnixPtyReader(self.master.clone(), Some(self._slave));
        let w = UnixPtyWriter(self.master);
        (r, w)
    }
}

// ─── libc bindings (inline; no new Cargo dep) ────────────────────────────

#[repr(C)]
#[derive(Clone, Copy)]
struct WinSize {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
}

// TIOCSWINSZ value differs across OSes; both macOS Darwin and Linux use
// 0x80087467 in practice (encoded via _IOW('t', 103, struct winsize)),
// but to stay portable we define platform-specific values.
#[cfg(target_os = "macos")]
const TIOCSWINSZ: u64 = 0x80087467;
#[cfg(target_os = "linux")]
const TIOCSWINSZ: u64 = 0x5414;

// TIOCGWINSZ (read window size). macOS Darwin _IOR('t', 104, struct winsize);
// Linux fixed value. Counterpart to TIOCSWINSZ above.
#[cfg(target_os = "macos")]
const TIOCGWINSZ: u64 = 0x40087468;
#[cfg(target_os = "linux")]
const TIOCGWINSZ: u64 = 0x5413;

#[link(name = "c")]
unsafe extern "C" {
    fn openpty(
        amaster: *mut c_int,
        aslave: *mut c_int,
        name: *mut c_char,
        termp: *const std::ffi::c_void, // struct termios* (NULL = default)
        winp: *mut WinSize,
    ) -> c_int;

    fn read(fd: c_int, buf: *mut std::ffi::c_void, count: usize) -> isize;
    fn write(fd: c_int, buf: *const std::ffi::c_void, count: usize) -> isize;
    fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;

    // Thread-safe variant of ptsname(3) — required since ptsname returns
    // a static buffer.
    fn ptsname_r(fd: c_int, buf: *mut c_char, buflen: usize) -> c_int;

    // `ioctl` is variadic in C; one binding serves both TIOCSWINSZ (kernel
    // reads the winsize we hand it) and TIOCGWINSZ (kernel writes it back).
    // Two fixed-signature bindings to the same symbol trip
    // `clashing_extern_declarations`, so bind the variadic form once.
    fn ioctl(fd: c_int, request: u64, ...) -> c_int;

    // Terminal attribute manipulation used to put the host PTY into raw mode.
    // All three are POSIX and present on macOS and Linux.
    fn tcgetattr(fd: c_int, termios_p: *mut std::ffi::c_void) -> c_int;
    fn tcsetattr(fd: c_int, optional_actions: c_int, termios_p: *const std::ffi::c_void) -> c_int;
    fn cfmakeraw(termios_p: *mut std::ffi::c_void);
}

// TCSANOW = 0 on both macOS and Linux; apply termios changes immediately.
const TCSANOW: c_int = 0;

const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0o4;

fn set_nonblocking(fd: RawFd) -> Result<(), UnixPtyError> {
    let flags = unsafe { fcntl(fd, F_GETFL) };
    if flags < 0 {
        return Err(UnixPtyError::Fcntl(io::Error::last_os_error()));
    }
    let rc = unsafe { fcntl(fd, F_SETFL, flags | O_NONBLOCK) };
    if rc < 0 {
        Err(UnixPtyError::Fcntl(io::Error::last_os_error()))
    } else {
        Ok(())
    }
}

fn ptsname_of(master_fd: RawFd) -> Result<String, UnixPtyError> {
    let mut buf = [0u8; 128];
    let rc = unsafe { ptsname_r(master_fd, buf.as_mut_ptr() as *mut c_char, buf.len()) };
    if rc != 0 {
        return Err(UnixPtyError::Ptsname(io::Error::last_os_error()));
    }
    // Find the NUL terminator.
    let nul = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    let s = std::str::from_utf8(&buf[..nul]).map_err(UnixPtyError::Utf8)?;
    Ok(s.to_string())
}

unsafe fn read_fd(fd: RawFd, buf: &mut [std::mem::MaybeUninit<u8>]) -> io::Result<usize> {
    let n = unsafe { read(fd, buf.as_mut_ptr() as *mut std::ffi::c_void, buf.len()) };
    if n < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(n as usize)
    }
}

unsafe fn write_fd(fd: RawFd, buf: &[u8]) -> io::Result<usize> {
    let n = unsafe { write(fd, buf.as_ptr() as *const std::ffi::c_void, buf.len()) };
    if n < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(n as usize)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Compile-time check that `UnixPtyMaster` satisfies `PtyMaster`.
    #[test]
    fn unix_pty_master_satisfies_trait() {
        fn assert_impl<M: super::super::PtyMaster>() {}
        assert_impl::<UnixPtyMaster>();
    }

    /// Open a real PTY and confirm we get a `/dev/ttys*` path back. This
    /// exercises openpty + ptsname_r against the real kernel.
    /// AsyncFd::new requires a running tokio runtime, hence #[tokio::test].
    #[tokio::test]
    async fn open_real_pty_yields_slave_path() {
        let pty = UnixPtyMaster::open(24, 80).expect("openpty");
        let path = pty.slave_path();
        assert!(path.starts_with("/dev/"), "unexpected slave path: {path:?}");
    }

    /// Compile-time: `UnixPtyReader: AsyncRead` and `UnixPtyWriter:
    /// AsyncWrite`. Load-bearing for `pump_io`.
    #[test]
    fn unix_pty_halves_are_async_io() {
        fn assert_r<T: tokio::io::AsyncRead>() {}
        fn assert_w<T: tokio::io::AsyncWrite>() {}
        assert_r::<UnixPtyReader>();
        assert_w::<UnixPtyWriter>();
    }
}
