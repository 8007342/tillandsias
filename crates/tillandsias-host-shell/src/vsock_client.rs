//! Vsock-or-Unix control-wire client for the host trays.
//!
//! Wraps `tillandsias-control-wire::transport::connect` and provides a
//! typed `request`/`handshake` surface over `ControlEnvelope`. The Linux
//! dev box uses the `Unix` transport for round-trip unit tests against a
//! fake in-process server; production Windows + macOS hosts open `Vsock`
//! to the in-VM headless.
//!
//! @trace spec:host-shell-architecture, spec:vsock-transport

#![allow(dead_code)]

use std::io;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};

use tillandsias_control_wire::transport::{
    self, AsyncReadWrite, CONTROL_WIRE_VSOCK_PORT, Transport,
};
use tillandsias_control_wire::{
    ControlEnvelope, ControlMessage, MAX_MESSAGE_BYTES, WIRE_VERSION, decode, encode,
};
use tillandsias_secure_channel::{HopId, channel_psk, client_handshake};
use tracing::info;

/// Default duration the client gives the in-VM headless to ack a `Hello`
/// before treating the VM as unreachable. Matches the
/// `host-shell-architecture.transport.vsock-client-lifecycle@v1`
/// "within 2s of VM start" budget.
pub const DEFAULT_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(2);

/// Canonical capability set advertised by ALL host senders (Windows tray,
/// macOS tray, host-shell test clients). Having a single source of truth
/// ensures `Hello` messages from both tray implementations are identical and
/// guarantees the headless sees `"pty.attach@v1"` (required by
/// spec:vsock-transport before any `PtyOpen` variant may be accepted).
///
/// @trace plan/issues/vsock-postmortem-host-guest-design-audit-2026-06-29.md (H6)
/// @trace openspec/changes/control-wire-pty-attach/specs/vsock-transport/spec.md
pub const STANDARD_HOST_CAPABILITIES: &[&str] = &[
    "VmStatusRequest",
    "VmShutdownRequest",
    "EnumerateLocalProjects",
    "CloudRefreshRequest",
    "pty.attach@v1",
];

/// Runtime gate env var for the secure control wire. Matches the server-side
/// convention in vsock_server.rs — set to `"on"` to enable Noise NNpsk0
/// handshake before Hello/HelloAck, `"off"` or absent for plaintext. Any
/// unrecognized value is an error (fail-closed) so a typo never silently
/// downgrades security.
///
/// Default: Off. Flip to `"on"` for the coordinated cross-host cutover
/// (order 145).
///
/// @trace plan/issues/secure-channel-maturity-ladder-2026-07-04.md
const SECURE_CONTROL_WIRE_ENV: &str = "TILLANDSIAS_SECURE_CONTROL_WIRE";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SecureControlWireMode {
    Off,
    On,
}

fn parse_secure_control_wire_mode(
    raw: Result<String, std::env::VarError>,
) -> Result<SecureControlWireMode, String> {
    match raw {
        Ok(v) if v.eq_ignore_ascii_case("on") => Ok(SecureControlWireMode::On),
        Ok(v) if v.eq_ignore_ascii_case("off") || v.is_empty() => Ok(SecureControlWireMode::Off),
        Ok(v) => Err(format!(
            "{SECURE_CONTROL_WIRE_ENV} must be 'on' or 'off' (got {v:?})"
        )),
        Err(std::env::VarError::NotPresent) => Ok(SecureControlWireMode::Off),
        Err(err) => Err(format!("{SECURE_CONTROL_WIRE_ENV}: {err}")),
    }
}

fn secure_control_wire_mode() -> Result<SecureControlWireMode, String> {
    static MODE: OnceLock<Result<SecureControlWireMode, String>> = OnceLock::new();
    MODE.get_or_init(|| parse_secure_control_wire_mode(std::env::var(SECURE_CONTROL_WIRE_ENV)))
        .clone()
}

/// Backoff schedule for the reconnect loop. Mirrors the spec's
/// `250ms / 500ms / 1s / 2s / 4s` cap.
pub const BACKOFF_SCHEDULE: &[Duration] = &[
    Duration::from_millis(250),
    Duration::from_millis(500),
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
];

/// A connected control-wire client.
///
/// Holds a single open transport stream and a monotonic per-connection
/// `seq` counter. The Linux dev loop uses `Transport::Unix`; production
/// Windows + macOS use `Transport::Vsock`.
pub struct Client {
    stream: Box<dyn AsyncReadWrite + Unpin + Send>,
    next_seq: AtomicU64,
    transport: Transport,
}

impl Client {
    /// Open a fresh connection to `transport`. Does not perform the
    /// `Hello`/`HelloAck` handshake — call `handshake()` next.
    pub async fn connect(transport: Transport) -> io::Result<Self> {
        let stream = transport::connect(&transport).await?;
        Ok(Self {
            stream,
            next_seq: AtomicU64::new(1),
            transport,
        })
    }

    /// Convenience constructor matching the Windows/macOS production path:
    /// connect over vsock to the given CID on the standard control port.
    pub async fn connect_vsock(cid: u32) -> io::Result<Self> {
        Self::connect(Transport::Vsock {
            cid,
            port: CONTROL_WIRE_VSOCK_PORT,
        })
        .await
    }

    /// Wrap a pre-opened stream as a `Client`. Used by hosts that open
    /// the underlying transport via a non-`tillandsias_control_wire`
    /// path (e.g. macOS opens vsock via `VZVirtioSocketConnection`,
    /// then hands the resulting AsyncRead+AsyncWrite stream here so
    /// the standard Hello/HelloAck + request/recv code paths can drive
    /// it). The caller carries responsibility for the `Transport`
    /// label used in diagnostics.
    pub fn from_stream(
        stream: Box<dyn AsyncReadWrite + Unpin + Send>,
        transport: Transport,
    ) -> Self {
        Self {
            stream,
            next_seq: AtomicU64::new(1),
            transport,
        }
    }

    fn next_seq(&self) -> u64 {
        self.next_seq.fetch_add(1, Ordering::Relaxed)
    }

    /// Send a `Hello` envelope and consume the `HelloAck` reply, returning
    /// the server's reported `wire_version`. Surfaces a wire-version
    /// mismatch as an `InvalidData` error.
    pub async fn handshake(&mut self) -> io::Result<u16> {
        let seq = self.next_seq();
        let hello = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
            body: ControlMessage::Hello {
                from: "tillandsias-host-shell".to_string(),
                capabilities: STANDARD_HOST_CAPABILITIES
                    .iter()
                    .map(|s| s.to_string())
                    .collect(),
            },
        };
        self.send(&hello).await?;
        let ack = self.recv().await?;
        match ack.body {
            ControlMessage::HelloAck { wire_version, .. } => {
                if wire_version != WIRE_VERSION {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!(
                            "wire version mismatch: local={} server={}",
                            WIRE_VERSION, wire_version
                        ),
                    ));
                }
                Ok(wire_version)
            }
            other => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("expected HelloAck, got {:?}", other),
            )),
        }
    }

    /// Send a single envelope and await the next inbound envelope. Callers
    /// requiring strict sequence correlation MUST filter on `seq` from the
    /// reply.
    pub async fn request(&mut self, envelope: &ControlEnvelope) -> io::Result<ControlEnvelope> {
        self.send(envelope).await?;
        self.recv().await
    }

    /// Allocate a fresh `seq` for outgoing envelopes the caller authors.
    pub fn allocate_seq(&self) -> u64 {
        self.next_seq()
    }

    /// Send a single envelope without awaiting a reply. Subscription-stream
    /// half of the tray reader-task pattern (orders 154/155): the caller sends
    /// `Subscribe` once, then drains pushes via [`Client::next_envelope`].
    pub async fn send_envelope(&mut self, envelope: &ControlEnvelope) -> io::Result<()> {
        self.send(envelope).await
    }

    /// Receive the next inbound envelope without sending anything. This is the
    /// push-stream read primitive: after `Subscribe`/`SubscribeAck`, the
    /// headless emits `VmStatusPush`/`LoginStatePush`/`CloudProjectsPush`
    /// frames unprompted, and a dedicated reader task loops on this call.
    /// Shared here (not per-tray) so the Windows and macOS reader tasks stay
    /// structurally identical.
    pub async fn next_envelope(&mut self) -> io::Result<ControlEnvelope> {
        self.recv().await
    }

    async fn send(&mut self, envelope: &ControlEnvelope) -> io::Result<()> {
        let bytes = encode(envelope).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        if bytes.len() > MAX_MESSAGE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "control frame too large",
            ));
        }
        self.stream
            .write_all(&(bytes.len() as u32).to_be_bytes())
            .await?;
        self.stream.write_all(&bytes).await?;
        self.stream.flush().await
    }

    async fn recv(&mut self) -> io::Result<ControlEnvelope> {
        let mut len_buf = [0u8; 4];
        self.stream.read_exact(&mut len_buf).await?;
        let len = u32::from_be_bytes(len_buf) as usize;
        if len > MAX_MESSAGE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "inbound control frame too large",
            ));
        }
        let mut body = vec![0u8; len];
        self.stream.read_exact(&mut body).await?;
        decode(&body).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }
}

/// Try `connect + handshake` once, with the given timeout for the whole
/// operation. Returns `Ok(Client)` on success, an `io::Error` otherwise.
///
/// When `TILLANDSIAS_SECURE_CONTROL_WIRE=on` is set, wraps the transport
/// stream with a Noise NNpsk0 handshake (version-bound PSK) before the
/// control-wire Hello/HelloAck exchange. Off by default — gated for the
/// coordinated cross-host cutover (order 145). Fail-closed on unrecognized
/// values.
///
/// @trace spec:host-shell-architecture.transport.vsock-client-lifecycle@v1
/// @trace plan/issues/encrypted-control-channel-impl-2026-07-01.md (slice 4)
pub async fn connect_with_handshake(transport: Transport, timeout: Duration) -> io::Result<Client> {
    match tokio::time::timeout(timeout, async {
        let raw = transport::connect(&transport).await?;
        let wrapped: Box<dyn AsyncReadWrite + Unpin + Send> = match secure_control_wire_mode()
            .map_err(io::Error::other)?
        {
            SecureControlWireMode::Off => raw,
            SecureControlWireMode::On => {
                let psk = channel_psk(crate::version(), WIRE_VERSION, HopId::HostGuest);
                let encrypted = client_handshake(raw, &psk).await?;
                info!(
                    spec = "vsock-transport",
                    "secure control wire handshake succeeded (TILLANDSIAS_SECURE_CONTROL_WIRE=on)"
                );
                Box::new(encrypted)
            }
        };
        let mut client = Client::from_stream(wrapped, transport);
        client.handshake().await?;
        Ok::<_, io::Error>(client)
    })
    .await
    {
        Ok(result) => result,
        Err(_) => Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "handshake timed out",
        )),
    }
}

// These round-trip tests drive the `Transport::Unix` path, which only exists
// on Unix (production Windows/macOS use `Transport::Vsock`). Gate the module
// on `unix` so `cargo test` compiles on the Windows host; Linux + macOS still
// run them.
#[cfg(test)]
mod capability_tests {
    use super::*;

    /// Both tray implementations send `Hello` using `STANDARD_HOST_CAPABILITIES`.
    /// This guards against drift (e.g. adding `"pty.attach@v1"` to one sender
    /// but not the other, breaking PTY attach on one platform).
    #[test]
    fn standard_capabilities_include_pty_attach() {
        assert!(
            STANDARD_HOST_CAPABILITIES.contains(&"pty.attach@v1"),
            "STANDARD_HOST_CAPABILITIES must include \"pty.attach@v1\" (required by spec:vsock-transport)"
        );
    }

    #[test]
    fn standard_capabilities_include_core_rpc_set() {
        for cap in &[
            "VmStatusRequest",
            "VmShutdownRequest",
            "EnumerateLocalProjects",
        ] {
            assert!(
                STANDARD_HOST_CAPABILITIES.contains(cap),
                "STANDARD_HOST_CAPABILITIES must include \"{cap}\""
            );
        }
    }
}

// Cross-platform (duplex-stream) tests — no OS socket, so they run on the
// Windows host too, unlike the `unix`-gated module below.
#[cfg(test)]
mod push_stream_tests {
    use super::*;

    fn encode_frame(env: &ControlEnvelope) -> Vec<u8> {
        let bytes = encode(env).expect("encode");
        let mut framed = (bytes.len() as u32).to_be_bytes().to_vec();
        framed.extend_from_slice(&bytes);
        framed
    }

    /// `next_envelope` reads unsolicited frames (the `Subscribe` →
    /// `SubscribeAck` → `VmStatusPush`… stream shape from order 152/153)
    /// without sending anything — the reader-task primitive for the tray
    /// stream refactors (orders 154/155).
    ///
    /// @trace spec:host-shell-architecture, spec:vsock-transport
    #[tokio::test]
    async fn next_envelope_reads_unsolicited_push_frames() {
        let (host_side, mut guest_side) = tokio::io::duplex(4096);
        let mut client = Client::from_stream(
            Box::new(host_side),
            Transport::Vsock {
                cid: 0,
                port: CONTROL_WIRE_VSOCK_PORT,
            },
        );

        // Guest pushes SubscribeAck then two VmStatusPush frames, unprompted.
        let frames = [
            ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 1,
                body: ControlMessage::SubscribeAck,
            },
            ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 2,
                body: ControlMessage::VmStatusPush {
                    seq: 2,
                    phase: tillandsias_control_wire::VmPhase::Starting,
                    podman_ready: false,
                    last_event: None,
                },
            },
            ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 3,
                body: ControlMessage::VmStatusPush {
                    seq: 3,
                    phase: tillandsias_control_wire::VmPhase::Ready,
                    podman_ready: true,
                    last_event: Some("tillandsias-in-vm".to_string()),
                },
            },
        ];
        for env in &frames {
            guest_side.write_all(&encode_frame(env)).await.unwrap();
        }
        guest_side.flush().await.unwrap();

        assert!(matches!(
            client.next_envelope().await.unwrap().body,
            ControlMessage::SubscribeAck
        ));
        assert!(matches!(
            client.next_envelope().await.unwrap().body,
            ControlMessage::VmStatusPush {
                phase: tillandsias_control_wire::VmPhase::Starting,
                podman_ready: false,
                ..
            }
        ));
        match client.next_envelope().await.unwrap().body {
            ControlMessage::VmStatusPush {
                phase,
                podman_ready,
                last_event,
                ..
            } => {
                assert_eq!(phase, tillandsias_control_wire::VmPhase::Ready);
                assert!(podman_ready);
                assert_eq!(last_event.as_deref(), Some("tillandsias-in-vm"));
            }
            other => panic!("expected VmStatusPush, got {other:?}"),
        }
    }

    /// `send_envelope` writes a correctly framed envelope the peer can decode
    /// — the Subscribe-send half of the reader-task pattern.
    #[tokio::test]
    async fn send_envelope_frames_subscribe_for_peer() {
        let (host_side, mut guest_side) = tokio::io::duplex(4096);
        let mut client = Client::from_stream(
            Box::new(host_side),
            Transport::Vsock {
                cid: 0,
                port: CONTROL_WIRE_VSOCK_PORT,
            },
        );

        let seq = client.allocate_seq();
        client
            .send_envelope(&ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq,
                body: ControlMessage::Subscribe {
                    topics: vec![tillandsias_control_wire::SubscriptionTopic::VmStatus],
                },
            })
            .await
            .unwrap();

        let mut len_buf = [0u8; 4];
        guest_side.read_exact(&mut len_buf).await.unwrap();
        let len = u32::from_be_bytes(len_buf) as usize;
        let mut body = vec![0u8; len];
        guest_side.read_exact(&mut body).await.unwrap();
        let env = decode(&body).unwrap();
        match env.body {
            ControlMessage::Subscribe { topics } => {
                assert_eq!(
                    topics,
                    vec![tillandsias_control_wire::SubscriptionTopic::VmStatus]
                );
            }
            other => panic!("expected Subscribe, got {other:?}"),
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use tokio::net::UnixListener;

    async fn spawn_hello_responder(path: std::path::PathBuf) -> tokio::task::JoinHandle<()> {
        let listener = UnixListener::bind(&path).expect("bind responder");
        tokio::spawn(async move {
            let (mut stream, _addr) = listener.accept().await.expect("accept");
            // Read Hello.
            let mut len_buf = [0u8; 4];
            stream.read_exact(&mut len_buf).await.expect("read len");
            let len = u32::from_be_bytes(len_buf) as usize;
            let mut body = vec![0u8; len];
            stream.read_exact(&mut body).await.expect("read body");
            let env = decode(&body).expect("decode");
            assert!(matches!(env.body, ControlMessage::Hello { .. }));
            // Reply with HelloAck.
            let ack = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: env.seq,
                body: ControlMessage::HelloAck {
                    wire_version: WIRE_VERSION,
                    server_caps: vec!["v1".to_string()],
                },
            };
            let ack_bytes = encode(&ack).expect("encode ack");
            stream
                .write_all(&(ack_bytes.len() as u32).to_be_bytes())
                .await
                .expect("write len");
            stream.write_all(&ack_bytes).await.expect("write ack");
            stream.flush().await.expect("flush");
            // Keep the stream alive briefly so the client can complete the read.
            tokio::time::sleep(Duration::from_millis(100)).await;
        })
    }

    /// @trace spec:host-shell-architecture, spec:vsock-transport
    #[tokio::test]
    async fn handshake_succeeds_against_fake_unix_server() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("control.sock");
        let _server = spawn_hello_responder(path.clone()).await;
        // Give the listener a moment to bind.
        tokio::time::sleep(Duration::from_millis(50)).await;

        let client = connect_with_handshake(Transport::Unix(path), DEFAULT_HANDSHAKE_TIMEOUT)
            .await
            .expect("handshake succeeds");
        // After handshake the next seq is 2 (we consumed 1 for Hello).
        assert_eq!(client.next_seq.load(Ordering::Relaxed), 2);
    }

    /// `Client::from_stream` accepts a pre-opened stream (the macOS
    /// vsock path produces one via VZVirtioSocketConnection rather
    /// than the standard `Transport::Vsock` connect path). Verifies
    /// the wrapped client drives the same Hello/HelloAck handshake
    /// the standard `connect_with_handshake` does.
    ///
    /// @trace spec:host-shell-architecture.transport.vsock-client-lifecycle@v1,
    ///        plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 4)
    #[tokio::test]
    async fn from_stream_handshake_drives_pre_opened_stream() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("from-stream.sock");
        let _server = spawn_hello_responder(path.clone()).await;
        tokio::time::sleep(Duration::from_millis(50)).await;

        let stream = tokio::net::UnixStream::connect(&path)
            .await
            .expect("connect");
        let mut client = Client::from_stream(Box::new(stream), Transport::Unix(path));
        let wire = client.handshake().await.expect("handshake succeeds");
        assert_eq!(wire, WIRE_VERSION);
        // After handshake the next seq is 2 (we consumed 1 for Hello).
        assert_eq!(client.next_seq.load(Ordering::Relaxed), 2);
    }

    #[tokio::test]
    async fn handshake_times_out_when_server_does_not_reply() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("control.sock");
        // Bind a listener but never accept — connect succeeds at the kernel
        // level (Unix), and the subsequent handshake read will block until
        // the timeout fires.
        let _listener = UnixListener::bind(&path).expect("bind");
        let result =
            connect_with_handshake(Transport::Unix(path), Duration::from_millis(150)).await;
        match result {
            Err(err) => assert_eq!(err.kind(), io::ErrorKind::TimedOut),
            Ok(_) => panic!("handshake against silent server must time out"),
        }
    }
}
