//! macOS host-side vsock connector for the running `VZVirtualMachine`.
//!
//! Apple's `Virtualization.framework` does NOT expose vsock via the kernel's
//! `AF_VSOCK` socket family (the way Linux + `tokio-vsock` do). Instead, the
//! host *connects* into the guest by calling
//! `VZVirtioSocketDevice::connectToPort:completionHandler:`, which delivers a
//! `VZVirtioSocketConnection` whose `.fileDescriptor()` is the host-side end
//! of the established vsock pipe.
//!
//! This module is the macOS-side equivalent of `tokio_vsock::VsockStream` —
//! it takes a running VM handle, a port, and returns the raw fd. Wrapping
//! that fd into a tokio-friendly `AsyncRead + AsyncWrite` is the next step
//! (m1b sub-task B); this file ships only the connect-and-extract-fd
//! primitive so the macOS host can drive the same `tillandsias-control-wire`
//! framing the Linux + Windows hosts use.
//!
//! Macos-only — the module isn't defined on Linux/Windows.
//!
//! Architectural note (per `plan/issues/branch-and-coordination-canon-
//! 2026-05-25.md`): the shared `tillandsias-control-wire::transport::
//! connect(Transport::Vsock{cid, port})` path does NOT change — that lives
//! on the Linux + Windows native-vsock paths. macOS uses this private
//! connector because VFR's API requires an in-process `VZVirtualMachine`
//! handle, which the shared `Transport` enum has no way to carry.
//!
//! @trace spec:vm-idiomatic-layer, spec:vsock-transport, spec:macos-native-tray

#![cfg(target_os = "macos")]

use std::io;
use std::os::raw::c_int;
use std::os::unix::io::{AsRawFd, RawFd};
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use objc2::rc::Retained;
use objc2_foundation::NSError;
use objc2_virtualization::{
    VZVirtioSocketConnection, VZVirtioSocketDevice, VZVirtualMachine,
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf, unix::AsyncFd};

use crate::vz::boot::pump_cf_loop_for;

/// Raw vsock fd + the keep-alive `VZVirtioSocketConnection` that owns it.
/// Drop the wrapper to release both. The `Retained` field is what keeps the
/// VZ object (and thus the underlying socket) alive — the bare fd alone is
/// not enough.
pub struct VsockFd {
    /// Host-side end of the connected vsock pipe. Use with `tokio::io::unix::
    /// AsyncFd::new(fd)` (next iter) for AsyncRead + AsyncWrite.
    pub fd: c_int,
    /// Holds the ObjC retain count on the underlying connection so the fd
    /// stays valid for the lifetime of `VsockFd`.
    _connection: Retained<VZVirtioSocketConnection>,
}

// SAFETY: `VZVirtioSocketConnection` is documented as usable from any
// thread once established (the dispatch-queue restriction applies to the
// VM-management ObjC API, not to the established socket fd). Reading +
// writing to the fd is OS-level and thread-safe per POSIX. We treat
// `VsockFd` as `Send + Sync` so the host-shell can park it in an `Arc`
// behind an `AsyncFd` shared across tokio tasks.
unsafe impl Send for VsockFd {}
unsafe impl Sync for VsockFd {}

/// Tokio-friendly wrapper around `VsockFd` that implements
/// `AsyncRead + AsyncWrite` so the host-shell can drive the postcard
/// framing layer (`tillandsias-control-wire`) directly on top of an
/// established VZ vsock connection.
///
/// The fd's lifecycle is governed by the held `VZVirtioSocketConnection`
/// `Retained` (`_connection`) — dropping the stream releases the ObjC
/// retain, which closes the underlying socket via VZ's destructor.
/// `AsyncFd` registers the fd with the tokio reactor (kqueue on macOS)
/// for readiness notifications; the closure invoked from `try_io`
/// performs the actual `read(2)`/`write(2)` syscall.
///
/// @trace spec:vsock-transport, spec:vm-idiomatic-layer
pub struct VsockStream {
    fd: AsyncFd<FdHolder>,
    _connection: Retained<VZVirtioSocketConnection>,
}

/// Borrowed `RawFd` wrapper. Owned semantically by the held
/// `VZVirtioSocketConnection`; this struct exists only so `AsyncFd` has
/// an `AsRawFd` value to register with the reactor.
///
/// `AsyncFd<T>` does NOT close the fd on drop — it just deregisters; the
/// VZ connection's destructor is what actually closes the socket. So
/// double-close is not a concern.
struct FdHolder(RawFd);

impl AsRawFd for FdHolder {
    fn as_raw_fd(&self) -> RawFd {
        self.0
    }
}

impl VsockStream {
    /// Convert a `VsockFd` (from `connect_to_vm_vsock`) into a
    /// `VsockStream`. Sets the fd to non-blocking so tokio's reactor can
    /// dispatch readiness events instead of blocking the runtime thread.
    ///
    /// @trace spec:vsock-transport
    pub fn from_vsock_fd(v: VsockFd) -> io::Result<Self> {
        // Toggle O_NONBLOCK on the fd. POSIX read/write under non-blocking
        // mode return EAGAIN/EWOULDBLOCK when no data is ready / no buffer
        // space available; AsyncFd::try_io maps that to "not ready" and
        // re-registers for the next readiness edge.
        set_nonblocking(v.fd)?;
        let fd = AsyncFd::new(FdHolder(v.fd))?;
        Ok(Self {
            fd,
            _connection: v._connection,
        })
    }
}

// SAFETY: same justification as VsockFd (established vsock fd is POSIX
// thread-safe; VZ doesn't gate established sockets to a dispatch queue).
// AsyncFd<FdHolder> is itself Send+Sync iff FdHolder is, and FdHolder
// holds only a primitive c_int.
unsafe impl Send for VsockStream {}
unsafe impl Sync for VsockStream {}

impl AsyncRead for VsockStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        loop {
            let mut guard = match this.fd.poll_read_ready(cx) {
                Poll::Ready(Ok(g)) => g,
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending => return Poll::Pending,
            };
            let unfilled = unsafe { buf.unfilled_mut() };
            let fd = guard.get_ref().as_raw_fd();
            let res = guard.try_io(|_| unsafe { read_fd(fd, unfilled) });
            match res {
                Ok(Ok(n)) => {
                    unsafe { buf.assume_init(n) };
                    buf.advance(n);
                    return Poll::Ready(Ok(()));
                }
                Ok(Err(e)) => return Poll::Ready(Err(e)),
                // try_io returned WouldBlock; loop back to re-arm.
                Err(_would_block) => continue,
            }
        }
    }
}

impl AsyncWrite for VsockStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        loop {
            let mut guard = match this.fd.poll_write_ready(cx) {
                Poll::Ready(Ok(g)) => g,
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending => return Poll::Pending,
            };
            let fd = guard.get_ref().as_raw_fd();
            let res = guard.try_io(|_| unsafe { write_fd(fd, buf) });
            match res {
                Ok(Ok(n)) => return Poll::Ready(Ok(n)),
                Ok(Err(e)) => return Poll::Ready(Err(e)),
                Err(_would_block) => continue,
            }
        }
    }

    fn poll_flush(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
    ) -> Poll<io::Result<()>> {
        // No userspace buffering — every poll_write hits the kernel.
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
    ) -> Poll<io::Result<()>> {
        // VZ closes the underlying socket when the connection's retain
        // count hits zero (= VsockStream::drop). Tell the kernel to
        // half-close the write side immediately so the peer gets EOF.
        let fd = self.fd.get_ref().as_raw_fd();
        let rc = unsafe { libc_shutdown(fd, 1 /* SHUT_WR */) };
        if rc < 0 {
            Poll::Ready(Err(io::Error::last_os_error()))
        } else {
            Poll::Ready(Ok(()))
        }
    }
}

// ─── inline libc bindings (avoid pulling the `libc` crate as a direct
// dep just for three syscalls; objc2 already pulls it transitively but
// we don't want to declare it in our Cargo.toml unnecessarily) ────────

#[link(name = "c")]
unsafe extern "C" {
    fn read(fd: c_int, buf: *mut std::ffi::c_void, count: usize) -> isize;
    fn write(fd: c_int, buf: *const std::ffi::c_void, count: usize) -> isize;
    #[link_name = "shutdown"]
    fn libc_shutdown(fd: c_int, how: c_int) -> c_int;
    fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
}

const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0o4;

fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { fcntl(fd, F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    let rc = unsafe { fcntl(fd, F_SETFL, flags | O_NONBLOCK) };
    if rc < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// SAFETY: caller guarantees `buf` is valid for writes of `buf.len()` bytes.
unsafe fn read_fd(fd: RawFd, buf: &mut [std::mem::MaybeUninit<u8>]) -> io::Result<usize> {
    let n = unsafe {
        read(
            fd,
            buf.as_mut_ptr() as *mut std::ffi::c_void,
            buf.len(),
        )
    };
    if n < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(n as usize)
    }
}

/// SAFETY: caller guarantees `buf` is valid for reads of `buf.len()` bytes.
unsafe fn write_fd(fd: RawFd, buf: &[u8]) -> io::Result<usize> {
    let n = unsafe {
        write(
            fd,
            buf.as_ptr() as *const std::ffi::c_void,
            buf.len(),
        )
    };
    if n < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(n as usize)
    }
}

/// Errors from the connect path.
#[derive(Debug)]
pub enum ConnectError {
    /// The running VM has no socketDevices (configuration didn't add a
    /// `VZVirtioSocketDeviceConfiguration`).
    NoSocketDevice,
    /// The first socket device on the VM is not a `VZVirtioSocketDevice`
    /// (some unexpected subclass — should never happen with VFR's only
    /// vsock impl, but guards against future framework additions).
    UnexpectedSocketDeviceKind,
    /// The completion handler never fired within `timeout`.
    Timeout(Duration),
    /// VZ reported a connect error via `NSError`. String is
    /// `NSError.localizedDescription`.
    VzError(String),
    /// VZ delivered a null connection without an error — should never
    /// happen but bindings type it as nullable.
    NullConnection,
}

impl std::fmt::Display for ConnectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoSocketDevice => f.write_str("VM has no socket devices"),
            Self::UnexpectedSocketDeviceKind => {
                f.write_str("first VM socket device is not a VZVirtioSocketDevice")
            }
            Self::Timeout(d) => write!(f, "connect timed out after {} ms", d.as_millis()),
            Self::VzError(s) => write!(f, "VZ connect error: {s}"),
            Self::NullConnection => f.write_str("VZ delivered null connection without error"),
        }
    }
}

impl std::error::Error for ConnectError {}

/// Connect into the running VM's vsock listener on `port` and return the
/// host-side fd + retain-keeping wrapper. Blocks the calling thread for up
/// to `timeout` while pumping `CFRunLoop` so VZ's completion handler can
/// dispatch on the main queue.
///
/// **Threading**: must be called from a thread that owns the CFRunLoop the
/// VM was started on (typically the same thread that called `VzRuntime::
/// start`). Calling from a tokio worker is acceptable IF that worker pumps
/// the runloop; in practice the tray wraps this in `tokio::task::
/// spawn_blocking` and the spawned thread runs `pump_cf_loop_for` slices.
///
/// @trace spec:vsock-transport, spec:vm-idiomatic-layer
pub fn connect_to_vm_vsock(
    vm: &VZVirtualMachine,
    port: u32,
    timeout: Duration,
) -> Result<VsockFd, ConnectError> {
    use block2::RcBlock;

    // Walk the VM's runtime socket-devices list. VFR exposes exactly one
    // VZVirtioSocketDevice per VZVirtioSocketDeviceConfiguration added to
    // the VZVirtualMachineConfiguration; we use the first.
    let devices = unsafe { vm.socketDevices() };
    if devices.count() == 0 {
        return Err(ConnectError::NoSocketDevice);
    }
    // SAFETY: index 0 is within bounds (count > 0 checked above).
    let first = unsafe { devices.objectAtIndex(0) };
    // Downcast: VZVirtioSocketDevice IS a VZSocketDevice subclass and is
    // the only kind VFR instantiates from our config, so the cast is sound.
    // Verify via -isKindOfClass: before the unsafe cast to fail-closed on
    // any future framework addition.
    use objc2::ClassType;
    let is_virtio: bool = unsafe {
        let cls = <VZVirtioSocketDevice as ClassType>::class();
        let obj: &objc2::runtime::AnyObject = first.as_ref().as_ref();
        objc2::msg_send![obj, isKindOfClass: cls]
    };
    if !is_virtio {
        return Err(ConnectError::UnexpectedSocketDeviceKind);
    }
    // SAFETY: verified above via isKindOfClass.
    let vsock_dev: Retained<VZVirtioSocketDevice> = unsafe { Retained::cast(first) };

    // Bridge VZ's dispatch-queue completion handler to this thread via a
    // mpsc channel; pump CFRunLoop until the result arrives or `timeout`
    // elapses.
    let (tx, rx) = std::sync::mpsc::channel::<Result<Retained<VZVirtioSocketConnection>, ConnectError>>();
    let handler = RcBlock::new(move |conn_ptr: *mut VZVirtioSocketConnection, err_ptr: *mut NSError| {
        let result = if !err_ptr.is_null() {
            let desc = unsafe { (*err_ptr).localizedDescription() }.to_string();
            Err(ConnectError::VzError(desc))
        } else if conn_ptr.is_null() {
            Err(ConnectError::NullConnection)
        } else {
            // SAFETY: VZ delivers an owned reference per documented
            // semantics; we wrap it in `Retained` so the retain count
            // is balanced when `Retained` drops.
            let conn = unsafe { Retained::retain(conn_ptr) };
            match conn {
                Some(c) => Ok(c),
                None => Err(ConnectError::NullConnection),
            }
        };
        let _ = tx.send(result);
    });
    unsafe { vsock_dev.connectToPort_completionHandler(port, &handler) };

    let deadline = Instant::now() + timeout;
    loop {
        if let Ok(result) = rx.try_recv() {
            let conn = result?;
            let fd = unsafe { conn.fileDescriptor() };
            return Ok(VsockFd {
                fd,
                _connection: conn,
            });
        }
        if Instant::now() >= deadline {
            return Err(ConnectError::Timeout(timeout));
        }
        pump_cf_loop_for(Duration::from_millis(50));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Compile-time check that `ConnectError` implements the standard
    /// error/display traits the host-shell expects from transport errors.
    #[test]
    fn connect_error_implements_error() {
        fn assert_error<T: std::error::Error>() {}
        assert_error::<ConnectError>();

        let err = ConnectError::Timeout(Duration::from_secs(3));
        let s = format!("{err}");
        assert!(s.contains("3000 ms"));
    }

    /// `VsockFd` should drop the underlying `Retained` and release the fd
    /// when it goes out of scope. Hard to assert directly without a real
    /// VM, but at minimum verify the struct is `Send` so a tokio task can
    /// own it (when the AsyncFd wrap arrives in sub-task B, `Send`-ness
    /// becomes load-bearing).
    #[test]
    fn vsock_fd_is_send() {
        fn assert_send<T: Send>() {}
        assert_send::<VsockFd>();
    }

    /// `VsockStream` must be `Send + Sync` so the host-shell can park it
    /// in an `Arc<Mutex<VsockStream>>` shared across tokio tasks. Compile-
    /// time check.
    ///
    /// @trace spec:vsock-transport
    #[test]
    fn vsock_stream_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<VsockStream>();
    }

    /// `VsockStream` must implement both `AsyncRead` and `AsyncWrite` so
    /// the postcard framing layer can frame envelopes directly on top of
    /// it without a UnixStream-style adapter.
    ///
    /// @trace spec:vsock-transport
    #[test]
    fn vsock_stream_is_async_read_write() {
        fn assert_read_write<T: tokio::io::AsyncRead + tokio::io::AsyncWrite>() {}
        assert_read_write::<VsockStream>();
    }
}
