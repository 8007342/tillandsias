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

use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::task::JoinHandle;

use tillandsias_control_wire::transport::control_frame_codec;
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
/// `capacity` is the outbound mpsc bound, keeping host RSS predictable
/// when the VM stalls (the Linux shared `Client` uses an effectively
/// unbounded write loop). Semantics per path: one-shot control ops use
/// the fail-fast `send` (a full queue surfaces as an error); the byte
/// pumps and the resize/close control path use `send_lossless`, which
/// AWAITS queue space — a stall backpressures the local terminal instead
/// of silently killing the input direction (audit D3, the host→guest
/// twin of the ea2fbc8d guest→host fix).
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
    // Framed once at the split, same as `connect_pty_bridge` (order 795-5itp).
    // This entry point does no handshake, so there is no earlier read whose
    // buffer could be stranded — but the tasks take framed halves either way,
    // which is what keeps a second codec policy from appearing on this path.
    let framed_read = tokio_util::codec::FramedRead::new(read_half, control_frame_codec());
    let framed_write = tokio_util::codec::FramedWrite::new(write_half, control_frame_codec());

    let writer = tokio::spawn(writer_task(framed_write, rx, starting_seq));
    let reader = tokio::spawn(reader_task(framed_read, router));

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
    // ORDER 795-5itp. FRAME ONCE, HERE, AND THREAD THE FRAMED HALVES INTO THE
    // TASKS — never a `Framed` per call.
    //
    // THIS SEAM IS THE MEASURED HAZARD, not a theoretical one. The HelloAck
    // read below and `reader_task`'s loop are two reads on ONE stream. A
    // `FramedRead` built here for the handshake and then dropped, handing the
    // raw half onward, would take any bytes it had already buffered past the
    // HelloAck with it — the guest pipelines PtyData immediately after the
    // HelloAck, so those are session bytes, and their loss is silent. The
    // packet records this as measured on the exec control path: "a per-call
    // Framed/FramedRead may read ahead and drop pipelined bytes when it is
    // dropped. That is a silent data-loss bug, not a compile error."
    //
    // So the codec is constructed once per half and the SAME `Framed` that
    // read the HelloAck is what `reader_task` keeps reading from. Its buffer is
    // never dropped, so there is nothing to lose.
    //
    // `control_frame_codec()` is the shared constructor (also 795-5itp), which
    // is where `max_frame_length` = MAX_MESSAGE_BYTES lives — one bound for the
    // whole tree rather than a copy per site.
    let (read_half, write_half) = tokio::io::split(stream);
    let mut framed_read = tokio_util::codec::FramedRead::new(read_half, control_frame_codec());
    let mut framed_write = tokio_util::codec::FramedWrite::new(write_half, control_frame_codec());

    // Send Hello (seq=1).
    let hello = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: 1,
        body: ControlMessage::Hello {
            from: hello_from,
            capabilities,
            build_version: None,
        },
    };
    let bytes =
        encode(&hello).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    // Order 828-r2ek. The HelloAck reader below (:169) bounds its inbound
    // frame and the PtyData sender (:241) bounds its outbound one; the Hello
    // that opens the session was the only write on this path with no bound at
    // all. An oversize Hello is refused by the guest's reader, so the bridge
    // would fail at HelloAck with no indication that the Hello was the cause.
    if bytes.len() > MAX_MESSAGE_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!(
                "Hello frame too large ({} > {MAX_MESSAGE_BYTES})",
                bytes.len()
            ),
        ));
    }
    // The codec writes the length prefix; `send` also flushes.
    framed_write.send(bytes.into()).await?;

    // Read HelloAck from the SAME framed half that reader_task will keep.
    // The oversize check the hand-rolled version performed here is now the
    // codec's `max_frame_length`, which surfaces as an InvalidData io::Error —
    // one bound, enforced before the body is ever allocated, rather than after
    // a length is read and trusted enough to size a Vec.
    let body = match framed_read.next().await {
        Some(Ok(frame)) => frame,
        Some(Err(e)) => return Err(e),
        None => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "stream closed before HelloAck",
            ));
        }
    };
    let envelope =
        decode(&body).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    let wire_version = match envelope.body {
        ControlMessage::HelloAck {
            wire_version,
            build_version,
            ..
        } => {
            if wire_version != WIRE_VERSION {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!("wire version mismatch: local={WIRE_VERSION} server={wire_version}"),
                ));
            }
            if let Some(guest_version) = build_version
                && guest_version != env!("WORKSPACE_VERSION")
            {
                tracing::warn!(
                    "build version skew: tray={} guest={}",
                    env!("WORKSPACE_VERSION"),
                    guest_version
                );
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
    // The framed halves are MOVED, buffers intact — see the note at the split.
    let writer = tokio::spawn(writer_task(framed_write, rx, 2));
    let reader = tokio::spawn(reader_task(framed_read, router));

    Ok((transport, BridgeJoin { writer, reader }, wire_version))
}

/// Takes the ALREADY-FRAMED write half (order 795-5itp), rather than a raw
/// `AsyncWrite` it frames itself. Constructing the codec here would put a
/// second `max_frame_length` policy on the same stream as the handshake's.
async fn writer_task<W>(
    mut writer: tokio_util::codec::FramedWrite<W, tokio_util::codec::LengthDelimitedCodec>,
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
        // `send` writes the length prefix and flushes. The explicit
        // oversize check above is KEPT rather than left to the codec: it
        // `continue`s past one too-large message, whereas the codec's error
        // would arrive as a stream error and break the session. A single
        // outsized PtyData should not end the terminal.
        if writer.send(bytes.into()).await.is_err() {
            break;
        }
    }
}

/// Takes the ALREADY-FRAMED read half (order 795-5itp) — the same one that read
/// the HelloAck, buffer intact. Framing here instead would drop whatever the
/// handshake's reader had buffered past the HelloAck; see the note at the split
/// in `connect_pty_bridge`.
async fn reader_task<R>(
    mut reader: tokio_util::codec::FramedRead<R, tokio_util::codec::LengthDelimitedCodec>,
    router: Arc<PtyRouter>,
) where
    R: AsyncRead + Unpin + Send + 'static,
{
    loop {
        // An oversize frame is now the codec's InvalidData error rather than a
        // length this loop bounds itself; either way the reader stops, which is
        // the same disposition the hand-rolled bound had.
        let body = match reader.next().await {
            Some(Ok(frame)) => frame,
            Some(Err(e)) => {
                eprintln!("[pty-vsock-bridge] inbound framing error: {e}; aborting reader");
                break;
            }
            None => break, // EOF or vsock dropped
        };
        let envelope = match decode(&body) {
            Ok(e) => e,
            Err(e) => {
                eprintln!("[pty-vsock-bridge] decode failed: {e}");
                continue;
            }
        };
        // Opt-in PTY forensics (TILLANDSIAS_PTY_DEBUG=1): mirror inbound
        // PtyData/PtyExit to stderr so a session's dying words survive the
        // popup terminal's alternate-screen teardown. The 2026-07-10
        // attended smoke lost a fast-failing agent launch's error text
        // exactly this way — the operator saw an unreadable flash, then a
        // blank window (findings F-J). Observability through the product's
        // own layer, not a host/guest side channel.
        if std::env::var_os("TILLANDSIAS_PTY_DEBUG").is_some_and(|v| v == "1") {
            match &envelope.body {
                tillandsias_control_wire::ControlMessage::PtyData {
                    session_id, bytes, ..
                } if !bytes.is_empty() => {
                    eprintln!(
                        "[pty-debug] session={} {} bytes: {}",
                        session_id,
                        bytes.len(),
                        String::from_utf8_lossy(bytes).escape_debug()
                    );
                }
                tillandsias_control_wire::ControlMessage::PtyClose { session_id, exit } => {
                    eprintln!(
                        "[pty-debug] session={session_id} CLOSE code={} signal={:?}",
                        exit.code, exit.signal
                    );
                }
                _ => {}
            }
        }
        if let Err(e) = router.route(&envelope.body).await {
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
    // The test PEERS stay hand-rolled on purpose (order 795-5itp). Production
    // now reads and writes through the shared codec, so a peer that decodes
    // `[u32 BE][body]` by hand is the only thing in this file still asserting
    // the WIRE FORMAT rather than asserting the codec against itself. Migrating
    // them would make these tests tautological — the same reasoning the packet
    // recorded when it kept `vsock_listener_e2e.rs` hand-rolled.
    //
    // Which is why these extension traits are imported HERE and not at the top:
    // production no longer needs them, and a top-level import would now be dead.
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

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
                build_version: None,
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
            ControlMessage::Hello {
                from,
                capabilities,
                build_version: _,
            } => {
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
                    build_version: None,
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

    /// REGRESSION GUARD for the hazard order 795-5itp calls measured, not
    /// argued: a `Framed` built for the handshake and dropped takes whatever it
    /// buffered past the HelloAck with it, and those bytes are session data.
    ///
    /// The existing handshake test cannot catch it — it sends the HelloAck and
    /// then READS, so nothing is ever in flight behind the ack. This one writes
    /// the HelloAck AND a PtyData frame in a single burst before the host has
    /// read either, which is what the guest actually does: it pipelines. If
    /// `connect_pty_bridge` ever frames per call again, the PtyData is consumed
    /// into a dropped buffer and this times out.
    ///
    /// It fails for the right reason too — a lost frame is a timeout on the
    /// inbox, not a decode error, which is exactly why the bug is silent in
    /// production.
    #[tokio::test]
    async fn pipelined_frame_behind_the_helloack_is_not_dropped() {
        let (host_side, peer_side) = tokio::io::duplex(8192);
        let router = Arc::new(PtyRouter::new());
        let mut inbox = router.register(9);

        let peer = tokio::spawn(async move {
            let (mut r, mut w) = tokio::io::split(peer_side);
            // Consume the Hello.
            let mut len_buf = [0u8; 4];
            r.read_exact(&mut len_buf).await.expect("read hello len");
            let len = u32::from_be_bytes(len_buf) as usize;
            let mut buf = vec![0u8; len];
            r.read_exact(&mut buf).await.expect("read hello body");

            // HelloAck and PtyData, back to back, ONE flush. The host has not
            // read anything yet, so both land in its socket buffer together —
            // and a handshake-scoped reader would take the second with it.
            let ack = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 1,
                body: ControlMessage::HelloAck {
                    wire_version: WIRE_VERSION,
                    server_caps: vec!["pty.attach@v1".into()],
                    build_version: None,
                },
            };
            use tillandsias_control_wire::PtyDirection;
            let data = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 2,
                body: ControlMessage::PtyData {
                    session_id: 9,
                    direction: PtyDirection::ToHost,
                    bytes: b"pipelined".to_vec(),
                },
            };
            let mut burst = Vec::new();
            for env in [&ack, &data] {
                let b = encode(env).expect("encode");
                burst.extend_from_slice(&(b.len() as u32).to_be_bytes());
                burst.extend_from_slice(&b);
            }
            w.write_all(&burst).await.expect("write burst");
            w.flush().await.expect("flush burst");
            // Hold the peer open; dropping here would race the assertion.
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        });

        let (_transport, join, _wire) = connect_pty_bridge(
            host_side,
            router,
            8,
            "test-host".to_string(),
            vec!["pty.attach@v1".to_string()],
        )
        .await
        .expect("handshake succeeds");

        use tillandsias_host_shell::pty::SessionEvent;
        let ev = tokio::time::timeout(std::time::Duration::from_secs(2), inbox.recv())
            .await
            .expect("the frame pipelined behind the HelloAck must still arrive")
            .expect("inbox not closed");
        match ev {
            SessionEvent::Data(bytes) => assert_eq!(bytes, b"pipelined"),
            other => panic!("expected Data, got {other:?}"),
        }
        peer.abort();
        let _ = join;
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
