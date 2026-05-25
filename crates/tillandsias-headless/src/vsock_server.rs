//! `--listen-vsock` mode: bind the control wire to a vsock listener instead
//! of the Linux Unix socket, so an in-VM tillandsias can serve the host-side
//! tray on Windows / macOS over virtio-vsock.
//!
//! Mirrors the Unix-socket handler in `tray::mod::handle_control_connection`:
//! reads the first frame as `Hello`, replies with `HelloAck`, then keeps the
//! connection open for VM-lifecycle / cloud-refresh request frames.
//!
//! Phase-2 scope is the handshake + a small request/reply set
//! (`VmStatusRequest`, `EnumerateLocalProjects`, `CloudRefreshRequest`,
//! `VmShutdownRequest`). Full menu-state propagation lands in Phase 3+.
//!
//! Linux-only, gated behind `feature = "listen-vsock"`.
//!
//! @trace spec:vsock-transport, spec:host-shell-architecture

use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tillandsias_control_wire::transport::{
    AsyncReadWrite, CONTROL_WIRE_VSOCK_PORT, Listener, Transport, bind,
};
use tillandsias_control_wire::{
    ControlEnvelope, ControlMessage, ErrorCode, MAX_MESSAGE_BYTES, VmPhase, WIRE_VERSION, decode,
    encode,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tracing::{debug, info, warn};

const SERVER_NAME: &str = "tillandsias-in-vm";

/// Bind a vsock listener on `VMADDR_CID_ANY:port` and serve control-wire
/// connections until `shutdown` is set.
///
/// Returns once the listener loop exits (either an unrecoverable bind error
/// at startup or `shutdown` flipped to true).
///
/// @trace spec:vsock-transport
pub async fn run_vsock_listener(port: u32, shutdown: Arc<AtomicBool>) -> io::Result<()> {
    let transport = Transport::Vsock {
        cid: vmaddr_cid_any(),
        port,
    };
    let mut listener = bind(&transport).await?;
    info!(
        spec = "vsock-transport",
        port = port,
        "control wire listening on vsock"
    );
    serve_listener(&mut listener, shutdown).await;
    Ok(())
}

/// Default vsock port for the control wire. Re-exported for the CLI to use
/// without depending on `control-wire::transport` directly.
#[allow(dead_code)]
pub const DEFAULT_LISTEN_PORT: u32 = CONTROL_WIRE_VSOCK_PORT;

fn vmaddr_cid_any() -> u32 {
    // `VMADDR_CID_ANY` is `-1` cast to `u32` in the vsock crate's public API.
    // We don't re-import the crate here because tests should remain feature-gated.
    u32::MAX
}

async fn serve_listener(listener: &mut Listener, shutdown: Arc<AtomicBool>) {
    loop {
        if shutdown.load(Ordering::SeqCst) {
            info!(
                spec = "vsock-transport",
                "vsock listener exiting (shutdown signalled)"
            );
            return;
        }
        // accept() borrows listener mutably; race against a short timer so we
        // can re-check the shutdown flag without an extra wake mechanism.
        let accept = tokio::time::timeout(Duration::from_millis(250), listener.accept()).await;
        match accept {
            Ok(Ok(stream)) => {
                tokio::spawn(handle_connection(stream));
            }
            Ok(Err(err)) => {
                warn!(spec = "vsock-transport", error = %err, "vsock accept failed");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            Err(_) => {
                // Timeout: loop and re-check shutdown.
            }
        }
    }
}

async fn handle_connection(mut stream: Box<dyn AsyncReadWrite + Unpin + Send>) {
    let first = match read_envelope(&mut stream).await {
        Ok(env) => env,
        Err(err) => {
            debug!(spec = "vsock-transport", error = %err, "vsock connection closed before Hello");
            return;
        }
    };

    if first.wire_version != WIRE_VERSION {
        warn!(
            spec = "vsock-transport",
            client_wire_version = first.wire_version,
            "rejecting vsock client with mismatched wire version"
        );
        return;
    }

    let hello_from = match &first.body {
        ControlMessage::Hello { from, .. } => from.clone(),
        other => {
            warn!(
                spec = "vsock-transport",
                first_frame = ?other,
                "first vsock frame was not Hello; closing"
            );
            return;
        }
    };
    debug!(spec = "vsock-transport", peer = %hello_from, "vsock client connected");

    let ack = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: first.seq,
        body: ControlMessage::HelloAck {
            wire_version: WIRE_VERSION,
            server_caps: vec![
                "VmStatusRequest".into(),
                "EnumerateLocalProjects".into(),
                "CloudRefreshRequest".into(),
                "VmShutdownRequest".into(),
            ],
        },
    };
    if let Err(err) = write_envelope(&mut stream, &ack).await {
        warn!(spec = "vsock-transport", error = %err, "failed to write HelloAck");
        return;
    }

    loop {
        let env = match read_envelope(&mut stream).await {
            Ok(env) => env,
            Err(err) => {
                debug!(spec = "vsock-transport", error = %err, "vsock connection closed");
                return;
            }
        };
        match env.body {
            ControlMessage::VmStatusRequest { seq } => {
                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::VmStatusReply {
                        seq_in_reply_to: seq,
                        phase: VmPhase::Ready,
                        podman_ready: true,
                        last_event: Some(SERVER_NAME.to_string()),
                    },
                };
                if write_envelope(&mut stream, &reply).await.is_err() {
                    return;
                }
            }
            ControlMessage::EnumerateLocalProjects { seq } => {
                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::LocalProjectsReply {
                        seq_in_reply_to: seq,
                        entries: Vec::new(),
                    },
                };
                if write_envelope(&mut stream, &reply).await.is_err() {
                    return;
                }
            }
            ControlMessage::CloudRefreshRequest { seq } => {
                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::CloudRefreshReply {
                        seq_in_reply_to: seq,
                        projects: Vec::new(),
                    },
                };
                if write_envelope(&mut stream, &reply).await.is_err() {
                    return;
                }
            }
            ControlMessage::VmShutdownRequest { .. } => {
                info!(
                    spec = "vsock-transport",
                    "VmShutdownRequest received; closing connection (drain happens via signal path)"
                );
                return;
            }
            // Per plan/issues/control-socket-protocol-convergence-2026-05-25.md:
            // unhandled variants must reply with an explicit Error frame
            // (Unsupported) instead of silently logging and continuing.
            // Clients otherwise hang waiting for a reply they will never get.
            other => {
                debug!(spec = "vsock-transport", msg = ?other, "rejecting unsupported vsock frame");
                let err = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::Error {
                        seq_in_reply_to: Some(env.seq),
                        code: ErrorCode::Unsupported,
                        message: format!(
                            "variant {:?} not handled by the in-VM vsock dispatcher",
                            std::mem::discriminant(&other),
                        ),
                    },
                };
                if write_envelope(&mut stream, &err).await.is_err() {
                    return;
                }
            }
        }
    }
}

async fn read_envelope<R>(stream: &mut R) -> io::Result<ControlEnvelope>
where
    R: AsyncReadExt + Unpin,
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
    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload).await?;
    decode(&payload).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

async fn write_envelope<W>(stream: &mut W, env: &ControlEnvelope) -> io::Result<()>
where
    W: AsyncWriteExt + Unpin,
{
    let bytes =
        encode(env).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    stream.write_all(&(bytes.len() as u32).to_be_bytes()).await?;
    stream.write_all(&bytes).await?;
    stream.flush().await
}
