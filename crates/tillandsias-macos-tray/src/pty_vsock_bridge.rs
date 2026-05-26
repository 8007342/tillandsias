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
    decode, encode, ControlEnvelope, ControlMessage, MAX_MESSAGE_BYTES, WIRE_VERSION,
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
    let (transport, rx) = ChannelPtyTransport::new(capacity);
    let (read_half, write_half) = tokio::io::split(stream);

    let writer = tokio::spawn(writer_task(write_half, rx));
    let reader = tokio::spawn(reader_task(read_half, router));

    (transport, BridgeJoin { writer, reader })
}

async fn writer_task<W>(mut writer: W, mut rx: tokio::sync::mpsc::Receiver<ControlMessage>)
where
    W: AsyncWrite + Unpin + Send + 'static,
{
    let seq = AtomicU64::new(1);
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
