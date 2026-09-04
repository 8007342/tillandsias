//! Relay an accepted guest→host vsock connection to a host-native TCP service.
//!
//! ORDER 830-xsk2. The host listener (`transport_macos::HostVsockListener`)
//! accepts guest-initiated connections and hands each accepted fd to a
//! channel. Until this module existed **nothing read that channel**: the
//! accept succeeded, the fd was duplicated exactly as the delegate documents,
//! and then it was dropped on the floor. From inside the guest that is
//! indistinguishable from a working service that answers nothing — the
//! silent-success shape this milestone exists to remove.
//!
//! WHY THE HOST HALF AND NOT THE GUEST HALF FIRST. The packet's deliverable
//! has two independent pieces: something in the guest that answers
//! `inference:11434` and dials CID 2, and something on the host that turns an
//! accepted vsock fd into bytes exchanged with the host-native engine. The
//! guest piece cannot be *validated* through `--exec-guest` at all — measured
//! 2026-08-29, six guest connects timed out at 2.04–2.06s and were then
//! accepted in a burst once the blocking command returned, because
//! Virtualization.framework only delivers accepts while the host pumps
//! CFRunLoop. The host piece has no such constraint: it is plain POSIX
//! plumbing, so it can be proven here, today, against a real socket pair and a
//! real TCP listener rather than against a booted VM.
//!
//! `cfg(unix)` rather than `cfg(target_os = "macos")` on purpose. Only macOS
//! produces these fds, but the relay itself is family-agnostic POSIX, and
//! compiling plus testing it on the Linux hosts means a regression is caught by
//! the fleet's normal gate instead of only on the one host that owns the lane.
//!
//! @trace spec:vsock-transport, spec:vm-idiomatic-layer

#![cfg(unix)]

use std::io::{self, Read as _, Write as _};
use std::net::{Shutdown, SocketAddr, TcpStream};
use std::os::fd::{FromRawFd as _, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::Receiver;
use std::thread::JoinHandle;

/// Wrap an accepted vsock fd as a stream.
///
/// `UnixStream` is used as a generic POSIX-socket handle, NOT because the fd is
/// an `AF_UNIX` socket — it is `AF_VSOCK`. Everything this relay needs from it
/// (`read`, `write`, `shutdown`, `try_clone`) is a family-agnostic socket call,
/// and std exposes no neutral "owned socket" stream type. The alternative is
/// raw `libc::read`/`write` loops, which would add a dependency and hand-roll
/// the `EINTR` handling std already does correctly.
fn stream_from_fd(fd: OwnedFd) -> UnixStream {
    // SAFETY: `fd` is an owned, open socket descriptor — the duplicate the
    // accept delegate made — and ownership moves into the stream, which closes
    // it exactly once on drop.
    unsafe { UnixStream::from_raw_fd(std::os::fd::IntoRawFd::into_raw_fd(fd)) }
}

/// Copy one direction until EOF, then half-close the far side.
///
/// The half-close is the whole reason this is not `io::copy`. A protocol that
/// signals "request complete" by shutting down its write half — which is what
/// an HTTP client without content-length does — deadlocks if the relay swallows
/// that shutdown: each side sits waiting for the other to speak.
fn pump(mut from: impl Read0, mut to: impl Write0, to_shutdown: &dyn Shutdownable) {
    let mut buf = [0u8; 16 * 1024];
    loop {
        match from.read0(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if to.write0(&buf[..n]).is_err() {
                    break;
                }
            }
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
    // Best effort: the peer may already be gone, which is not an error here.
    let _ = to_shutdown.shutdown_write();
}

// Tiny local traits so `pump` works over both stream types without pulling in a
// generic-over-two-concrete-types dance that reads worse than it computes.
trait Read0 {
    fn read0(&mut self, b: &mut [u8]) -> io::Result<usize>;
}
trait Write0 {
    fn write0(&mut self, b: &[u8]) -> io::Result<()>;
}
trait Shutdownable {
    fn shutdown_write(&self) -> io::Result<()>;
}
impl Read0 for UnixStream {
    fn read0(&mut self, b: &mut [u8]) -> io::Result<usize> {
        self.read(b)
    }
}
impl Read0 for TcpStream {
    fn read0(&mut self, b: &mut [u8]) -> io::Result<usize> {
        self.read(b)
    }
}
impl Write0 for UnixStream {
    fn write0(&mut self, b: &[u8]) -> io::Result<()> {
        self.write_all(b)
    }
}
impl Write0 for TcpStream {
    fn write0(&mut self, b: &[u8]) -> io::Result<()> {
        self.write_all(b)
    }
}
impl Shutdownable for UnixStream {
    fn shutdown_write(&self) -> io::Result<()> {
        self.shutdown(Shutdown::Write)
    }
}
impl Shutdownable for TcpStream {
    fn shutdown_write(&self) -> io::Result<()> {
        self.shutdown(Shutdown::Write)
    }
}

/// Relay one accepted guest connection to `target`, blocking until both
/// directions are done.
///
/// FAILS CLOSED, AND THAT IS THE POINT. If the host-native service is not
/// listening, the connect fails and this returns immediately, dropping the
/// guest fd — the guest's read gets a prompt EOF and its HTTP client reports a
/// closed connection. The alternative, holding an accepted-but-unserved
/// connection open, is exactly the state that made the accept path look healthy
/// while delivering nothing.
pub fn relay_to(guest_fd: OwnedFd, target: SocketAddr) -> io::Result<()> {
    let guest = stream_from_fd(guest_fd);
    let host = TcpStream::connect(target)?;

    let guest_r = guest.try_clone()?;
    let guest_w = guest.try_clone()?;
    let host_r = host.try_clone()?;
    let host_w = host.try_clone()?;

    // One thread per direction. Two threads rather than one polled loop because
    // this is a handful of connections at a time on a developer's laptop, not a
    // server: a readiness loop here would be machinery bought with no buyer.
    let up = std::thread::Builder::new()
        .name("vsock-relay-g2h".into())
        .spawn(move || pump(guest_r, host_w, &host))?;
    pump(host_r, guest_w, &guest);
    let _ = up.join();
    Ok(())
}

/// Drain accepted fds off the listener's channel forever, relaying each to
/// `target`.
///
/// This is what makes the listener a *service* rather than a counter. Returns
/// the thread handle; dropping the sending half of the channel (i.e. dropping
/// the listener) ends the loop, so this does not need its own stop signal.
pub fn spawn_forwarder(rx: Receiver<RawFd>, target: SocketAddr) -> JoinHandle<()> {
    std::thread::Builder::new()
        .name("vsock-forwarder".into())
        .spawn(move || {
            for raw in rx {
                // SAFETY: the accept delegate duplicated this fd and released
                // ownership when it sent it; we are the only owner now.
                let owned = unsafe { OwnedFd::from_raw_fd(raw) };
                if let Err(e) = relay_to(owned, target) {
                    // Loud, per connection, and naming the target: a relay that
                    // fails silently reproduces the exact defect this module
                    // exists to close.
                    eprintln!(
                        "[vz] host vsock: relay to {target} failed: {e}. The guest \
                         connection was accepted and is now closed; the host-native \
                         service is not answering."
                    );
                }
            }
        })
        .expect("spawning the vsock forwarder thread")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::os::fd::AsRawFd as _;

    /// A host-side echo service, returning the address to dial.
    fn echo_server() -> SocketAddr {
        let l = TcpListener::bind("127.0.0.1:0").expect("bind echo server");
        let addr = l.local_addr().expect("echo addr");
        std::thread::spawn(move || {
            for s in l.incoming().flatten() {
                std::thread::spawn(move || {
                    let mut s = s;
                    let mut buf = [0u8; 1024];
                    while let Ok(n) = s.read(&mut buf) {
                        if n == 0 || s.write_all(&buf[..n]).is_err() {
                            break;
                        }
                    }
                });
            }
        });
        addr
    }

    /// The relay carries bytes BOTH ways. A one-way relay passes a naive smoke
    /// test (the request arrives) and then hangs forever waiting for a response
    /// that is being read by nobody.
    #[test]
    fn bytes_cross_in_both_directions() {
        let addr = echo_server();
        let (guest, mut peer) = UnixStream::pair().expect("socketpair");
        let fd = OwnedFd::from(guest);

        let t = std::thread::spawn(move || relay_to(fd, addr));

        peer.write_all(b"ping").expect("guest writes");
        let mut buf = [0u8; 4];
        peer.read_exact(&mut buf)
            .expect("guest reads the echo back");
        assert_eq!(&buf, b"ping", "the relay must carry the response back");

        drop(peer);
        t.join().expect("relay thread").expect("relay result");
    }

    /// Half-close must PROPAGATE. Without it, a client that signals end-of-
    /// request by shutting down its write half waits forever for a service that
    /// is itself waiting for more request bytes.
    #[test]
    fn a_guest_half_close_reaches_the_host_service() {
        let l = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = l.local_addr().expect("addr");
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let (mut s, _) = l.accept().expect("accept");
            let mut all = Vec::new();
            // read_to_end returns ONLY when the write half is shut down.
            s.read_to_end(&mut all).expect("read to end");
            let _ = tx.send(all);
        });

        let (guest, mut peer) = UnixStream::pair().expect("socketpair");
        let fd = OwnedFd::from(guest);
        std::thread::spawn(move || relay_to(fd, addr));

        peer.write_all(b"request").expect("write");
        peer.shutdown(Shutdown::Write).expect("half close");

        let got = rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .expect("the host service must see EOF, not hang");
        assert_eq!(got, b"request");
    }

    /// An unserved target must close the guest connection promptly rather than
    /// hold it open. Holding it is what makes a dead backend look alive.
    #[test]
    fn an_unreachable_target_closes_the_guest_connection() {
        // Bind then drop, so the port is almost certainly unbound.
        let dead = {
            let l = TcpListener::bind("127.0.0.1:0").expect("bind");
            l.local_addr().expect("addr")
        };
        let (guest, mut peer) = UnixStream::pair().expect("socketpair");
        let fd = OwnedFd::from(guest);
        assert!(
            relay_to(fd, dead).is_err(),
            "connecting to an unserved target must report an error"
        );
        let mut buf = [0u8; 8];
        let n = peer.read(&mut buf).expect("guest read after relay gave up");
        assert_eq!(n, 0, "the guest must see EOF, not an open idle connection");
    }

    /// The forwarder loop ends when the listener (and thus the sender) is
    /// dropped. Anything else leaks a thread per VM start.
    #[test]
    fn the_forwarder_stops_when_the_listener_is_dropped() {
        let addr = echo_server();
        let (tx, rx) = std::sync::mpsc::channel::<RawFd>();
        let h = spawn_forwarder(rx, addr);
        drop(tx);
        // If this hangs the loop has no exit condition.
        h.join()
            .expect("the forwarder thread must end with its sender");
    }

    /// A relayed fd is closed exactly once. `stream_from_fd` takes ownership,
    /// so a second owner would be a double close — the bug class the accept
    /// delegate's duplication comment already warns about one level up.
    #[test]
    fn the_relay_takes_ownership_of_the_fd() {
        let src = include_str!("host_vsock_forward.rs");
        let f = src
            .split("fn stream_from_fd")
            .nth(1)
            .and_then(|t| t.split("\n}").next())
            .expect("stream_from_fd moved — repoint this scan");
        assert!(
            f.contains("into_raw_fd"),
            "ownership must MOVE into the stream; borrowing would double-close"
        );
        let (a, _b) = UnixStream::pair().expect("socketpair");
        let raw = a.as_raw_fd();
        let s = stream_from_fd(OwnedFd::from(a));
        assert_eq!(
            s.as_raw_fd(),
            raw,
            "the same descriptor must be carried over"
        );
    }
}
