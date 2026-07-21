//! Transport descriptors and connect/bind helpers for the control wire.
//!
//! The framing format (`4-byte BE length || postcard envelope`) is
//! identical across transports. This module names the two transports we
//! support — Unix socket (Linux tray ↔ Linux headless on the same host)
//! and vsock (host tray ↔ in-VM headless on Windows + macOS) — and exposes
//! `connect` / `bind` helpers that return an `AsyncReadWrite` (an alias for
//! `tokio::io::AsyncRead + AsyncWrite`) so callers can frame envelopes
//! without caring which transport is underneath.
//!
//! Phase-2 status: Unix is implemented on every platform. Vsock is
//! implemented on Linux behind the `vsock` cargo feature; on non-Linux
//! targets (and on Linux without the feature), `connect`/`bind` on the
//! `Vsock` variant returns `io::ErrorKind::Unsupported` so the crate still
//! compiles cleanly.
//!
//! @trace spec:vsock-transport, spec:host-shell-architecture

use std::io;
use std::path::PathBuf;

use tokio::io::{AsyncRead, AsyncWrite};
#[cfg(unix)]
use tokio::net::{UnixListener, UnixStream};

/// Stable vsock port used by the control wire for the primary channel.
///
/// Single source of truth for both the in-VM headless's bind and the
/// host-side tray's connect. Future ports (log forwarding, MCP framing)
/// MUST be allocated as additional named constants in this module.
///
/// @trace spec:vsock-transport
pub const CONTROL_WIRE_VSOCK_PORT: u32 = 42420;

/// Where to reach the control wire.
#[derive(Debug, Clone)]
pub enum Transport {
    /// Filesystem socket (Linux). Default
    /// `$XDG_RUNTIME_DIR/tillandsias/control.sock`.
    Unix(PathBuf),
    /// virtio-vsock (Windows + macOS host trays). `cid` identifies the
    /// guest VM; `port` is conventionally `CONTROL_WIRE_VSOCK_PORT`.
    Vsock { cid: u32, port: u32 },
}

/// Trait combining `tokio::io::AsyncRead` + `AsyncWrite`. Boxed instances
/// of this trait are what `connect` / `Listener::accept` hand back to the
/// caller, who then frames postcard envelopes on top.
pub trait AsyncReadWrite: AsyncRead + AsyncWrite {}
impl<T: AsyncRead + AsyncWrite + ?Sized> AsyncReadWrite for T {}

/// A bound listener that yields connections framed for the control wire.
pub enum Listener {
    /// Unix-socket listener (Unix-family only).
    #[cfg(unix)]
    Unix(UnixListener),
    /// Vsock listener (Linux only, behind the `vsock` feature).
    #[cfg(all(target_os = "linux", feature = "vsock"))]
    Vsock(tokio_vsock::VsockListener),
    /// Cross-platform placeholder so the enum is non-empty on every target.
    /// Never instantiated.
    #[doc(hidden)]
    _Unreachable(std::marker::PhantomData<()>),
}

impl Listener {
    /// Accept the next inbound connection and return it as a boxed
    /// `AsyncReadWrite`. The framing layer is shared with the Unix path.
    ///
    /// @trace spec:vsock-transport
    pub async fn accept(&mut self) -> io::Result<Box<dyn AsyncReadWrite + Unpin + Send>> {
        match self {
            #[cfg(unix)]
            Listener::Unix(listener) => {
                let (stream, _addr) = listener.accept().await?;
                Ok(Box::new(stream))
            }
            #[cfg(all(target_os = "linux", feature = "vsock"))]
            Listener::Vsock(listener) => {
                let (stream, _addr) = listener.accept().await?;
                Ok(Box::new(stream))
            }
            Listener::_Unreachable(_) => unreachable!(
                "_Unreachable listener variant is never constructed; @trace spec:vsock-transport"
            ),
        }
    }
}

/// Open a client connection to the control wire.
///
/// On Linux this works for both Unix and vsock (when the `vsock` feature is
/// enabled). On non-Linux targets the `Vsock` variant returns
/// `io::ErrorKind::Unsupported`.
///
/// @trace spec:vsock-transport
pub async fn connect(transport: &Transport) -> io::Result<Box<dyn AsyncReadWrite + Unpin + Send>> {
    match transport {
        #[cfg(unix)]
        Transport::Unix(path) => {
            let stream = UnixStream::connect(path).await?;
            Ok(Box::new(stream))
        }
        #[cfg(not(unix))]
        Transport::Unix(_) => Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "Unix-socket transport is only available on Unix-family targets",
        )),
        Transport::Vsock { cid, port } => connect_vsock(*cid, *port).await,
    }
}

/// Bind a server-side listener for the control wire.
///
/// On Linux this works for both Unix and vsock (when the `vsock` feature is
/// enabled). On non-Linux targets the `Vsock` variant returns
/// `io::ErrorKind::Unsupported`.
///
/// @trace spec:vsock-transport
pub async fn bind(transport: &Transport) -> io::Result<Listener> {
    match transport {
        #[cfg(unix)]
        Transport::Unix(path) => {
            let listener = UnixListener::bind(path)?;
            Ok(Listener::Unix(listener))
        }
        #[cfg(not(unix))]
        Transport::Unix(_) => Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "Unix-socket transport is only available on Unix-family targets",
        )),
        Transport::Vsock { cid, port } => bind_vsock(*cid, *port).await,
    }
}

#[cfg(all(target_os = "linux", feature = "vsock"))]
async fn connect_vsock(cid: u32, port: u32) -> io::Result<Box<dyn AsyncReadWrite + Unpin + Send>> {
    use tokio_vsock::{VsockAddr, VsockStream};
    let addr = VsockAddr::new(cid, port);
    let stream = VsockStream::connect(addr).await?;
    Ok(Box::new(stream))
}

#[cfg(not(all(target_os = "linux", feature = "vsock")))]
async fn connect_vsock(
    _cid: u32,
    _port: u32,
) -> io::Result<Box<dyn AsyncReadWrite + Unpin + Send>> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "vsock transport is only available on Linux with the `vsock` feature enabled",
    ))
}

#[cfg(all(target_os = "linux", feature = "vsock"))]
async fn bind_vsock(cid: u32, port: u32) -> io::Result<Listener> {
    use tokio_vsock::{VsockAddr, VsockListener};
    let addr = VsockAddr::new(cid, port);
    let listener = VsockListener::bind(addr)?;
    Ok(Listener::Vsock(listener))
}

#[cfg(not(all(target_os = "linux", feature = "vsock")))]
async fn bind_vsock(_cid: u32, _port: u32) -> io::Result<Listener> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "vsock transport is only available on Linux with the `vsock` feature enabled",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    // The framing helpers below only feed the unix roundtrip test; on
    // Windows they (and their imports) would be dead code — a lint class
    // Linux clippy never compiles (mirror of the windows-cfg case, 2abfcb30).
    #[cfg(unix)]
    use crate::{ControlEnvelope, ControlMessage, MAX_MESSAGE_BYTES, WIRE_VERSION, decode, encode};
    #[cfg(unix)]
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[cfg(unix)]
    async fn write_envelope<W>(stream: &mut W, env: &ControlEnvelope) -> io::Result<()>
    where
        W: AsyncWrite + Unpin,
    {
        let bytes = encode(env).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        stream
            .write_all(&(bytes.len() as u32).to_be_bytes())
            .await?;
        stream.write_all(&bytes).await?;
        stream.flush().await
    }

    #[cfg(unix)]
    async fn read_envelope<R>(stream: &mut R) -> io::Result<ControlEnvelope>
    where
        R: AsyncRead + Unpin,
    {
        let mut len_buf = [0u8; 4];
        stream.read_exact(&mut len_buf).await?;
        let len = u32::from_be_bytes(len_buf) as usize;
        if len > MAX_MESSAGE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "control frame too large",
            ));
        }
        let mut body = vec![0u8; len];
        stream.read_exact(&mut body).await?;
        decode(&body).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }

    /// Bind a Unix listener via the transport module, connect to it, exchange
    /// `Hello` / `HelloAck`, and assert the frames round-trip via the shared
    /// encode/decode pair.
    ///
    /// @trace spec:vsock-transport
    #[cfg(unix)]
    #[tokio::test]
    async fn unix_roundtrip_via_transport_module() {
        let dir = tempfile::tempdir().expect("tempdir");
        let sock_path = dir.path().join("control.sock");

        let server_transport = Transport::Unix(sock_path.clone());
        let mut listener = bind(&server_transport)
            .await
            .expect("bind unix listener via transport");

        let client_transport = Transport::Unix(sock_path);
        let client_task = tokio::spawn(async move {
            let mut stream = connect(&client_transport).await.expect("client connect");
            let hello = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 7,
                body: ControlMessage::Hello {
                    from: "transport-test".to_string(),
                    capabilities: vec!["IssueWebSession".to_string()],
                    build_version: None,
                },
            };
            write_envelope(&mut stream, &hello)
                .await
                .expect("client write hello");
            let ack = read_envelope(&mut stream).await.expect("client read ack");
            assert_eq!(ack.seq, 7);
            match ack.body {
                ControlMessage::HelloAck {
                    wire_version,
                    build_version: _,
                    ..
                } => {
                    assert_eq!(wire_version, WIRE_VERSION);
                }
                other => panic!("expected HelloAck, got {other:?}"),
            }
        });

        let mut server_stream = listener.accept().await.expect("server accept");
        let hello = read_envelope(&mut server_stream)
            .await
            .expect("server read hello");
        assert_eq!(hello.seq, 7);
        match hello.body {
            ControlMessage::Hello { ref from, .. } => assert_eq!(from, "transport-test"),
            ref other => panic!("expected Hello, got {other:?}"),
        }
        let ack = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: hello.seq,
            body: ControlMessage::HelloAck {
                wire_version: WIRE_VERSION,
                server_caps: vec!["IssueWebSession".to_string()],
                build_version: None,
            },
        };
        write_envelope(&mut server_stream, &ack)
            .await
            .expect("server write ack");

        client_task.await.expect("client task joined");
    }

    /// On non-Linux targets (or on Linux without the `vsock` feature),
    /// `connect`/`bind` on a `Vsock` transport must surface
    /// `ErrorKind::Unsupported` rather than compile-error or silently work.
    ///
    /// @trace spec:vsock-transport
    #[cfg(not(all(target_os = "linux", feature = "vsock")))]
    #[tokio::test]
    async fn vsock_listener_unsupported_on_non_linux() {
        let transport = Transport::Vsock {
            cid: 1,
            port: CONTROL_WIRE_VSOCK_PORT,
        };
        let bind_err = match bind(&transport).await {
            Ok(_) => panic!("bind on vsock without feature must fail"),
            Err(err) => err,
        };
        assert_eq!(bind_err.kind(), io::ErrorKind::Unsupported);

        let connect_err = match connect(&transport).await {
            Ok(_) => panic!("connect on vsock without feature must fail"),
            Err(err) => err,
        };
        assert_eq!(connect_err.kind(), io::ErrorKind::Unsupported);
    }
}
