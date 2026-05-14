//! Tillandsias router sidecar.
//!
//! Runs alongside Caddy inside the `tillandsias-router` container. Two jobs:
//!
//! 1. **Subscribe** to the tray's control socket (bind-mounted into the
//!    container at `TILLANDSIAS_CONTROL_SOCKET`, default
//!    `/run/host/tillandsias/control.sock`). Each `IssueWebSession` envelope
//!    pushes a session entry into a local [`tillandsias_otp::OtpStore`].
//!
//! 2. **Serve** Caddy's `forward_auth` directive on `127.0.0.1:9090`
//!    (override via `TILLANDSIAS_VALIDATE_PORT`). Every request to
//!    `<project>.opencode.localhost:8080` triggers a Caddy → sidecar
//!    HTTP `GET /validate?project=<label>` with the original `Cookie:`
//!    header forwarded. The sidecar replies `204` if the cookie value is
//!    in the project's session list, `401` otherwise.
//!
//! Failure modes:
//! - **Tray down at startup**: connect-loop retries with exponential backoff
//!   (250 ms → 8 s). The HTTP validator binds first so Caddy doesn't 502 on
//!   the first request — it just returns 401 because the store is empty.
//! - **Tray restarts mid-run**: read returns EOF; reconnect kicks in. The
//!   sidecar's session table KEEPS its existing entries (24 h client-side
//!   Max-Age outlives the reconnect window).
//! - **Sidecar lags broadcast**: server closes the connection on
//!   `RecvError::Lagged`; reconnect re-syncs (best-effort — in-flight
//!   issuances during the lag window are lost; spec calls this out).
//! - **Sidecar crash**: entrypoint.sh restarts it (chunk 4 wires the loop).
//!   Caddy keeps running; `forward_auth` 502s during the gap.
//!
//! @trace spec:opencode-web-session-otp, spec:tray-host-control-socket, spec:subdomain-naming-flip, spec:subdomain-routing-via-reverse-proxy

use std::env;
use std::path::PathBuf;
use std::time::Duration;

use bytes::{Bytes, BytesMut};
use futures_util::{SinkExt, StreamExt};
use tillandsias_control_wire::{
    ControlEnvelope, ControlMessage, MAX_MESSAGE_BYTES, WIRE_VERSION, decode, encode,
};
use tillandsias_otp::{OtpStore, global, spawn_eviction_task};
use tokio::net::UnixStream;
use tokio_util::codec::{Framed, LengthDelimitedCodec};
use tracing::{debug, info, warn};

mod http;

/// Default in-container path the tray's control socket is bind-mounted at.
/// Must match `crate::control_socket::path::CONTAINER_SOCKET_PATH` on the
/// tray side. Override via `TILLANDSIAS_CONTROL_SOCKET`.
const DEFAULT_SOCKET_PATH: &str = "/run/host/tillandsias/control.sock";

/// Default loopback port for the validate HTTP endpoint. Caddy's
/// `forward_auth` directive in `images/router/base.Caddyfile` (chunk 5)
/// targets `127.0.0.1:<this>`. Override via `TILLANDSIAS_VALIDATE_PORT`.
const DEFAULT_VALIDATE_PORT: u16 = 9090;

/// Initial reconnect backoff. Doubled per failure up to [`MAX_BACKOFF`].
const MIN_BACKOFF: Duration = Duration::from_millis(250);

/// Maximum reconnect backoff. Past this we keep retrying every 8 s; the
/// upper bound keeps the log volume sane during long outages.
const MAX_BACKOFF: Duration = Duration::from_secs(8);

#[tokio::main]
async fn main() {
    init_tracing();

    let socket_path: PathBuf = env::var_os("TILLANDSIAS_CONTROL_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_SOCKET_PATH));
    let validate_port: u16 = env::var("TILLANDSIAS_VALIDATE_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_VALIDATE_PORT);

    info!(
        spec = "opencode-web-session-otp",
        socket = %socket_path.display(),
        port = validate_port,
        "tillandsias-router-sidecar starting"
    );

    // Bind the validator FIRST so Caddy's forward_auth never sees connection
    // refused on first launch. An empty store means every request 401s, which
    // is the correct degraded behaviour while we wait for the tray.
    let store: &'static OtpStore = global();
    let _eviction = spawn_eviction_task();
    let _http = tokio::spawn(http::serve(validate_port, store));

    // Now the connect loop. Reconnect on every failure with exponential
    // backoff so a tray restart causes only a brief gap.
    let mut backoff = MIN_BACKOFF;
    loop {
        match connect_and_run(&socket_path, store).await {
            Ok(()) => {
                debug!(
                    spec = "opencode-web-session-otp",
                    "Control-socket subscribe loop exited normally; reconnecting"
                );
                backoff = MIN_BACKOFF;
            }
            Err(e) => {
                warn!(
                    spec = "opencode-web-session-otp",
                    error = %e,
                    "Control-socket connection failed; backing off {:?}",
                    backoff
                );
            }
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(MAX_BACKOFF);
    }
}

/// Connect to the control socket, send Hello, then loop reading envelopes
/// and dispatching them.
///
/// Returns `Ok(())` on clean EOF (server closed) so the outer loop resets
/// backoff and reconnects immediately. Returns `Err` for any I/O failure
/// (the outer loop applies backoff).
///
/// @trace spec:opencode-web-session-otp, spec:tray-host-control-socket
async fn connect_and_run(socket_path: &std::path::Path, store: &OtpStore) -> std::io::Result<()> {
    let stream = UnixStream::connect(socket_path).await?;
    let codec = LengthDelimitedCodec::builder()
        .length_field_length(4)
        .max_frame_length(MAX_MESSAGE_BYTES)
        .big_endian()
        .new_codec();
    let mut framed = Framed::new(stream, codec);

    // Hello handshake.
    let hello = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: 1,
        body: ControlMessage::Hello {
            from: "router-sidecar".to_string(),
            capabilities: vec!["IssueWebSession".to_string()],
        },
    };
    write_envelope(&mut framed, &hello).await?;

    // Read HelloAck. Reject mismatched wire_version.
    let result = framed.next().await;
    match result {
        Some(Ok(buf)) => {
            let env = decode(&buf)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))?;
            match env.body {
                ControlMessage::HelloAck { wire_version, .. } if wire_version == WIRE_VERSION => {
                    info!(
                        spec = "opencode-web-session-otp",
                        wire_version, "Control-socket Hello handshake complete"
                    );
                }
                ControlMessage::HelloAck { wire_version, .. } => {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::Unsupported,
                        format!(
                            "wire_version mismatch: server={}, sidecar={}",
                            wire_version, WIRE_VERSION
                        ),
                    ));
                }
                other => {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        format!("expected HelloAck, got {:?}", other),
                    ));
                }
            }
        }
        Some(Err(e)) => return Err(e),
        None => return Ok(()),
    }

    // Read loop.
    loop {
        match framed.next().await {
            Some(Ok(buf)) => {
                let env = match decode(&buf) {
                    Ok(e) => e,
                    Err(e) => {
                        warn!(
                            spec = "opencode-web-session-otp",
                            error = %e,
                            "Failed to decode control-socket envelope; ignoring"
                        );
                        continue;
                    }
                };
                match env.body {
                    ControlMessage::IssueWebSession {
                        project_label,
                        cookie_value,
                    } => {
                        store.push(&project_label, cookie_value);
                    }
                    ControlMessage::EvictProject { project_label } => {
                        // @trace spec:opencode-web-session-otp
                        // Sent by the tray when a project's container stack
                        // stops. Drop every session entry for that label so the
                        // sidecar doesn't keep honouring stale cookies on a
                        // future namespace reuse.
                        store.evict_project(&project_label);
                    }
                    other => {
                        debug!(
                            spec = "opencode-web-session-otp",
                            variant = ?std::mem::discriminant(&other),
                            "Ignoring non-OTP broadcast (sidecar consumes only IssueWebSession + EvictProject)"
                        );
                    }
                }
            }
            Some(Err(e)) => {
                warn!(
                    spec = "opencode-web-session-otp",
                    error = %e,
                    "Control-socket read error; breaking"
                );
                break;
            }
            None => break,
        }
    }

    Ok(())
}

async fn write_envelope(
    framed: &mut Framed<UnixStream, LengthDelimitedCodec>,
    envelope: &ControlEnvelope,
) -> std::io::Result<()> {
    let bytes = encode(envelope)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))?;
    let buf: Bytes = BytesMut::from(&bytes[..]).freeze();
    framed
        .send(buf)
        .await
        .map_err(|e| std::io::Error::other(e.to_string()))
}

fn init_tracing() {
    use tracing_subscriber::{EnvFilter, fmt};
    let filter =
        EnvFilter::try_from_env("TILLANDSIAS_LOG").unwrap_or_else(|_| EnvFilter::new("info"));
    fmt().with_env_filter(filter).with_target(false).init();
}
