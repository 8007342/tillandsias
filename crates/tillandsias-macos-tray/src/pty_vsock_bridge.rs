//! `pty_vsock_bridge` — bidirectional framing + routing adapter that
//! turns any AsyncRead + AsyncWrite stream (the macOS
//! `transport_macos::VsockStream` in production; a `tokio::io::duplex`
//! pair in tests) into a usable `PtyTransport` for the host-shell
//! PTY layer.
//!
//! Foundation work for m4 sub-task B "slice 4b" (real PTY-over-vsock).
//! Doesn't yet wire into `openShell:` / `githubLogin:` — that step
//! lands once a booted VM (m5) is available to target.
//!
//! ## Frame format
//!
//! Each frame on the wire is `[len: u32 BE][payload]`, where `payload`
//! is a postcard-encoded `ControlEnvelope`. Matches the framing the
//! shared `Client` in `tillandsias-host-shell::vsock_client` already
//! uses, so the host + in-VM headless interop without changes.
//!
//! ## Spawn layout
//!
//! `spawn_pty_bridge(stream, router, capacity)` returns:
//!   - A `ChannelPtyTransport` the caller hands to `PtySession::open`.
//!   - A `BridgeJoin` holding the writer-task + reader-task handles
//!     so the caller can `.await` shutdown or `.abort()` on teardown.
//!
//! Writer task: drains the `mpsc::Receiver<ControlMessage>` paired
//! with the transport, wraps each into a `ControlEnvelope` with a
//! monotonic per-connection `seq`, postcard-encodes, prefixes with
//! the BE length, writes + flushes. A write error closes the writer.
//!
//! Reader task: reads length prefix, reads body, postcard-decodes,
//! routes `envelope.body` via `PtyRouter::route`. EOF or decode error
//! closes the reader.
//!
//! macOS-only consumer today; the module compiles everywhere (no
//! platform-gated code in the body), gated only because the macos-tray
//! crate's binary is macOS-only.
//!
//! @trace plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 4b — foundation)

#![cfg(target_os = "macos")]

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::task::JoinHandle;

use tillandsias_control_wire::{
    ControlEnvelope, ControlMessage, MAX_MESSAGE_BYTES, WIRE_VERSION, decode, encode,
};
use tillandsias_host_shell::pty::{ChannelPtyTransport, PtyRouter};

/// Handle to the spawned reader + writer tasks. Drop to abort both
/// (writer drains first), or `.join().await` for an orderly close.
pub struct BridgeJoin {
    writer: JoinHandle<()>,
    reader: JoinHandle<()>,
}

impl BridgeJoin {
    /// Wait for both tasks to finish (e.g. via EOF / closed mpsc).
    pub async fn join(self) {
        let _ = self.writer.await;
        let _ = self.reader.await;
    }

    /// Force-abort both tasks. Used on tray shutdown / VM stop.
    pub fn abort(&self) {
        self.writer.abort();
        self.reader.abort();
    }
}

/// Spawn the framed reader + writer tasks that bridge `stream` to
/// the PTY layer. Returns the transport the caller plumbs into
/// `PtySession::open` plus the task handles.
///
/// `capacity` is the outbound mpsc bound — small enough that
/// backpressure on a stuck VM surfaces as a clean `send` error
/// (which `PtySession` then propagates) rather than unbounded host
/// memory growth. The Linux shared `Client` uses an effectively
/// unbounded write loop; we choose bounded here to keep host RSS
/// predictable when the VM stalls.
pub fn spawn_pty_bridge<S>(
    stream: S,
    router: Arc<PtyRouter>,
    capacity: usize,
) -> (ChannelPtyTransport, BridgeJoin)
where
    S: AsyncRead + AsyncWrite + Send + Unpin + 'static,
{
    // Default: bridge starts at seq=1. Callers that did a separate
    // handshake before handing the stream over should use
    // `spawn_pty_bridge_with_seq` instead so seq numbering stays
    // monotonic per-connection.
    spawn_pty_bridge_with_seq(stream, router, capacity, 1)
}

/// Same as [`spawn_pty_bridge`] but lets the caller pick the starting
/// `seq` for the writer task. Used by [`connect_pty_bridge`], which
/// does the `Hello`/`HelloAck` handshake at seq=1 before delegating
/// here at seq=2.
pub fn spawn_pty_bridge_with_seq<S>(
    stream: S,
    router: Arc<PtyRouter>,
    capacity: usize,
    starting_seq: u64,
) -> (ChannelPtyTransport, BridgeJoin)
where
    S: AsyncRead + AsyncWrite + Send + Unpin + 'static,
{
    let (transport, rx) = ChannelPtyTransport::new(capacity);
    let (read_half, write_half) = tokio::io::split(stream);

    let writer = tokio::spawn(writer_task(write_half, rx, starting_seq));
    let reader = tokio::spawn(reader_task(read_half, router));

    (transport, BridgeJoin { writer, reader })
}

/// Connect: do the `Hello`/`HelloAck` handshake on `stream`, then
/// spawn the framing tasks with `seq` advanced past the handshake.
/// One-shot composition so callers don't have to coordinate seq
/// numbers manually.
///
/// `hello_from` and `capabilities` are sent in the outgoing Hello so
/// the in-VM headless can log which side connected with which
/// feature set.
///
/// Returns the established transport, the bridge join handle, AND
/// the wire_version the peer reported (so the caller can log/assert
/// version compatibility).
pub async fn connect_pty_bridge<S>(
    stream: S,
    router: Arc<PtyRouter>,
    capacity: usize,
    hello_from: String,
    capabilities: Vec<String>,
) -> std::io::Result<(ChannelPtyTransport, BridgeJoin, u16)>
where
    S: AsyncRead + AsyncWrite + Send + Unpin + 'static,
{
    let (mut read_half, mut write_half) = tokio::io::split(stream);

    // Send Hello (seq=1).
    let hello = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: 1,
        body: ControlMessage::Hello {
            from: hello_from,
            capabilities,
        },
    };
    let bytes =
        encode(&hello).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    write_half
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .await?;
    write_half.write_all(&bytes).await?;
    write_half.flush().await?;

    // Read HelloAck.
    let mut len_buf = [0u8; 4];
    read_half.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_MESSAGE_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("HelloAck frame too large ({len} > {MAX_MESSAGE_BYTES})"),
        ));
    }
    let mut body = vec![0u8; len];
    read_half.read_exact(&mut body).await?;
    let envelope =
        decode(&body).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    let wire_version = match envelope.body {
        ControlMessage::HelloAck { wire_version, .. } => {
            if wire_version != WIRE_VERSION {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!("wire version mismatch: local={WIRE_VERSION} server={wire_version}"),
                ));
            }
            wire_version
        }
        other => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("expected HelloAck, got {other:?}"),
            ));
        }
    };

    // Rejoin halves into Send-friendly task spawns. We can't put them
    // back into a single `S` (tokio::io::split is one-way), so we
    // spawn writer/reader directly with the halves we already have.
    let (transport, rx) = ChannelPtyTransport::new(capacity);
    let writer = tokio::spawn(writer_task(write_half, rx, 2));
    let reader = tokio::spawn(reader_task(read_half, router));

    Ok((transport, BridgeJoin { writer, reader }, wire_version))
}

async fn writer_task<W>(
    mut writer: W,
    mut rx: tokio::sync::mpsc::Receiver<ControlMessage>,
    starting_seq: u64,
) where
    W: AsyncWrite + Unpin + Send + 'static,
{
    let seq = AtomicU64::new(starting_seq);
    while let Some(body) = rx.recv().await {
        let envelope = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: seq.fetch_add(1, Ordering::Relaxed),
            body,
        };
        let bytes = match encode(&envelope) {
            Ok(b) => b,
            Err(e) => {
                eprintln!("[pty-vsock-bridge] encode failed: {e}");
                continue;
            }
        };
        if bytes.len() > MAX_MESSAGE_BYTES {
            eprintln!(
                "[pty-vsock-bridge] outbound frame too large ({} > {})",
                bytes.len(),
                MAX_MESSAGE_BYTES
            );
            continue;
        }
        if writer
            .write_all(&(bytes.len() as u32).to_be_bytes())
            .await
            .is_err()
        {
            break;
        }
        if writer.write_all(&bytes).await.is_err() {
            break;
        }
        if writer.flush().await.is_err() {
            break;
        }
    }
}

async fn reader_task<R>(mut reader: R, router: Arc<PtyRouter>)
where
    R: AsyncRead + Unpin + Send + 'static,
{
    loop {
        let mut len_buf = [0u8; 4];
        if reader.read_exact(&mut len_buf).await.is_err() {
            break; // EOF or vsock dropped
        }
        let len = u32::from_be_bytes(len_buf) as usize;
        if len > MAX_MESSAGE_BYTES {
            eprintln!(
                "[pty-vsock-bridge] inbound frame too large ({} > {}); aborting reader",
                len, MAX_MESSAGE_BYTES
            );
            break;
        }
        let mut body = vec![0u8; len];
        if reader.read_exact(&mut body).await.is_err() {
            break;
        }
        let envelope = match decode(&body) {
            Ok(e) => e,
            Err(e) => {
                eprintln!("[pty-vsock-bridge] decode failed: {e}");
                continue;
            }
        };
        if let Err(e) = router.route(&envelope.body) {
            // PtyRouter rejects unrouted ControlMessages — non-fatal
            // for non-PTY traffic (handshake replies, status, etc.).
            eprintln!("[pty-vsock-bridge] route returned: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tillandsias_host_shell::pty::PtyTransport;

    /// Writer task encodes a `ControlMessage::Hello` into the
    /// expected `[len BE][postcard payload]` framing.
    #[tokio::test]
    async fn writer_frames_outbound_messages_correctly() {
        let (a, mut b) = tokio::io::duplex(8192);
        let router = Arc::new(PtyRouter::new());
        let (transport, join) = spawn_pty_bridge(a, router, 8);

        transport
            .send(ControlMessage::Hello {
                from: "test".to_string(),
                capabilities: vec!["X".to_string()],
            })
            .expect("send into bounded mpsc");

        // Drop the transport so the writer task EOFs on the rx side.
        drop(transport);

        // Read one frame off the other half of the duplex.
        let mut len_buf = [0u8; 4];
        b.read_exact(&mut len_buf).await.expect("read length");
        let len = u32::from_be_bytes(len_buf) as usize;
        assert!(
            (1..=MAX_MESSAGE_BYTES).contains(&len),
            "length out of range: {len}"
        );
        let mut payload = vec![0u8; len];
        b.read_exact(&mut payload).await.expect("read payload");
        let envelope = decode(&payload).expect("postcard decode");
        assert_eq!(envelope.wire_version, WIRE_VERSION);
        assert_eq!(envelope.seq, 1);
        match envelope.body {
            ControlMessage::Hello { from, capabilities } => {
                assert_eq!(from, "test");
                assert_eq!(capabilities, vec!["X"]);
            }
            other => panic!("expected Hello, got {other:?}"),
        }

        // Close the test's side of the duplex so the reader task EOFs
        // and the .join() can complete (otherwise it blocks forever).
        drop(b);
        join.join().await;
    }

    /// `connect_pty_bridge` performs the Hello/HelloAck handshake on
    /// the supplied stream, then resumes framing at seq=2. Simulates
    /// the in-VM headless on the other half of the duplex.
    #[tokio::test]
    async fn connect_pty_bridge_does_handshake_then_starts_framing() {
        let (host_side, peer_side) = tokio::io::duplex(8192);
        let router = Arc::new(PtyRouter::new());

        // Spawn the "in-VM headless" side: read Hello, send HelloAck,
        // then read the next outbound frame to assert seq=2.
        let peer = tokio::spawn(async move {
            let (mut r, mut w) = tokio::io::split(peer_side);
            // Read Hello length + body.
            let mut len_buf = [0u8; 4];
            r.read_exact(&mut len_buf).await.expect("read hello len");
            let len = u32::from_be_bytes(len_buf) as usize;
            let mut buf = vec![0u8; len];
            r.read_exact(&mut buf).await.expect("read hello body");
            let env = decode(&buf).expect("decode hello");
            assert_eq!(env.seq, 1);
            match env.body {
                ControlMessage::Hello { from, .. } => assert_eq!(from, "test-host"),
                other => panic!("expected Hello, got {other:?}"),
            }

            // Send HelloAck (seq=1 from the peer's seq space).
            let ack = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 1,
                body: ControlMessage::HelloAck {
                    wire_version: WIRE_VERSION,
                    server_caps: vec!["pty.attach@v1".into()],
                },
            };
            let ab = encode(&ack).expect("encode ack");
            w.write_all(&(ab.len() as u32).to_be_bytes())
                .await
                .expect("write ack len");
            w.write_all(&ab).await.expect("write ack body");
            w.flush().await.expect("flush ack");

            // Read the first POST-handshake frame and assert seq=2.
            let mut lb = [0u8; 4];
            r.read_exact(&mut lb).await.expect("read post-hs len");
            let l = u32::from_be_bytes(lb) as usize;
            let mut pb = vec![0u8; l];
            r.read_exact(&mut pb).await.expect("read post-hs body");
            let post = decode(&pb).expect("decode post-hs");
            assert_eq!(post.seq, 2, "post-handshake seq should be 2");
            // Drop w to EOF the host bridge's reader.
            drop(w);
            drop(r);
        });

        let (transport, join, wire_version) = connect_pty_bridge(
            host_side,
            router,
            8,
            "test-host".to_string(),
            vec!["pty.attach@v1".to_string()],
        )
        .await
        .expect("handshake completes");
        assert_eq!(wire_version, WIRE_VERSION);

        // Send a frame; the peer will assert it carries seq=2.
        transport
            .send(ControlMessage::PtyResize {
                session_id: 99,
                rows: 24,
                cols: 80,
            })
            .expect("send into mpsc");

        peer.await.expect("peer task finishes cleanly");
        drop(transport);
        join.join().await;
    }

    /// Reader task decodes a framed `PtyData` and dispatches it
    /// through the router to a registered session.
    #[tokio::test]
    async fn reader_routes_inbound_pty_data() {
        let (a, mut b) = tokio::io::duplex(8192);
        let router = Arc::new(PtyRouter::new());
        let mut inbox = router.register(7);
        let (_transport, join) = spawn_pty_bridge(a, router, 8);

        // Hand-frame an inbound PtyData{ToHost} for session 7.
        use tillandsias_control_wire::PtyDirection;
        let env = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::PtyData {
                session_id: 7,
                direction: PtyDirection::ToHost,
                bytes: b"hello".to_vec(),
            },
        };
        let payload = encode(&env).expect("encode test envelope");
        b.write_all(&(payload.len() as u32).to_be_bytes())
            .await
            .expect("write len");
        b.write_all(&payload).await.expect("write payload");
        b.flush().await.expect("flush");

        // Reader should route the message into the session 7 inbox.
        use tillandsias_host_shell::pty::SessionEvent;
        let ev = tokio::time::timeout(std::time::Duration::from_secs(2), inbox.recv())
            .await
            .expect("router delivers within 2s")
            .expect("inbox not closed");
        match ev {
            SessionEvent::Data(bytes) => assert_eq!(bytes, b"hello"),
            other => panic!("expected Data, got {other:?}"),
        }
        // Close the writer half (b) to EOF the reader task so it exits.
        drop(b);
        let _ = join; // drop, both tasks unwind on EOF
    }
}
