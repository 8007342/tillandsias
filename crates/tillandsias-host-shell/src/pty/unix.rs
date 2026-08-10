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
//! fd is held only from `open()` to `split()` — long enough for the caller
//! to hand the slave path to the attach client — and dropped at `split()`
//! so the client's exit EOFs the master and the session can tear down
//! (order 492; the old whole-session retention made master reads
//! EAGAIN-pend forever after the terminal window closed).
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

/// Host-side Unix PTY master + bootstrap slave. The slave fd is held from
/// `open()` until `split()` so the pair survives while the caller (e.g. the
/// macOS tray's `terminal_attach`) hands the slave's `/dev/ttys*` path to
/// Terminal.app via a small wrapper that re-opens it; `split()` drops it so
/// the wrapper's exit EOFs the master (order 492).
pub struct UnixPtyMaster {
    /// Shared so `split()` can hand both halves concurrent access. AsyncFd
    /// itself only needs `&self` for poll_read_ready / poll_write_ready.
    master: Arc<AsyncFd<FdHolder>>,
    /// Bootstrap slave fd — dropped at `split()`, see above.
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
        let _ = fd_set_raw(slave_fd);

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
}

// NOTE (terminal-attach@v2, 2026-07-27): the former master-side winsize
// machinery (`UnixPtyMaster::resize`, `winsize_reader`, `PtyWinsizeReader`)
// was deleted with the tray's poll loops — geometry now moves ONLY on the
// attach client's SIGWINCH events (it stamps `TIOCSWINSZ` on the slave and
// notifies the tray on the session socket; see `pty::attach_client` and
// `fd_winsize`/`fd_set_winsize` below). Do not reintroduce a master-side
// winsize watcher: there is no kernel event to subscribe to on a PTY
// master, so any watcher degenerates into a forbidden poll.

/// Read half handed out by `split()`. Wraps `Arc<AsyncFd>` so both halves
/// share the same kqueue registration.
pub struct UnixPtyReader(Arc<AsyncFd<FdHolder>>);

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
        // The retained slave CLOSES here (order 492, audit D5). From this
        // point the attach client is the only slave holder, so its exit
        // EOFs the master and pump_io's input task can tear the session
        // down instead of EAGAIN-pending forever. Darwin resets the pair's
        // termios to cooked if this drop ever creates a zero-slave window
        // (measured — see raw_termios_survives_zero_slave_window), which is
        // why the attach client re-raws the slave it opens.
        drop(self._slave);
        let r = UnixPtyReader(self.master.clone());
        let w = UnixPtyWriter(self.master);
        (r, w)
    }
}

// ─── shared fd-level termios/winsize helpers ──────────────────────────────
//
// Used by `UnixPtyMaster` above and by `pty::attach_client` (the in-terminal
// client that owns the operator-facing tty). All operate on a raw fd so the
// caller decides ownership; none of them poll — they are one-shot ioctls.

/// Read `(rows, cols)` from any tty fd via `TIOCGWINSZ`.
pub(crate) fn fd_winsize(fd: RawFd) -> io::Result<(u16, u16)> {
    let mut ws = WinSize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe { ioctl(fd, TIOCGWINSZ, &mut ws as *mut WinSize) };
    if rc < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok((ws.ws_row, ws.ws_col))
    }
}

/// Stamp `rows`x`cols` onto any tty fd via `TIOCSWINSZ`. The kernel raises
/// `SIGWINCH` in the fd's foreground process group (if any).
pub(crate) fn fd_set_winsize(fd: RawFd, rows: u16, cols: u16) -> io::Result<()> {
    let ws = WinSize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe { ioctl(fd, TIOCSWINSZ, &ws as *const WinSize) };
    if rc < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// Opaque saved-termios image. 128 bytes over-allocates `struct termios` on
/// both macOS aarch64 (≈72 bytes) and Linux aarch64 (≈60 bytes) — same trick
/// as the raw-mode block in `UnixPtyMaster::open`.
pub(crate) type SavedTermios = [u8; 128];

/// Snapshot the fd's termios for a later [`fd_restore_termios`].
pub(crate) fn fd_save_termios(fd: RawFd) -> io::Result<SavedTermios> {
    let mut t: SavedTermios = [0u8; 128];
    let rc = unsafe { tcgetattr(fd, t.as_mut_ptr() as *mut std::ffi::c_void) };
    if rc != 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(t)
    }
}

/// Put the fd into raw mode (`cfmakeraw`): transparent byte conduit — no
/// echo, no ISIG, no CR/LF translation, byte-granular reads.
pub(crate) fn fd_set_raw(fd: RawFd) -> io::Result<()> {
    let mut t: SavedTermios = [0u8; 128];
    let t_ptr = t.as_mut_ptr() as *mut std::ffi::c_void;
    unsafe {
        if tcgetattr(fd, t_ptr) != 0 {
            return Err(io::Error::last_os_error());
        }
        cfmakeraw(t_ptr);
        if tcsetattr(fd, TCSANOW, t_ptr) != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Restore a termios image previously captured with [`fd_save_termios`].
pub(crate) fn fd_restore_termios(fd: RawFd, saved: &SavedTermios) -> io::Result<()> {
    let rc = unsafe { tcsetattr(fd, TCSANOW, saved.as_ptr() as *const std::ffi::c_void) };
    if rc != 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
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

    /// Order 492 (the packet's step-5 test): with `split()` no longer
    /// retaining a slave, the master must EOF/error once the sole external
    /// slave holder exits — NOT pend forever, which is exactly the wedge
    /// the retention caused (window close left master reads EAGAIN-pending
    /// and the guest harness leaked). Mirrors the production ordering: the
    /// external slave (the attach client) opens BEFORE `split()` drops the
    /// bootstrap fd, so the pair never sees a zero-slave window mid-test.
    #[tokio::test]
    async fn master_read_errors_once_sole_external_slave_closes() {
        use std::io::Write as _;
        use tokio::io::AsyncReadExt;

        const O_NOCTTY_DARWIN: i32 = 0x2_0000;
        #[cfg(not(target_os = "macos"))]
        const O_NOCTTY_OTHER: i32 = 0o400;
        #[cfg(target_os = "macos")]
        let noctty = O_NOCTTY_DARWIN;
        #[cfg(not(target_os = "macos"))]
        let noctty = O_NOCTTY_OTHER;

        let pty = UnixPtyMaster::open(24, 80).expect("openpty");
        let path = pty.slave_path().to_string();

        // External slave opens first (as the attach client does), THEN the
        // bootstrap slave drops inside split().
        let mut external = {
            use std::os::unix::fs::OpenOptionsExt;
            std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(noctty)
                .open(&path)
                .expect("open external slave")
        };
        let (mut reader, _writer) = super::super::PtyMaster::split(pty);

        // Liveness: a byte written at the slave arrives at the master.
        external.write_all(b"x").expect("slave write");
        let mut buf = [0u8; 8];
        let n = tokio::time::timeout(std::time::Duration::from_secs(2), reader.read(&mut buf))
            .await
            .expect("live read must not time out")
            .expect("live read");
        assert_eq!(&buf[..n], b"x", "byte must flow slave -> master");

        // Sole slave holder exits: the master read must terminate.
        drop(external);
        let end = tokio::time::timeout(std::time::Duration::from_secs(2), reader.read(&mut buf))
            .await
            .expect("post-close master read must terminate, not pend forever (order 492)");
        match end {
            Ok(0) => {}  // Darwin: clean EOF (measured)
            Err(_) => {} // EIO also acceptable — still terminates the pump
            Ok(n) => panic!("unexpected extra bytes after slave close: {:?}", &buf[..n]),
        }
    }

    /// Order 492 live Darwin probe (audit D5), now the permanent behavior
    /// pin. Measured on this hardware 2026-08-09:
    ///
    ///   1. Darwin RESETS pty termios to cooked when the last slave closes
    ///      (`after == cooked`). The 8c6c8d05 slave retention really was
    ///      load-bearing for raw-mode persistence, exactly as the
    ///      terminal-management audit's verifier suspected — which is why
    ///      the attach client re-raws the slave it opens (branch 3 of the
    ///      packet) now that `split()` drops the tray's retained fd.
    ///
    ///   2. With zero slaves a nonblocking Darwin master read returns
    ///      `n == 0` (EOF), not EIO and crucially not EAGAIN — so
    ///      `pump_io`'s clean-EOF break is the live teardown path once the
    ///      terminal client exits.
    ///
    /// Shape: raw openpty FFI (no tokio reactor needed), three tcgetattr
    /// snapshots through the crate's own helpers — cooked reference,
    /// post-cfmakeraw raw, and post-zero-slave-window reopen (opened with the
    /// exact attach-client flags, O_RDWR|O_NOCTTY). `SavedTermios` is a
    /// zero-initialized [u8; 128], so whole-array equality is sound.
    #[cfg(target_os = "macos")]
    #[test]
    fn raw_termios_survives_zero_slave_window() {
        const O_NOCTTY_DARWIN: i32 = 0x2_0000;

        let mut master_fd: c_int = -1;
        let mut slave_fd: c_int = -1;
        let mut winsize = WinSize {
            ws_row: 24,
            ws_col: 80,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let rc = unsafe {
            openpty(
                &mut master_fd,
                &mut slave_fd,
                std::ptr::null_mut(),
                std::ptr::null(),
                &mut winsize,
            )
        };
        assert_eq!(rc, 0, "openpty failed: {}", io::Error::last_os_error());
        let master = unsafe { OwnedFd::from_raw_fd(master_fd) };
        let slave = unsafe { OwnedFd::from_raw_fd(slave_fd) };

        let cooked = fd_save_termios(slave.as_raw_fd()).expect("tcgetattr cooked");
        fd_set_raw(slave.as_raw_fd()).expect("cfmakeraw");
        let raw = fd_save_termios(slave.as_raw_fd()).expect("tcgetattr raw");
        assert_ne!(raw, cooked, "cfmakeraw must change the termios image");

        let path = ptsname_of(master.as_raw_fd()).expect("ptsname");

        // Zero-slave window opens here; master stays alive.
        drop(slave);

        // Document the zero-slave master read errno (EIO expected on Darwin;
        // EAGAIN is the with-retained-slave symptom). Master must be
        // nonblocking first or a blocking read could hang the test.
        set_nonblocking(master.as_raw_fd()).expect("O_NONBLOCK");
        let mut buf = [0u8; 8];
        let n = unsafe {
            read(
                master.as_raw_fd(),
                buf.as_mut_ptr() as *mut std::ffi::c_void,
                buf.len(),
            )
        };
        let zero_slave_errno = if n < 0 {
            io::Error::last_os_error().raw_os_error()
        } else {
            None
        };
        eprintln!("[probe] zero-slave master read: n={n} errno={zero_slave_errno:?}");
        // EAGAIN here would mean the kernel still counts an open slave —
        // the with-retained-slave symptom this packet removed. EOF (0) is
        // what this kernel does; EIO would also terminate the pump loop.
        assert!(
            !(n < 0 && zero_slave_errno == Some(35 /* EAGAIN */)),
            "zero-slave master read must terminate (EOF/EIO), not EAGAIN-pend"
        );

        // Reopen exactly like the attach client (O_RDWR | O_NOCTTY).
        let reopened = {
            use std::os::unix::fs::OpenOptionsExt;
            std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(O_NOCTTY_DARWIN)
                .open(&path)
                .expect("reopen slave")
        };
        let after = fd_save_termios(reopened.as_raw_fd()).expect("tcgetattr reopened");

        eprintln!(
            "[probe] after==raw: {}  after==cooked: {}",
            after == raw,
            after == cooked
        );
        assert_eq!(
            after, cooked,
            "measured Darwin behavior: pty termios RESETS to cooked across a \
             zero-slave window. If this pin ever flips, the attach client's \
             re-raw becomes redundant (but harmless); if it flips the OTHER \
             way while the client's re-raw is ever removed, the cooked-mode \
             echo loop from 8c6c8d05 comes back"
        );
    }
}
