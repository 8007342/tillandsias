//! Tray-host control socket.
//!
//! Single Unix-domain stream socket bound by the tray at startup, listened
//! on for the entire tray lifetime, unlinked at graceful shutdown. Carries
//! typed, postcard-framed, length-prefixed messages between the tray and
//! bind-mounted consumer containers (router, future host-browser-mcp,
//! future log-event ingest).
//!
//! v1 wires up the lifecycle (bind, permissions, stale recovery, accept
//! loop, graceful shutdown) and the `Hello` / `HelloAck` handshake. The
//! `IssueWebSession` variant exists in the wire schema but is not yet
//! handled — it lands with the `opencode-web-session-otp` change.
//!
//! @trace spec:tray-host-control-socket
//! @cheatsheet languages/rust.md
//! @cheatsheet runtime/networking.md

pub mod handler;
pub mod path;
pub mod wire;

// ============================================================================
// @windows-migration:control-socket
//
// The entire Server implementation below depends on Unix-domain sockets
// (`std::os::unix::net::UnixListener`, `tokio::net::{UnixListener, UnixStream}`).
// Windows has named pipes (`tokio::net::windows::named_pipe`) but the wire
// protocol, path discovery, accept loop, stale-recovery probe, and
// bind-mount-into-container handoff are all Unix-shaped today.
//
// Until the Windows port lands (the windows-next branch is migrating from
// podman to WSL on a separate box; that work will replace the entire
// host↔container channel for Windows), this module is gated `#[cfg(unix)]`.
// On non-Unix targets we provide stub types that satisfy the public API
// surface so the tray crate compiles, but every constructor returns
// `ErrorKind::Unsupported` — the tray's existing error path treats this as
// "router won't start" which is the same visible behavior we'd get from a
// missing socket node anyway.
//
// When the windows-migration agents pick this up, search for the literal
// `@windows-migration:control-socket` to find every gated/stubbed block.
// The full Unix implementation below the cfg gate is the reference for
// what semantics need to be replicated on the new transport.
// ============================================================================

#[cfg(unix)]
use std::io;
#[cfg(unix)]
use std::os::unix::net::UnixListener as StdUnixListener;
#[cfg(unix)]
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::sync::Arc;
#[cfg(unix)]
use std::time::Duration;

#[cfg(unix)]
use bytes::{Bytes, BytesMut};
#[cfg(unix)]
use futures_util::{SinkExt, StreamExt};
#[cfg(unix)]
use tokio::io::AsyncWriteExt;
#[cfg(unix)]
use tokio::net::{UnixListener, UnixStream};
#[cfg(unix)]
use tokio::sync::{Notify, Semaphore, broadcast};
#[cfg(unix)]
use tokio::task::JoinHandle;
#[cfg(unix)]
use tokio::time::timeout;
#[cfg(unix)]
use tokio_util::codec::{Framed, LengthDelimitedCodec};
#[cfg(unix)]
use tracing::{debug, info, warn};

#[cfg(unix)]
use self::handler::{DispatchOutcome, dispatch, wire_version_mismatch};
#[cfg(unix)]
use self::path::{CONTAINER_SOCKET_PATH, ResolvedSocketPath, SocketPathSource};
#[cfg(unix)]
use self::wire::{ControlEnvelope, ControlMessage, ErrorCode, MAX_MESSAGE_BYTES, WIRE_VERSION};

#[cfg(unix)]
/// Maximum simultaneous accepted connections. Beyond this, the kernel
/// `accept` queue holds the next connection until a permit is released.
pub const MAX_CONNECTIONS: usize = 32;

#[cfg(unix)]
/// Per-connection idle timeout. Connections with no inbound bytes for
/// longer than this are closed.
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(60);

#[cfg(unix)]
/// Broadcast channel capacity for server-initiated envelopes (e.g.
/// `IssueWebSession` fan-out to subscribed router sidecars). A subscriber
/// that falls more than this many messages behind the producer receives
/// `broadcast::error::RecvError::Lagged` and the connection closes — the
/// sidecar's reconnect loop handles resync.
///
/// 64 is enough headroom for tray-side issuance bursts (one envelope per
/// "Attach Here" click; humans don't click 64 times per second) without
/// pinning much memory if a subscriber stalls.
///
/// @trace spec:opencode-web-session-otp
pub const BROADCAST_CAPACITY: usize = 64;

#[cfg(unix)]
/// Probe deadlines used by the stale-socket recovery path. A live tray
/// instance MUST respond to a `Hello` within these bounds; otherwise the
/// existing socket node is treated as a stale leftover.
const PROBE_CONNECT_DEADLINE: Duration = Duration::from_millis(200);
#[cfg(unix)]
const PROBE_READ_DEADLINE: Duration = Duration::from_millis(500);

#[cfg(unix)]
/// Outcome of probing an existing socket node at startup.
#[derive(Debug, PartialEq, Eq)]
pub enum StaleProbeOutcome {
    /// Another tray instance is alive and answered our probe — caller
    /// SHOULD exit through the singleton-guard path.
    LivePeer,
    /// No path existed, or the path was a stale leftover that we've now
    /// unlinked. Caller may proceed to bind.
    Stale,
    /// The path was not a socket at all (regular file, directory, …).
    /// Caller should treat this as a startup error.
    NotASocket,
}

#[cfg(unix)]
/// Builder result holding the live listener and the cleanup handle.
///
/// The listener is held as a `std::os::unix::net::UnixListener` so that
/// `bind()` can be called from any thread WITHOUT requiring an active
/// Tokio runtime (Tauri's `setup` callback runs synchronously before the
/// runtime starts). The std listener is converted to a tokio listener
/// via `UnixListener::from_std()` inside `spawn_accept_loop`, which
/// must be called from a Tokio runtime context.
pub struct Server {
    listener: Option<StdUnixListener>,
    socket_path: PathBuf,
    shutdown: Arc<Notify>,
    accept_handle: Option<JoinHandle<()>>,
    /// Server-initiated envelope publisher. Each accepted connection
    /// subscribes; tray code calls `publisher().send(msg)` to fan out.
    /// Today the only producer is the OTP issuance path (chunk 6 wires
    /// the `otp::issue_session_and_publish` call site).
    publisher: broadcast::Sender<ControlMessage>,
}

#[cfg(unix)]
impl Server {
    /// Bind the control socket using the resolved freedesktop runtime path.
    ///
    /// Creates the parent directory with mode `0700` if absent, recovers
    /// any stale socket node left behind by a previous crashed instance,
    /// binds the listener, and chmods the node to `0600` between `bind(2)`
    /// and any `accept(2)` call.
    ///
    /// @trace spec:tray-host-control-socket
    pub fn bind_default() -> io::Result<Self> {
        let resolved = path::resolve();
        Self::bind(resolved)
    }

    /// Bind at an explicit resolved location. Exposed for tests.
    ///
    /// @trace spec:tray-host-control-socket
    pub fn bind(resolved: ResolvedSocketPath) -> io::Result<Self> {
        let ResolvedSocketPath {
            parent_dir,
            socket_path,
            source,
        } = resolved;

        if matches!(source, SocketPathSource::PerUserTmp | SocketPathSource::Tmpdir) {
            info!(
                accountability = true,
                category = "control-socket",
                spec = "tray-host-control-socket",
                cheatsheet = "runtime/networking.md",
                operation = "fallback-path",
                source = ?source,
                parent = %parent_dir.display(),
                "XDG_RUNTIME_DIR unset; using fallback location"
            );
        }

        ensure_parent_dir(&parent_dir)?;

        // Stale-socket recovery before bind. This is best-effort; on
        // platforms where probing isn't supported we simply attempt to
        // unlink and retry once.
        match probe_existing_socket(&socket_path) {
            StaleProbeOutcome::LivePeer => {
                warn!(
                    accountability = true,
                    category = "control-socket",
                    spec = "tray-host-control-socket",
                    operation = "live-peer",
                    path = %socket_path.display(),
                    "Another tray instance owns the control socket — refusing to bind"
                );
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    "another tillandsias tray owns the control socket",
                ));
            }
            StaleProbeOutcome::Stale => {
                if socket_path.exists() {
                    info!(
                        accountability = true,
                        category = "control-socket",
                        spec = "tray-host-control-socket",
                        operation = "stale-cleanup",
                        path = %socket_path.display(),
                        "Removing stale control socket from a previous tray instance"
                    );
                    if let Err(e) = std::fs::remove_file(&socket_path) {
                        warn!(error = %e, "Failed to unlink stale socket — bind will likely fail");
                    }
                }
            }
            StaleProbeOutcome::NotASocket => {
                warn!(
                    accountability = true,
                    category = "control-socket",
                    spec = "tray-host-control-socket",
                    operation = "not-a-socket",
                    path = %socket_path.display(),
                    "Refusing to bind: existing path is not a socket"
                );
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "control socket path exists but is not a socket",
                ));
            }
        }

        // Use std::os::unix::net::UnixListener (no runtime needed) for the
        // initial bind. Tokio's UnixListener::bind() requires an active
        // Tokio runtime to register with the reactor, but Tauri's `setup`
        // callback runs synchronously before any runtime is live. The std
        // listener is converted to tokio inside `spawn_accept_loop` (which
        // is called from a runtime context).
        //
        // Mark non-blocking now so that `from_std()` doesn't have to do it
        // later — `from_std()` requires the fd to already be non-blocking.
        let listener = StdUnixListener::bind(&socket_path)?;
        listener.set_nonblocking(true)?;
        // Chmod between bind and accept — closes the race where another
        // user could connect during the brief default-mode window.
        chmod_0600(&socket_path)?;

        info!(
            accountability = true,
            category = "control-socket",
            spec = "tray-host-control-socket",
            cheatsheet = "runtime/networking.md",
            operation = "bind",
            path = %socket_path.display(),
            source = ?source,
            "Control socket bound (mode 0600, parent 0700)"
        );

        let (publisher, _) = broadcast::channel(BROADCAST_CAPACITY);

        Ok(Self {
            listener: Some(listener),
            socket_path,
            shutdown: Arc::new(Notify::new()),
            accept_handle: None,
            publisher,
        })
    }

    /// Clone of the broadcast publisher. Tray code calls `.send(msg)` to
    /// fan an envelope out to every connected subscriber. Returns
    /// `SendError` when there are zero subscribers — callers should treat
    /// that as "no router-sidecar connected yet" and proceed (the cookie
    /// minted in tray-local state is still valid; the next sidecar to
    /// connect will miss this issuance until it reconnects).
    ///
    /// @trace spec:opencode-web-session-otp, spec:tray-host-control-socket
    pub fn publisher(&self) -> broadcast::Sender<ControlMessage> {
        self.publisher.clone()
    }

    /// Path of the bound socket node. Used to populate the bind-mount
    /// source for consumer containers.
    ///
    /// API surface — exposed for diagnostic CLI commands and future
    /// `IssueWebSession` flows that may need to surface the host path.
    #[allow(dead_code)]
    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    /// Spawn the accept loop. Returns immediately; the loop continues
    /// until `shutdown()` is called.
    ///
    /// MUST be called from a Tokio runtime context — this is where the
    /// std listener is converted to a tokio listener via `from_std()`,
    /// which registers the fd with the reactor.
    ///
    /// @trace spec:tray-host-control-socket
    pub fn spawn_accept_loop(&mut self) {
        let Some(std_listener) = self.listener.take() else {
            warn!("Control-socket accept loop already running");
            return;
        };
        // Convert from std to tokio inside the runtime context. This
        // panics if no runtime is active — caller bug, not a runtime
        // failure.
        let listener = match UnixListener::from_std(std_listener) {
            Ok(l) => l,
            Err(e) => {
                warn!(
                    spec = "tray-host-control-socket",
                    error = %e,
                    "Failed to register control-socket listener with the Tokio reactor — accept loop will not start"
                );
                return;
            }
        };
        let shutdown = self.shutdown.clone();
        let semaphore = Arc::new(Semaphore::new(MAX_CONNECTIONS));
        let publisher = self.publisher.clone();
        let handle = tokio::spawn(async move {
            run_accept_loop(listener, shutdown, semaphore, publisher).await;
        });
        self.accept_handle = Some(handle);
    }

    /// Signal graceful shutdown. The accept loop stops accepting new
    /// connections; in-flight tasks finish naturally. The socket node is
    /// unlinked by `Drop`.
    ///
    /// @trace spec:tray-host-control-socket
    pub async fn shutdown(&mut self) {
        self.shutdown.notify_waiters();
        if let Some(handle) = self.accept_handle.take() {
            // Give the accept loop 200 ms to drain.
            let _ = timeout(Duration::from_millis(200), handle).await;
        }
    }
}

#[cfg(unix)]
impl Drop for Server {
    fn drop(&mut self) {
        // Best-effort socket unlink — may fail if another component already
        // cleaned up. Logged at debug because graceful shutdown SHOULD have
        // emitted an info-level entry already.
        match std::fs::remove_file(&self.socket_path) {
            Ok(()) => {
                info!(
                    accountability = true,
                    category = "control-socket",
                    spec = "tray-host-control-socket",
                    operation = "unlink",
                    path = %self.socket_path.display(),
                    "Control socket unlinked on shutdown"
                );
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                debug!(
                    path = %self.socket_path.display(),
                    "Control socket already gone at Drop time"
                );
            }
            Err(e) => {
                debug!(
                    error = %e,
                    path = %self.socket_path.display(),
                    "Failed to unlink control socket on Drop"
                );
            }
        }
    }
}

#[cfg(unix)]
/// Ensure the parent directory exists with mode `0700`.
///
/// If the directory already exists with a more permissive mode, we tighten
/// it to `0700` — the freedesktop spec already mandates `0700` for
/// `$XDG_RUNTIME_DIR`, but the fallback `/tmp` path may default looser.
///
/// @trace spec:tray-host-control-socket
fn ensure_parent_dir(parent_dir: &Path) -> io::Result<()> {
    std::fs::create_dir_all(parent_dir)?;
    chmod_dir_0700(parent_dir)?;
    Ok(())
}

#[cfg(unix)]
fn chmod_dir_0700(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let perms = std::fs::Permissions::from_mode(0o700);
    std::fs::set_permissions(path, perms)
}

// @windows-migration:control-socket
// Pre-existing #[cfg(not(unix))] stubs for chmod_dir_0700 / chmod_0600 were
// removed when the whole control_socket impl was gated on #[cfg(unix)].
// They referenced `Path` and `io::Result` which are now unix-only imports.
// They are dead code on Windows: the only callers (ensure_parent_dir and
// Server::bind) are themselves #[cfg(unix)] and unreachable on Windows.

#[cfg(unix)]
fn chmod_0600(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let perms = std::fs::Permissions::from_mode(0o600);
    std::fs::set_permissions(path, perms)
}

#[cfg(unix)]
/// Probe an existing socket node (if any) to distinguish a live tray peer
/// from a stale leftover or a non-socket path.
///
/// @trace spec:tray-host-control-socket
pub fn probe_existing_socket(path: &Path) -> StaleProbeOutcome {
    use std::os::unix::fs::FileTypeExt;

    let meta = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return StaleProbeOutcome::Stale,
        Err(_) => return StaleProbeOutcome::Stale,
    };

    if !meta.file_type().is_socket() {
        return StaleProbeOutcome::NotASocket;
    }

    // Probe via a short-lived blocking connect on the std library so we
    // don't need a tokio runtime when called from the synchronous startup
    // path. The probe deadlines are short enough (200 ms / 500 ms) that
    // blocking is acceptable.
    use std::io::{Read, Write};
    use std::os::unix::net::UnixStream as StdUnixStream;

    let mut stream = match StdUnixStream::connect(path) {
        Ok(s) => s,
        Err(_) => return StaleProbeOutcome::Stale,
    };

    if stream.set_read_timeout(Some(PROBE_READ_DEADLINE)).is_err()
        || stream.set_write_timeout(Some(PROBE_CONNECT_DEADLINE)).is_err()
    {
        return StaleProbeOutcome::Stale;
    }

    // Send a Hello envelope. If the peer is alive it should answer with a
    // HelloAck (or at least something that decodes). We treat any response
    // — even garbage — as "live peer", and any disconnect / timeout as
    // "stale".
    let envelope = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: 0,
        body: ControlMessage::Hello {
            from: "tray-probe".to_string(),
            capabilities: vec![],
        },
    };
    let payload = match wire::encode(&envelope) {
        Ok(p) => p,
        Err(_) => return StaleProbeOutcome::Stale,
    };
    let mut frame = Vec::with_capacity(4 + payload.len());
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(&payload);
    if stream.write_all(&frame).is_err() {
        return StaleProbeOutcome::Stale;
    }

    let mut buf = [0u8; 4];
    match stream.read(&mut buf) {
        Ok(0) => StaleProbeOutcome::Stale,
        Ok(_) => StaleProbeOutcome::LivePeer,
        Err(_) => StaleProbeOutcome::Stale,
    }
}

#[cfg(unix)]
/// Top-level accept loop. Backpressures via `Semaphore` so the tray cannot
/// be DoS'd by a flood of consumer connections.
///
/// @trace spec:tray-host-control-socket
async fn run_accept_loop(
    listener: UnixListener,
    shutdown: Arc<Notify>,
    semaphore: Arc<Semaphore>,
    publisher: broadcast::Sender<ControlMessage>,
) {
    loop {
        let permit = match semaphore.clone().acquire_owned().await {
            Ok(p) => p,
            Err(_) => {
                debug!("Control-socket semaphore closed — exiting accept loop");
                return;
            }
        };

        tokio::select! {
            biased;
            _ = shutdown.notified() => {
                debug!(
                    spec = "tray-host-control-socket",
                    "Control-socket accept loop received shutdown — exiting"
                );
                drop(permit);
                return;
            }
            accepted = listener.accept() => {
                match accepted {
                    Ok((stream, _addr)) => {
                        let conn_shutdown = shutdown.clone();
                        let broadcast_rx = publisher.subscribe();
                        tokio::spawn(async move {
                            let _permit = permit; // released when this task exits
                            handle_connection(stream, conn_shutdown, broadcast_rx).await;
                        });
                    }
                    Err(e) => {
                        warn!(error = %e, "Control-socket accept failed; continuing");
                        drop(permit);
                    }
                }
            }
        }
    }
}

#[cfg(unix)]
/// Per-connection state machine: read frames, dispatch, write replies.
///
/// Enforces the per-connection idle timeout (60 s) and the per-frame size
/// cap (64 KiB). Panics in handlers are isolated to this task — other
/// connections continue.
///
/// @trace spec:tray-host-control-socket
async fn handle_connection(
    stream: UnixStream,
    shutdown: Arc<Notify>,
    mut broadcast_rx: broadcast::Receiver<ControlMessage>,
) {
    let codec = LengthDelimitedCodec::builder()
        .length_field_length(4)
        .max_frame_length(MAX_MESSAGE_BYTES)
        .big_endian()
        .new_codec();
    let mut framed = Framed::new(stream, codec);

    info!(
        accountability = true,
        category = "control-socket",
        spec = "tray-host-control-socket",
        operation = "accept",
        "Control-socket connection accepted"
    );

    // Per-connection counter for SERVER-initiated frames (broadcasts). Inbound
    // frames echo the peer's seq; outbound starts at 1 and grows monotonically
    // so subscribers can detect missed frames if they wanted to (chunk 6 may
    // surface this in a Resync envelope).
    let mut outbound_seq: u64 = 0;

    loop {
        let read = tokio::select! {
            biased;
            _ = shutdown.notified() => {
                debug!(spec = "tray-host-control-socket", "Connection drop on shutdown");
                break;
            }
            broadcast = broadcast_rx.recv() => {
                match broadcast {
                    Ok(msg) => {
                        outbound_seq += 1;
                        let env = ControlEnvelope {
                            wire_version: WIRE_VERSION,
                            seq: outbound_seq,
                            body: msg,
                        };
                        if let Err(e) = write_envelope(&mut framed, &env).await {
                            debug!(
                                spec = "opencode-web-session-otp",
                                error = %e,
                                "Broadcast write failed; closing connection"
                            );
                            break;
                        }
                        continue;
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        info!(
                            accountability = true,
                            category = "control-socket",
                            spec = "opencode-web-session-otp",
                            operation = "subscriber-lagged",
                            skipped,
                            "Subscriber fell behind broadcast queue — closing for resync"
                        );
                        break;
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        debug!(
                            spec = "tray-host-control-socket",
                            "Broadcast channel closed — server going away"
                        );
                        break;
                    }
                }
            }
            r = timeout(IDLE_TIMEOUT, framed.next()) => r,
        };

        let frame = match read {
            Ok(Some(Ok(bytes))) => bytes,
            Ok(Some(Err(e))) => {
                // Codec error — likely oversized frame.
                let kind = e.kind();
                if kind == io::ErrorKind::InvalidData {
                    let env = ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: 0,
                        body: ControlMessage::Error {
                            seq_in_reply_to: None,
                            code: ErrorCode::PayloadTooLarge,
                            message: "frame exceeded MAX_MESSAGE_BYTES".to_string(),
                        },
                    };
                    let _ = write_envelope(&mut framed, &env).await;
                }
                debug!(error = %e, "Control-socket frame read failed; closing");
                break;
            }
            Ok(None) => {
                debug!("Control-socket peer closed");
                break;
            }
            Err(_) => {
                info!(
                    accountability = true,
                    category = "control-socket",
                    spec = "tray-host-control-socket",
                    operation = "idle-timeout",
                    "Control-socket connection idle for {:?} — closing",
                    IDLE_TIMEOUT
                );
                break;
            }
        };

        let envelope = match wire::decode(&frame) {
            Ok(e) => e,
            Err(decode_err) => {
                warn!(
                    accountability = true,
                    category = "control-socket",
                    spec = "tray-host-control-socket",
                    operation = "decode-failed",
                    error = %decode_err,
                    "Control-socket envelope decode failed"
                );
                let env = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 0,
                    body: ControlMessage::Error {
                        seq_in_reply_to: None,
                        code: ErrorCode::UnknownVariant,
                        message: format!("decode failed: {decode_err}"),
                    },
                };
                let _ = write_envelope(&mut framed, &env).await;
                continue;
            }
        };

        if envelope.wire_version != WIRE_VERSION {
            warn!(
                accountability = true,
                category = "control-socket",
                spec = "tray-host-control-socket",
                operation = "wire-version-mismatch",
                peer_version = envelope.wire_version,
                server_version = WIRE_VERSION,
                "Control-socket wire-version mismatch — closing"
            );
            let reply = wire_version_mismatch(envelope.seq, envelope.wire_version);
            let env = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: envelope.seq,
                body: reply,
            };
            let _ = write_envelope(&mut framed, &env).await;
            break;
        }

        // Capture an instance of `from` for the Hello logging path before
        // the borrow on `body` ends.
        if let ControlMessage::Hello {
            from, capabilities, ..
        } = &envelope.body
        {
            info!(
                accountability = true,
                category = "control-socket",
                spec = "tray-host-control-socket",
                operation = "hello",
                from = %from,
                caps = capabilities.len(),
                "Control-socket peer handshake"
            );
        }

        let outcome = dispatch(envelope.seq, &envelope.body);
        match outcome {
            DispatchOutcome::Reply(reply) => {
                let env = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: envelope.seq,
                    body: reply,
                };
                if let Err(e) = write_envelope(&mut framed, &env).await {
                    debug!(error = %e, "Failed to write reply — closing");
                    break;
                }
            }
            DispatchOutcome::ReplyAndClose(reply) => {
                let env = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: envelope.seq,
                    body: reply,
                };
                let _ = write_envelope(&mut framed, &env).await;
                break;
            }
            DispatchOutcome::NoReply => {}
        }
    }

    // Flush before drop so any final reply lands.
    let mut stream = framed.into_inner();
    let _ = stream.shutdown().await;
    debug!(
        spec = "tray-host-control-socket",
        "Control-socket connection closed"
    );
}

#[cfg(unix)]
/// Frame an envelope onto the wire.
///
/// Encoding errors are mapped to an `io::Error` so callers can decide
/// whether to close the connection.
///
/// @trace spec:tray-host-control-socket
async fn write_envelope(
    framed: &mut Framed<UnixStream, LengthDelimitedCodec>,
    envelope: &ControlEnvelope,
) -> io::Result<()> {
    let bytes = wire::encode(envelope)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string()))?;
    let buf: Bytes = BytesMut::from(&bytes[..]).freeze();
    framed
        .send(buf)
        .await
        .map_err(|e| io::Error::other(e.to_string()))
}

#[cfg(unix)]
/// Fixed in-container path consumers connect to. Re-exported from the
/// `path` module for callers that need it without importing the whole
/// module.
///
/// API surface — used by future client-library code in consumer crates.
#[allow(dead_code)]
pub fn container_socket_path() -> &'static str {
    CONTAINER_SOCKET_PATH
}

// ============================================================================
// @windows-migration:control-socket
//
// Windows stubs. The unix Server above does not compile on Windows because
// it depends on Unix-domain sockets; everything below is the minimal
// satisfaction of the public API surface used by `src-tauri/src/main.rs` and
// `src-tauri/src/event_loop.rs` so the tray crate compiles for the
// `x86_64-pc-windows-msvc` target.
//
// At runtime, `Server::bind_default()` returns `ErrorKind::Unsupported` and
// the existing tray error path treats that the same way it treats a missing
// socket node on Unix: log a warning, continue running the tray, accept
// that any container that opts in via `mount_control_socket = true` (today,
// the router) will fail to launch. There are no router builds on Windows in
// v1, so this is an acceptable degradation.
//
// **Windows-migration agents**: when you reimplement the host↔container
// channel for Windows (likely on top of WSL named pipes or HTTP-over-loopback
// since the windows-next branch is migrating off podman), replace these
// stubs with real implementations. The Unix Server above is the reference
// for required semantics: bind / stale-recovery probe / accept loop with a
// per-connection idle timeout / graceful shutdown / `Hello`-`HelloAck`
// handshake / `IssueWebSession` broadcast fan-out to subscribed sidecars.
//
// All stub methods are documented as "unreachable on Windows" because the
// `Ok(server)` arm of `match Server::bind_default()` in main.rs is never
// taken on Windows (bind_default always returns Err). They exist only so
// the type-checker can verify the Ok arm.
// ============================================================================

#[cfg(not(unix))]
pub struct Server {
    _phantom: std::marker::PhantomData<()>,
}

#[cfg(not(unix))]
impl Server {
    /// Windows stub: always returns `ErrorKind::Unsupported`. The tray's
    /// existing error path logs and continues without the control socket.
    /// @windows-migration:control-socket
    pub fn bind_default() -> std::io::Result<Self> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "control_socket::Server is not implemented on Windows; \
             tracked by windows-migration:control-socket — the windows-next \
             branch will replace this with a WSL/named-pipe transport",
        ))
    }

    /// Windows stub: unreachable (Server is never constructed on Windows
    /// because `bind_default` returns Err). Returns a fresh broadcast
    /// sender whose receiver is dropped immediately — `send()` calls will
    /// fail with `SendError` (no subscribers), which the OTP path already
    /// tolerates as "no router-sidecar connected yet".
    /// @windows-migration:control-socket
    pub fn publisher(
        &self,
    ) -> tokio::sync::broadcast::Sender<tillandsias_control_wire::ControlMessage> {
        let (tx, _rx) = tokio::sync::broadcast::channel(1);
        tx
    }

    /// Windows stub: unreachable. No-op.
    /// @windows-migration:control-socket
    pub fn spawn_accept_loop(&mut self) {}

    /// Windows stub: unreachable. No-op.
    /// @windows-migration:control-socket
    pub async fn shutdown(&mut self) {}
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use tempfile::TempDir;

    fn resolved_in(dir: &Path) -> ResolvedSocketPath {
        let parent_dir = dir.join("tillandsias");
        let socket_path = parent_dir.join("control.sock");
        ResolvedSocketPath {
            parent_dir,
            socket_path,
            source: SocketPathSource::XdgRuntimeDir,
        }
    }

    #[tokio::test]
    async fn bind_creates_socket_with_owner_only_perms() {
        let tmp = TempDir::new().unwrap();
        let resolved = resolved_in(tmp.path());

        let server = Server::bind(resolved.clone()).expect("bind succeeds");

        // Parent dir 0700.
        let parent_meta = std::fs::metadata(&resolved.parent_dir).unwrap();
        let parent_mode = parent_meta.permissions().mode() & 0o7777;
        assert_eq!(parent_mode, 0o700, "parent dir must be 0700");

        // Socket node 0600.
        let sock_meta = std::fs::metadata(&resolved.socket_path).unwrap();
        let sock_mode = sock_meta.permissions().mode() & 0o7777;
        assert_eq!(sock_mode, 0o600, "socket node must be 0600");

        drop(server);

        // Drop unlinks.
        assert!(
            !resolved.socket_path.exists(),
            "socket should be unlinked on drop"
        );
    }

    #[test]
    fn probe_returns_stale_when_path_missing() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("missing.sock");
        assert_eq!(probe_existing_socket(&path), StaleProbeOutcome::Stale);
    }

    #[test]
    fn probe_returns_not_a_socket_for_regular_file() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("regular.sock");
        std::fs::write(&path, b"not a socket").unwrap();
        assert_eq!(probe_existing_socket(&path), StaleProbeOutcome::NotASocket);
    }

    #[test]
    fn second_bind_at_same_path_fails_with_live_peer() {
        let tmp = TempDir::new().unwrap();
        let resolved = resolved_in(tmp.path());

        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();

        let mut server = rt.block_on(async {
            let mut s = Server::bind(resolved.clone()).expect("first bind succeeds");
            s.spawn_accept_loop();
            // Yield so the accept loop is actively listening before the probe.
            tokio::task::yield_now().await;
            s
        });

        // Second bind must detect the live peer and refuse.
        let result = Server::bind(resolved);
        assert!(
            matches!(&result, Err(e) if e.kind() == io::ErrorKind::AddrInUse),
            "expected AddrInUse, got {:?}",
            result.as_ref().err()
        );

        rt.block_on(async {
            server.shutdown().await;
        });
    }

    #[tokio::test]
    async fn stale_socket_is_recovered() {
        let tmp = TempDir::new().unwrap();
        let resolved = resolved_in(tmp.path());

        // First bind, then drop the listener WITHOUT going through Server's
        // graceful shutdown path. We simulate a crashed prior instance by
        // binding via std and letting it be destroyed without unlink.
        std::fs::create_dir_all(&resolved.parent_dir).unwrap();
        {
            use std::os::unix::net::UnixListener as StdUnixListener;
            let _listener = StdUnixListener::bind(&resolved.socket_path).unwrap();
            // Drop without unlink — std doesn't auto-unlink on drop, so the
            // socket node persists. The listener's process-side state is
            // gone though, so any new connect should fail with ECONNREFUSED.
        }

        assert!(
            resolved.socket_path.exists(),
            "stale socket should still be on disk"
        );
        assert_eq!(
            probe_existing_socket(&resolved.socket_path),
            StaleProbeOutcome::Stale,
            "stale node must probe as Stale"
        );

        // Server::bind should detect the stale node, unlink it, and bind.
        let server = Server::bind(resolved.clone()).expect("stale recovery succeeds");
        assert!(resolved.socket_path.exists());
        drop(server);
    }

    #[tokio::test]
    async fn hello_handshake_round_trips_across_socket() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let tmp = TempDir::new().unwrap();
        let resolved = resolved_in(tmp.path());
        let mut server = Server::bind(resolved.clone()).expect("bind");
        server.spawn_accept_loop();

        // Give the accept loop a tick to be fully ready.
        tokio::task::yield_now().await;

        let mut client = UnixStream::connect(&resolved.socket_path)
            .await
            .expect("client connect");

        let envelope = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::Hello {
                from: "test-client".to_string(),
                capabilities: vec![],
            },
        };
        let payload = wire::encode(&envelope).unwrap();
        client
            .write_all(&(payload.len() as u32).to_be_bytes())
            .await
            .unwrap();
        client.write_all(&payload).await.unwrap();
        client.flush().await.unwrap();

        // Read reply: 4-byte length + payload.
        let mut len_buf = [0u8; 4];
        client.read_exact(&mut len_buf).await.unwrap();
        let len = u32::from_be_bytes(len_buf) as usize;
        assert!(len <= MAX_MESSAGE_BYTES);
        let mut payload = vec![0u8; len];
        client.read_exact(&mut payload).await.unwrap();
        let reply = wire::decode(&payload).unwrap();

        assert_eq!(reply.seq, 1);
        match reply.body {
            ControlMessage::HelloAck {
                wire_version,
                server_caps,
            } => {
                assert_eq!(wire_version, WIRE_VERSION);
                assert!(server_caps.contains(&"v1".to_string()));
                assert!(
                    server_caps.contains(&"IssueWebSession".to_string()),
                    "HelloAck must advertise IssueWebSession capability post opencode-web-session-otp"
                );
            }
            other => panic!("expected HelloAck, got {:?}", other),
        }

        server.shutdown().await;
    }

    /// A server-side `publisher().send()` reaches every connected
    /// subscriber. Two clients connect, complete `Hello`, then the server
    /// publishes one envelope and both clients read it.
    ///
    /// @trace spec:opencode-web-session-otp
    #[tokio::test]
    async fn publisher_fanout_reaches_two_connected_clients() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let tmp = TempDir::new().unwrap();
        let resolved = resolved_in(tmp.path());
        let mut server = Server::bind(resolved.clone()).expect("bind");
        server.spawn_accept_loop();
        let publisher = server.publisher();

        // Helper: connect a client + complete Hello/HelloAck. Returns the
        // open stream so the test can read the upcoming broadcast.
        async fn handshake(socket_path: &Path) -> UnixStream {
            let mut s = UnixStream::connect(socket_path).await.expect("connect");
            let env = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 1,
                body: ControlMessage::Hello {
                    from: "fanout-test".to_string(),
                    capabilities: vec![],
                },
            };
            let payload = wire::encode(&env).unwrap();
            s.write_all(&(payload.len() as u32).to_be_bytes())
                .await
                .unwrap();
            s.write_all(&payload).await.unwrap();
            // Drain the HelloAck so the read loop is positioned at the
            // next inbound frame (which will be our broadcast).
            let mut len_buf = [0u8; 4];
            s.read_exact(&mut len_buf).await.unwrap();
            let len = u32::from_be_bytes(len_buf) as usize;
            let mut payload = vec![0u8; len];
            s.read_exact(&mut payload).await.unwrap();
            let _ack = wire::decode(&payload).unwrap();
            s
        }

        let mut client_a = handshake(&resolved.socket_path).await;
        let mut client_b = handshake(&resolved.socket_path).await;

        // Yield so both connections are subscribed to the broadcast channel.
        tokio::task::yield_now().await;

        // Publish one IssueWebSession envelope.
        let cookie: [u8; 32] = std::array::from_fn(|i| i as u8 ^ 0xA5);
        publisher
            .send(ControlMessage::IssueWebSession {
                project_label: "opencode.fanout.localhost".to_string(),
                cookie_value: cookie,
            })
            .expect("at least one subscriber");

        // Both clients see it.
        async fn read_envelope(s: &mut UnixStream) -> ControlEnvelope {
            let mut len_buf = [0u8; 4];
            s.read_exact(&mut len_buf).await.unwrap();
            let len = u32::from_be_bytes(len_buf) as usize;
            let mut payload = vec![0u8; len];
            s.read_exact(&mut payload).await.unwrap();
            wire::decode(&payload).unwrap()
        }

        let env_a = read_envelope(&mut client_a).await;
        let env_b = read_envelope(&mut client_b).await;
        for env in [&env_a, &env_b] {
            match &env.body {
                ControlMessage::IssueWebSession {
                    project_label,
                    cookie_value,
                } => {
                    assert_eq!(project_label, "opencode.fanout.localhost");
                    assert_eq!(cookie_value, &cookie);
                }
                other => panic!("expected IssueWebSession broadcast, got {:?}", other),
            }
            // Outbound seq is per-connection, starts at 1 for the first
            // server-initiated frame.
            assert_eq!(env.seq, 1);
        }

        server.shutdown().await;
    }

    /// A subscriber that falls behind by more than `BROADCAST_CAPACITY`
    /// frames receives `RecvError::Lagged` on its next `recv()` and the
    /// connection closes. The sidecar's reconnect loop handles resync.
    ///
    /// @trace spec:opencode-web-session-otp
    #[tokio::test]
    async fn lagged_subscriber_is_disconnected() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let tmp = TempDir::new().unwrap();
        let resolved = resolved_in(tmp.path());
        let mut server = Server::bind(resolved.clone()).expect("bind");
        server.spawn_accept_loop();
        let publisher = server.publisher();

        // Connect + Hello, then DON'T read any further — the connection is
        // a passive subscriber so the broadcast queue fills up.
        let mut client = UnixStream::connect(&resolved.socket_path)
            .await
            .expect("connect");
        let env = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::Hello {
                from: "lag-test".to_string(),
                capabilities: vec![],
            },
        };
        let payload = wire::encode(&env).unwrap();
        client
            .write_all(&(payload.len() as u32).to_be_bytes())
            .await
            .unwrap();
        client.write_all(&payload).await.unwrap();
        // Drain HelloAck.
        let mut len_buf = [0u8; 4];
        client.read_exact(&mut len_buf).await.unwrap();
        let len = u32::from_be_bytes(len_buf) as usize;
        let mut payload = vec![0u8; len];
        client.read_exact(&mut payload).await.unwrap();

        tokio::task::yield_now().await;

        // Drown the broadcast channel: send BROADCAST_CAPACITY * 2 + 4
        // envelopes. The handle_connection loop reads them one by one and
        // tries to write to the framed stream; the OS buffer eventually
        // fills, the write blocks, and the next broadcast::recv yields
        // Lagged because the sender has lapped us.
        let cookie = [0u8; 32];
        for _ in 0..(BROADCAST_CAPACITY * 2 + 4) {
            // send() returns SendError only when there are zero subscribers,
            // which can't happen here.
            let _ = publisher.send(ControlMessage::IssueWebSession {
                project_label: "opencode.lag.localhost".to_string(),
                cookie_value: cookie,
            });
        }

        // The lagged-subscriber path closes the connection. Try to read
        // some bytes from the client — eventually we hit EOF.
        let mut sink = vec![0u8; 4096];
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        let mut closed = false;
        while tokio::time::Instant::now() < deadline {
            match tokio::time::timeout(
                Duration::from_millis(100),
                client.read(&mut sink),
            )
            .await
            {
                Ok(Ok(0)) => {
                    closed = true;
                    break;
                }
                Ok(Ok(_)) => continue,
                Ok(Err(_)) => {
                    closed = true;
                    break;
                }
                Err(_) => continue,
            }
        }
        assert!(
            closed,
            "lagged subscriber connection must close within 2s"
        );

        server.shutdown().await;
    }
}
