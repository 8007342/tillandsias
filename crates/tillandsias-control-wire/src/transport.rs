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

/// The ONE construction site for the control wire's length-delimited framing.
///
/// Every framing site in the tree encodes exactly `u32-BE body length ‖ raw
/// postcard body` — no magic, no version byte, no type tag, no checksum, no
/// trailer. The length counts the body ONLY and excludes its own 4 bytes;
/// `wire_version` travels INSIDE the postcard envelope (see [`crate::encode`]),
/// not in the frame header. This constructor reproduces those bytes exactly,
/// so a `Framed` peer and a hand-rolled peer interoperate — which is not a
/// claim, it already ships: `tillandsias-router-sidecar` has talked to the
/// hand-rolled reader in `tillandsias-headless`'s tray over a live Unix socket
/// since it was written, and `codec_framing_is_byte_identical_to_hand_rolled`
/// below pins it.
///
/// **All four parameters are pinned deliberately, and `max_frame_length` is
/// the one that must never be defaulted.** `LengthDelimitedCodec::new()`
/// defaults to 8 MiB — 128x looser than [`MAX_MESSAGE_BYTES`] — and the bound
/// exists precisely to cap the `vec![0u8; len]` a hand-rolled reader performs
/// on an attacker-chosen `u32`. Constructing the codec anywhere else is how
/// that bound gets silently widened, so construct it here or not at all.
///
/// Unlike the hand-rolled sites, this bound is symmetric: the codec enforces
/// `max_frame_length` on ENCODE as well as decode, so an oversize outbound
/// frame fails locally instead of being put on the wire for the peer to
/// reject.
///
/// @trace order:795-5itp, spec:vsock-transport, spec:host-shell-architecture
pub fn control_frame_codec() -> tokio_util::codec::LengthDelimitedCodec {
    tokio_util::codec::LengthDelimitedCodec::builder()
        .length_field_length(4)
        .big_endian()
        .length_adjustment(0)
        .max_frame_length(crate::MAX_MESSAGE_BYTES)
        .new_codec()
}

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
    // These five are used by the codec tests too, which run on EVERY target
    // (they frame over `tokio::io::duplex`, not a Unix socket), so they are no
    // longer unix-gated.
    use crate::{ControlEnvelope, ControlMessage, MAX_MESSAGE_BYTES, WIRE_VERSION, encode};
    // The hand-rolled framing helpers below only feed the unix roundtrip test;
    // on Windows they (and these imports) would be dead code — a lint class
    // Linux clippy never compiles (mirror of the windows-cfg case, 2abfcb30).
    #[cfg(unix)]
    use crate::decode;
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
                ControlMessage::HelloAck { wire_version, .. } => {
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

    // ---- control_frame_codec (order 795-5itp) --------------------------
    //
    // These are deliberately NOT `#[cfg(unix)]`: they run on `tokio::io::duplex`
    // rather than a Unix socket, so they guard the framing on every target
    // including Windows — where `hvsocket.rs` speaks this same format and has
    // no other test that compiles off a live WSL host.

    /// The codec's bytes are the hand-rolled bytes, exactly.
    ///
    /// This is the proof that underwrites migrating any site: if these two
    /// vectors are equal, a `Framed` peer and a hand-rolled peer cannot
    /// desynchronise, and sites may be converted one at a time.
    #[tokio::test]
    async fn codec_framing_is_byte_identical_to_hand_rolled() {
        use futures_util::SinkExt;
        use tokio_util::codec::FramedWrite;

        let env = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 7,
            body: ControlMessage::Hello {
                from: "codec-golden-test".to_string(),
                capabilities: vec!["v1".to_string()],
                build_version: None,
            },
        };
        let body = encode(&env).expect("encode");

        // Hand-rolled, the shape every framing site in the tree writes today.
        let mut hand_rolled = Vec::new();
        hand_rolled.extend_from_slice(&(body.len() as u32).to_be_bytes());
        hand_rolled.extend_from_slice(&body);

        // Through the shared codec.
        let mut via_codec = Vec::new();
        let mut sink = FramedWrite::new(&mut via_codec, control_frame_codec());
        sink.send(tokio_util::bytes::Bytes::from(body.clone()))
            .await
            .expect("codec send");
        drop(sink);

        assert_eq!(
            hand_rolled, via_codec,
            "codec framing diverged from the hand-rolled wire format"
        );
        // Pin the format itself, not just the agreement: 4-byte BE prefix
        // counting the body only, body immediately after.
        assert_eq!(&via_codec[..4], &(body.len() as u32).to_be_bytes());
        assert_eq!(&via_codec[4..], &body[..]);
    }

    /// The bound is exactly `MAX_MESSAGE_BYTES`, inclusive, on BOTH directions.
    ///
    /// Before 795-5itp NOTHING in the tree asserted either half of this, across
    /// eleven read sites that all cap at this value — so a codec constructed
    /// without `max_frame_length` (tokio-util defaults to 8 MiB) would have
    /// widened every one of them 128x and shipped green.
    #[tokio::test]
    async fn codec_bound_is_max_message_bytes_inclusive_both_directions() {
        use futures_util::SinkExt;
        use futures_util::StreamExt;
        use tokio_util::codec::{FramedRead, FramedWrite};

        // --- ENCODE: at the limit is accepted, one over is refused ---
        let at_limit = vec![0xABu8; MAX_MESSAGE_BYTES];
        let mut buf = Vec::new();
        let mut sink = FramedWrite::new(&mut buf, control_frame_codec());
        sink.send(tokio_util::bytes::Bytes::from(at_limit.clone()))
            .await
            .expect("a frame exactly at MAX_MESSAGE_BYTES must be accepted");
        drop(sink);
        assert_eq!(buf.len(), 4 + MAX_MESSAGE_BYTES);

        let over = vec![0xABu8; MAX_MESSAGE_BYTES + 1];
        let mut buf2 = Vec::new();
        let mut sink2 = FramedWrite::new(&mut buf2, control_frame_codec());
        let err = sink2
            .send(tokio_util::bytes::Bytes::from(over))
            .await
            .expect_err("a frame one byte over MAX_MESSAGE_BYTES must be refused on encode");
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert!(
            buf2.is_empty(),
            "an oversize frame must not put ANY bytes on the wire, got {}",
            buf2.len()
        );

        // --- DECODE: at the limit is accepted ---
        let mut framed = FramedRead::new(&buf[..], control_frame_codec());
        let got = framed
            .next()
            .await
            .expect("a frame at the limit must decode")
            .expect("decode at limit");
        assert_eq!(got.len(), MAX_MESSAGE_BYTES);

        // --- DECODE: a declared length one over is refused, and the body is
        // never allocated. Hand-build the prefix, since the encoder above
        // (correctly) refuses to produce this.
        let mut hostile = Vec::new();
        hostile.extend_from_slice(&((MAX_MESSAGE_BYTES + 1) as u32).to_be_bytes());
        hostile.extend_from_slice(&[0u8; 16]); // a short, truncated body
        let mut framed = FramedRead::new(&hostile[..], control_frame_codec());
        let err = framed
            .next()
            .await
            .expect("an oversize length prefix must yield an item")
            .expect_err("a declared length over MAX_MESSAGE_BYTES must be refused on decode");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    /// A `u32::MAX` length prefix — the allocation the bound exists to stop.
    ///
    /// The hand-rolled readers do `vec![0u8; len]` immediately after decoding
    /// the prefix; without a bound that is a 4 GiB allocation on a peer's say-so.
    ///
    /// SENSITIVITY, stated so nobody over-trusts this one: it guards against
    /// NO bound, not against a WRONG one. Measured — with `max_frame_length`
    /// deleted entirely (tokio-util's 8 MiB default) this test still passes,
    /// because 4 GiB exceeds 8 MiB too. The test that pins the exact value is
    /// `codec_bound_is_max_message_bytes_inclusive_both_directions`, which goes
    /// red both when the bound is removed and when it is off by one byte.
    #[tokio::test]
    async fn codec_refuses_u32_max_length_prefix_without_allocating() {
        use futures_util::StreamExt;
        use tokio_util::codec::FramedRead;

        let mut hostile = Vec::new();
        hostile.extend_from_slice(&u32::MAX.to_be_bytes());
        hostile.extend_from_slice(b"only a few bytes actually follow");

        let mut framed = FramedRead::new(&hostile[..], control_frame_codec());
        let err = framed
            .next()
            .await
            .expect("a u32::MAX prefix must yield an item")
            .expect_err("a u32::MAX length prefix must be refused");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }
}
