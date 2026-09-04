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
use objc2_virtualization::{VZVirtioSocketConnection, VZVirtioSocketDevice, VZVirtualMachine};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf, unix::AsyncFd};

use crate::vz::boot::{dispatch_to_main_queue, pump_cf_loop_for};

struct VmForConnect(Retained<VZVirtualMachine>);

// SAFETY: mirrors `vz::vm_handle::VmHandle`; VZ VM-management calls are
// dispatched onto the main queue before touching the retained object.
unsafe impl Send for VmForConnect {}

struct SocketConnection(Retained<VZVirtioSocketConnection>);

// SAFETY: `VZVirtioSocketConnection` owns an established POSIX fd. We only
// move the retained connection back to the waiting worker after the
// main-queue `connectToPort` completion fires, then keep it alive in `VsockFd`.
unsafe impl Send for SocketConnection {}
unsafe impl Sync for SocketConnection {}

impl VmForConnect {
    fn connect_and_report(
        self,
        port: u32,
        tx: std::sync::mpsc::Sender<Result<SocketConnection, ConnectError>>,
    ) {
        // Walk the VM's runtime socket-devices list. VFR exposes exactly one
        // VZVirtioSocketDevice per VZVirtioSocketDeviceConfiguration added to
        // the VZVirtualMachineConfiguration; we use the first.
        let devices = unsafe { self.0.socketDevices() };
        if devices.count() == 0 {
            let _ = tx.send(Err(ConnectError::NoSocketDevice));
            return;
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
            let _ = tx.send(Err(ConnectError::UnexpectedSocketDeviceKind));
            return;
        }
        // SAFETY: verified above via isKindOfClass.
        let vsock_dev: Retained<VZVirtioSocketDevice> = unsafe { Retained::cast(first) };

        let handler = block2::RcBlock::new(
            move |conn_ptr: *mut VZVirtioSocketConnection, err_ptr: *mut NSError| {
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
                        Some(c) => Ok(SocketConnection(c)),
                        None => Err(ConnectError::NullConnection),
                    }
                };
                let _ = tx.send(result);
            },
        );
        unsafe { vsock_dev.connectToPort_completionHandler(port, &handler) };
    }
}

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

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        // No userspace buffering — every poll_write hits the kernel.
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        // VZ closes the underlying socket when the connection's retain
        // count hits zero (= VsockStream::drop). Tell the kernel to
        // half-close the write side immediately so the peer gets EOF.
        let fd = self.fd.get_ref().as_raw_fd();
        let rc = unsafe {
            libc_shutdown(fd, 1 /* SHUT_WR */)
        };
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
    let n = unsafe { read(fd, buf.as_mut_ptr() as *mut std::ffi::c_void, buf.len()) };
    if n < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(n as usize)
    }
}

/// SAFETY: caller guarantees `buf` is valid for reads of `buf.len()` bytes.
unsafe fn write_fd(fd: RawFd, buf: &[u8]) -> io::Result<usize> {
    let n = unsafe { write(fd, buf.as_ptr() as *const std::ffi::c_void, buf.len()) };
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
    vm: &Retained<VZVirtualMachine>,
    port: u32,
    timeout: Duration,
) -> Result<VsockFd, ConnectError> {
    // Bridge VZ's dispatch-queue completion handler to this thread via a
    // mpsc channel; pump CFRunLoop until the result arrives or `timeout`
    // elapses.
    //
    // 690-xeda recorded justification (the no-polling doctrine permits a
    // justified transient timer): this 50 ms pump-and-check runs ONLY for
    // the duration of one vsock connect attempt, bounded by `timeout`, and
    // contributes zero steady-state wakeups (measured 2026-08-16 with this
    // code present and idle). A plain `recv_timeout` block looks
    // equivalent, but the pump keeps this thread's runloop servicing
    // whatever VZ schedules on it during bring-up; proving the blocking
    // form safe requires connect-under-load testing on real hardware —
    // worth doing only if a measurement ever shows connects hot. If that
    // proof lands, remove this justification with it.
    let (tx, rx) = std::sync::mpsc::channel::<Result<SocketConnection, ConnectError>>();
    let vm_for_connect = VmForConnect(vm.clone());
    dispatch_to_main_queue(move || vm_for_connect.connect_and_report(port, tx));

    let deadline = Instant::now() + timeout;
    loop {
        if let Ok(result) = rx.try_recv() {
            let SocketConnection(conn) = result?;
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

// ── Host-side vsock LISTENER (order 830-xsk2) ────────────────────────────────
//
// The other direction, and until now the missing one. Everything above lets the
// HOST reach into the guest; nothing let the guest reach out. That asymmetry is
// what blocks an Apple-silicon inference lane: Metal is host-native only
// (accel_probe.rs PROBE-7), the workload runs in a Linux guest that has no
// Metal, and there was no transport between the accelerator and the work.
//
// MEASURED BEFORE THIS WAS WRITTEN, from inside the guest:
//   connect to CID 2 (host) -> ETIMEDOUT after 2.0s, on every port tried.
// Not ENETUNREACH, which would have meant no route and a different design
// entirely; not ECONNREFUSED. The guest's stack ROUTES to the host and
// transmits, and nothing answers — so the path exists and only a listener was
// absent. The 2.0s is Linux's VSOCK_DEFAULT_CONNECT_TIMEOUT, measured against a
// deliberate 45s budget so the bound could not have come from the probe itself,
// which means a guest-side caller gets a fast errno rather than a stall when the
// host is not listening.
//
// WHY A DELEGATE AT ALL. `setSocketListener:forPort:` takes a
// VZVirtioSocketListener, and a listener without a delegate accepts nothing:
// `listener:shouldAcceptNewConnection:fromSocketDevice:` IS the accept
// decision. This is the first Objective-C protocol conformance in this crate
// (vz.rs:1855 records VZVirtualMachineDelegate as deliberately unobserved), so
// the `declare_class!` block below is the pattern any future delegate copies.
use objc2::runtime::{NSObjectProtocol, ProtocolObject};
use objc2::{ClassType, DeclaredClass, declare_class, msg_send_id, mutability};
use objc2_foundation::NSObject;
use objc2_virtualization::{VZVirtioSocketListener, VZVirtioSocketListenerDelegate};

/// What the delegate needs to hand an accepted connection back to Rust.
pub struct AcceptIvars {
    /// Every accepted connection's fd, in arrival order. A channel rather than a
    /// callback because the delegate method is invoked on VZ's queue and must
    /// return a verdict promptly — doing real work there would block the
    /// framework's socket handling.
    tx: std::sync::mpsc::Sender<RawFd>,
}

declare_class!(
    /// Accepts guest-initiated vsock connections on one port and forwards each
    /// accepted fd to a channel.
    ///
    /// DUPLICATING THE FD IS NOT OPTIONAL. `VZVirtioSocketConnection` closes its
    /// file descriptor when the object deallocates, and this delegate method is
    /// the only place that object is alive — VZ hands it in, we return, it goes
    /// away. Passing the raw fd onward would hand the reader a descriptor that
    /// the framework closes underneath it, which is the shape of bug that
    /// presents as an unexplained EBADF long after the accept.
    struct VsockAcceptDelegate;

    unsafe impl ClassType for VsockAcceptDelegate {
        type Super = NSObject;
        type Mutability = mutability::InteriorMutable;
        const NAME: &'static str = "TillandsiasVsockAcceptDelegate";
    }

    impl DeclaredClass for VsockAcceptDelegate {
        type Ivars = AcceptIvars;
    }

    unsafe impl NSObjectProtocol for VsockAcceptDelegate {}

    unsafe impl VZVirtioSocketListenerDelegate for VsockAcceptDelegate {
        #[method(listener:shouldAcceptNewConnection:fromSocketDevice:)]
        unsafe fn listener_should_accept(
            &self,
            _listener: &VZVirtioSocketListener,
            connection: &VZVirtioSocketConnection,
            _device: &VZVirtioSocketDevice,
        ) -> objc2::runtime::Bool {
            use std::os::fd::{AsRawFd as _, BorrowedFd, IntoRawFd as _};
            let raw = unsafe { connection.fileDescriptor() };
            // SAFETY: `raw` is the fd VZ owns for the lifetime of this callback;
            // we only borrow it long enough to duplicate it. `try_clone_to_owned`
            // is std's dup(2) and keeps the CLOEXEC handling std guarantees, so
            // this needs no libc dependency.
            let borrowed = unsafe { BorrowedFd::borrow_raw(raw) };
            let Ok(owned) = borrowed.try_clone_to_owned() else {
                // Refusing is the honest answer: accepting and then failing to
                // keep the fd would look like a working connection to the guest
                // and deliver nothing.
                return objc2::runtime::Bool::NO;
            };
            let fd = owned.as_raw_fd();
            // The accept is otherwise invisible: it happens on VZ's queue, with
            // no return path a caller can watch. This line IS the runtime proof
            // that the guest reached the host, and it is the only evidence a
            // probe can quote — so it names the port and the fd rather than
            // saying "accepted".
            eprintln!(
                "[vz] host vsock: ACCEPTED a guest-initiated connection (fd {fd}) \
                 — the guest reached the host"
            );
            match self.ivars().tx.send(fd) {
                Ok(()) => {
                    // Ownership has moved to the receiver; do not let `owned`
                    // close it on drop.
                    let _ = owned.into_raw_fd();
                    objc2::runtime::Bool::YES
                }
                Err(_) => {
                    // The receiver is gone — nobody will ever read this
                    // connection, so do not pretend to accept it. Dropping
                    // `owned` closes the duplicate.
                    objc2::runtime::Bool::NO
                }
            }
        }
    }
);

impl VsockAcceptDelegate {
    fn new(tx: std::sync::mpsc::Sender<RawFd>) -> Retained<Self> {
        let this = Self::alloc().set_ivars(AcceptIvars { tx });
        unsafe { msg_send_id![super(this), init] }
    }
}

/// A live host-side vsock listener. Dropping it removes the listener from the
/// port, so a caller cannot leave the VM accepting connections nobody reads.
///
/// ACCEPTANCE IS GATED ON THE HOST PUMPING ITS RUNLOOP — measured, and the
/// single most important thing to know before building on this.
/// Virtualization.framework RETAINS guest connection requests and delivers them
/// to the delegate only when the host services CFRunLoop. It does not drop
/// them, and it does not deliver them eagerly.
///
/// Measured 2026-08-29 (order 830-xsk2) under `--exec-guest`, which blocks on
/// the control wire and pumps nothing while a guest command runs: six guest
/// connects failed with ETIMEDOUT at 2.04-2.06s each — the kernel's
/// VSOCK_DEFAULT_CONNECT_TIMEOUT, not a caller's patience — and then ALL SIX
/// were accepted in a burst (fd 12 through 17) the moment the command returned
/// and pumping resumed. The accepts were never lost; they arrived after the
/// guest had already given up.
///
/// So a host path that blocks without pumping cannot serve this listener, no
/// matter how correct the listener is. Tray mode drives NSApplication, whose
/// main runloop runs continuously, and should not have the problem — that is
/// REASONED, not measured, and needs its own proof before anything depends on
/// it.
pub struct HostVsockListener {
    device: Retained<VZVirtioSocketDevice>,
    port: u32,
    /// Taken by `forward_to`, which moves it onto the relay thread. `Option`
    /// rather than a clone because a second reader would silently steal half
    /// the accepted connections — two drains on one channel is a coin flip
    /// per connection, which is worse than a refusal.
    rx: Option<std::sync::mpsc::Receiver<RawFd>>,
    /// Held so the delegate outlives the listener registration. VZ does NOT
    /// retain a listener's delegate strongly enough to rely on; dropping it
    /// while the port is still registered would leave the framework calling
    /// into freed memory.
    _delegate: Retained<VsockAcceptDelegate>,
    _listener: Retained<VZVirtioSocketListener>,
}

impl HostVsockListener {
    /// Accept guest-initiated connections on `port` of the running VM.
    ///
    /// MUST be called on the thread that owns the VM, like every other VZ API
    /// in this file — the framework is not thread-safe and the existing
    /// connector already carries that constraint.
    pub fn bind(vm: &VZVirtualMachine, port: u32) -> io::Result<Self> {
        let devices = unsafe { vm.socketDevices() };
        if devices.count() == 0 {
            return Err(io::Error::other(
                "no VZVirtioSocketDevice on this VM — the configuration added none",
            ));
        }
        let first = unsafe { devices.objectAtIndex(0) };
        // Same fail-closed downcast the connector performs: verify before
        // casting so a future framework socket-device kind is refused rather
        // than reinterpreted.
        let is_virtio: bool = unsafe {
            let cls = <VZVirtioSocketDevice as ClassType>::class();
            let obj: &objc2::runtime::AnyObject = first.as_ref().as_ref();
            objc2::msg_send![obj, isKindOfClass: cls]
        };
        if !is_virtio {
            return Err(io::Error::other(
                "first socket device is not a VZVirtioSocketDevice",
            ));
        }
        // SAFETY: verified above via isKindOfClass.
        let device: Retained<VZVirtioSocketDevice> = unsafe { Retained::cast(first) };

        let (tx, rx) = std::sync::mpsc::channel();
        let delegate = VsockAcceptDelegate::new(tx);
        let listener = unsafe { VZVirtioSocketListener::new() };
        let proto: &ProtocolObject<dyn VZVirtioSocketListenerDelegate> =
            ProtocolObject::from_ref(&*delegate);
        unsafe { listener.setDelegate(Some(proto)) };
        unsafe { device.setSocketListener_forPort(&listener, port) };

        Ok(Self {
            device,
            port,
            rx: Some(rx),
            _delegate: delegate,
            _listener: listener,
        })
    }

    /// Next accepted connection's fd, or `None` if none has arrived yet.
    ///
    /// Non-blocking on purpose: the accept happens on VZ's own queue, so this
    /// is a drain of what has already been accepted rather than a wait.
    pub fn try_accept(&self) -> Option<RawFd> {
        self.rx.as_ref()?.try_recv().ok()
    }

    /// Block for the next accepted connection, bounded.
    ///
    /// The bound is the caller's, not the transport's: a guest that never
    /// connects produces no event at all, so there is nothing for the framework
    /// to time out. Contrast the guest side, where an absent host listener
    /// fails in 2.0s on its own (Linux VSOCK_DEFAULT_CONNECT_TIMEOUT, measured).
    pub fn accept_timeout(&self, budget: Duration) -> io::Result<RawFd> {
        let Some(rx) = self.rx.as_ref() else {
            return Err(io::Error::other(
                "this listener is forwarding; accepted connections go to the relay, \
                 not to a caller",
            ));
        };
        rx.recv_timeout(budget).map_err(|_| {
            io::Error::new(
                io::ErrorKind::TimedOut,
                format!(
                    "no guest connected to host vsock port {} within {budget:?}",
                    self.port
                ),
            )
        })
    }

    /// Hand every accepted connection to a relay that forwards it to a
    /// host-native TCP service (order 830-xsk2).
    ///
    /// THIS IS WHAT MAKES THE LISTENER USEFUL. Without it the delegate
    /// accepts, duplicates the fd, sends it to a channel nobody reads, and
    /// the connection dies unserved — which from inside the guest is
    /// indistinguishable from a service that answers nothing.
    ///
    /// Refuses on a second call rather than starting a second drain: two
    /// readers on one channel split the accepted connections arbitrarily
    /// between them, so half the guest requests would be served by a relay
    /// pointed somewhere else.
    pub fn forward_to(&mut self, target: std::net::SocketAddr) -> io::Result<()> {
        let rx = self
            .rx
            .take()
            .ok_or_else(|| io::Error::other("this listener is already forwarding"))?;
        let _ = crate::host_vsock_forward::spawn_forwarder(rx, target);
        Ok(())
    }

    /// The port this listener is registered on.
    pub fn port(&self) -> u32 {
        self.port
    }
}

impl Drop for HostVsockListener {
    fn drop(&mut self) {
        // Deregister explicitly. Without this the framework keeps accepting on
        // a port whose delegate is about to be freed — the reader is gone, so
        // every later connection would be accepted into nothing.
        unsafe { self.device.removeSocketListenerForPort(self.port) };
    }
}

#[cfg(test)]
mod host_listener_tests {
    //! ORDER 830-xsk2. These pin the SHAPE, not the runtime behaviour — a live
    //! accept needs a booted VM and is the packet's runtime criterion, recorded
    //! separately. What is checked here is the set of invariants that were
    //! reasoned about while writing the unsafe code, so a later edit that breaks
    //! one fails here instead of in a guest weeks later.

    /// The duplicate is the point. `VZVirtioSocketConnection` closes its fd when
    /// it deallocates, and that object lives only for the callback — handing the
    /// raw fd onward yields an EBADF long after the accept, with nothing near
    /// the failure to explain it.
    #[test]
    fn accepted_fd_is_duplicated_not_borrowed() {
        let src = include_str!("transport_macos.rs");
        let arm = src
            .split("fn listener_should_accept")
            .nth(1)
            .and_then(|t| t.split("\n        }").next())
            .expect("the delegate method moved — repoint this scan");
        assert!(
            arm.contains("try_clone_to_owned"),
            "the accepted fd MUST be duplicated; VZ closes the original when the \
             connection object deallocates at the end of this callback"
        );
        assert!(
            !arm.contains("tx.send(raw)"),
            "the RAW fd must never be sent onward — that is the borrowed-fd bug"
        );
    }

    /// A refusal must be a refusal. Accepting and then dropping the fd would
    /// look like a working connection to the guest and deliver nothing — the
    /// silent-success shape this milestone exists to remove.
    #[test]
    fn a_failed_handoff_refuses_rather_than_accepting_into_nothing() {
        let src = include_str!("transport_macos.rs");
        let arm = src
            .split("fn listener_should_accept")
            .nth(1)
            .and_then(|t| t.split("\n        }").next())
            .expect("the delegate method moved — repoint this scan");
        let err_branch = arm.split("Err(_)").nth(1).expect("receiver-gone branch");
        assert!(
            err_branch.contains("Bool::NO"),
            "when the receiver is gone the connection must be REFUSED, not \
             accepted into a channel nobody reads"
        );
    }

    /// Dropping the listener must deregister the port. Otherwise the framework
    /// keeps accepting onto a freed delegate.
    #[test]
    fn dropping_the_listener_removes_it_from_the_port() {
        let src = include_str!("transport_macos.rs");
        let drop_impl = src
            .split("impl Drop for HostVsockListener")
            .nth(1)
            .expect("the Drop impl moved — repoint this scan");
        assert!(
            drop_impl.contains("removeSocketListenerForPort"),
            "Drop must deregister, or VZ accepts into a delegate about to be freed"
        );
    }

    /// The delegate is held by the listener struct. VZ's delegate reference is
    /// not something to rely on for lifetime.
    #[test]
    fn the_listener_owns_its_delegate() {
        let src = include_str!("transport_macos.rs");
        let decl = src
            .split("pub struct HostVsockListener")
            .nth(1)
            .and_then(|t| t.split("\n}").next())
            .expect("the struct moved — repoint this scan");
        assert!(
            decl.contains("_delegate: Retained<VsockAcceptDelegate>"),
            "the delegate must be owned here; a freed delegate with a live \
             registration is a use-after-free in framework code"
        );
    }
}
