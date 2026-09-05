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

// Only the test-side fake guest peers still frame by hand (order 795-5itp
// migrated the production path onto the shared codec). Keeping their framing
// hand-rolled is deliberate: it is what proves codec↔hand-rolled interop on
// the real client, so these peers must NOT be migrated with it.
#[cfg(test)]
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use futures_util::{SinkExt, StreamExt};
use tokio_util::codec::{Framed, LengthDelimitedCodec};

use tillandsias_control_wire::transport::{
    self, AsyncReadWrite, CONTROL_WIRE_VSOCK_PORT, Transport, control_frame_codec,
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
    // 997-e4v2 step 3: "EnumerateLocalProjects" left with the wire variant. A
    // capability string is a PROMISE — advertising an RPC the guest no longer
    // implements is worse than not advertising it, because a peer selects on
    // this list.
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
    /// The control wire, framed by the shared codec rather than by hand
    /// (order 795-5itp). `Framed` OWNS the stream and its read buffer, which
    /// is safe here precisely because this field is private with no accessor,
    /// no `into_inner`, and no split: nothing can take the stream back and
    /// resume reading it by hand, which is the way a partial migration
    /// strands buffered bytes and desynchronises the wire.
    framed: Framed<Box<dyn AsyncReadWrite + Unpin + Send>, LengthDelimitedCodec>,
    next_seq: AtomicU64,
    transport: Transport,
    /// Capabilities the guest advertised in HelloAck, recorded so hosts can
    /// feature-detect instead of comparing wire versions (order 823-u5zf).
    /// Empty until `handshake()` has run.
    server_caps: Vec<String>,
}

impl Client {
    /// Open a fresh connection to `transport`. Does not perform the
    /// `Hello`/`HelloAck` handshake — call `handshake()` next.
    pub async fn connect(transport: Transport) -> io::Result<Self> {
        let stream = transport::connect(&transport).await?;
        Ok(Self {
            framed: Framed::new(stream, control_frame_codec()),
            next_seq: AtomicU64::new(1),
            transport,
            server_caps: Vec::new(),
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
            framed: Framed::new(stream, control_frame_codec()),
            next_seq: AtomicU64::new(1),
            transport,
            server_caps: Vec::new(),
        }
    }

    fn next_seq(&self) -> u64 {
        self.next_seq.fetch_add(1, Ordering::Relaxed)
    }

    /// Send a `Hello` envelope and consume the `HelloAck` reply, returning
    /// the server's reported `wire_version`. Surfaces a wire-version
    /// mismatch as an `InvalidData` error.
    pub async fn handshake(&mut self) -> io::Result<(u16, Option<String>)> {
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
                build_version: None,
            },
        };
        self.send(&hello).await?;
        let ack = self.recv().await?;
        match ack.body {
            ControlMessage::HelloAck {
                wire_version,
                build_version,
                server_caps,
                ..
            } => {
                if wire_version != WIRE_VERSION {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!(
                            "wire version mismatch: local={} server={}",
                            WIRE_VERSION, wire_version
                        ),
                    ));
                }
                // Order 823-u5zf: record what the guest advertised. The
                // capability list was destructured away here, so
                // CAP_EXEC_ARGV_VECTOR's own rule — "hosts MUST feature-detect
                // on this ... read HelloAck.server_caps, never compare wire
                // versions" — was impossible for any caller to follow.
                self.server_caps = server_caps;
                Ok((wire_version, build_version))
            }
            other => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("expected HelloAck, got {:?}", other),
            )),
        }
    }

    /// Capabilities the guest advertised in its `HelloAck`.
    ///
    /// Empty before [`Client::handshake`] has run — an empty slice therefore
    /// means "not yet asked", never "the guest supports nothing". Callers that
    /// branch on a capability must handshake first.
    pub fn server_caps(&self) -> &[String] {
        &self.server_caps
    }

    /// Does the guest advertise `cap`?
    ///
    /// This is the feature-detection path the wire's own capability constants
    /// mandate: `CAP_EXEC_ARGV_VECTOR`'s doc says hosts "MUST feature-detect on
    /// this before sending that shape ... read `HelloAck.server_caps`, never
    /// compare wire versions", because this fleet routinely runs a host newer
    /// than the guest binary staged beside it. Before order 823-u5zf the
    /// handshake discarded the list, so that rule could not be followed by
    /// anyone.
    ///
    /// Fails CLOSED: an un-handshaked client reports every capability absent,
    /// so a caller that forgets to handshake takes the conservative path rather
    /// than sending a shape the guest may refuse.
    pub fn supports(&self, cap: &str) -> bool {
        self.server_caps.iter().any(|c| c == cap)
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
        // Kept AHEAD of the sink deliberately. The codec would also refuse an
        // oversize frame, but with its own message ("frame size too big"); this
        // pre-check preserves the exact `control frame too large` string that
        // callers and tests have always seen. Removing it does not change what
        // is accepted — only what the failure is called.
        if bytes.len() > MAX_MESSAGE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "control frame too large",
            ));
        }
        self.framed.send(bytes.into()).await?;
        self.framed.flush().await
    }

    async fn recv(&mut self) -> io::Result<ControlEnvelope> {
        let body = match self.framed.next().await {
            Some(Ok(body)) => body,
            // The codec's own bound rejection, remapped to the string this
            // call site has always returned. `InvalidData` is what the codec
            // raises for an oversize length prefix.
            Some(Err(err)) if err.kind() == io::ErrorKind::InvalidData => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "inbound control frame too large",
                ));
            }
            Some(Err(err)) => return Err(err),
            // `Framed` reports a clean EOF as `None`; the hand-rolled
            // `read_exact` reported it as `UnexpectedEof`. Preserved, because
            // the reconnect loop distinguishes EOF from a transport error.
            None => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "control wire closed",
                ));
            }
        };
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
        for cap in &["VmStatusRequest", "VmShutdownRequest"] {
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

    // ---- order 795-5itp, exit criterion 3 (NEGATIVE CONTROL) -------------
    //
    // The bound survives the move onto `LengthDelimitedCodec`, and — the half
    // that is easy to lose in a codec swap — it still fails with the SAME
    // error surface callers saw when this path framed by hand. The codec's own
    // wording is "frame size too big"; both strings below are the pre-migration
    // ones, preserved deliberately.

    /// Outbound: an envelope over the limit is refused BEFORE anything is
    /// written, with the pre-migration string.
    #[tokio::test]
    async fn oversize_outbound_envelope_is_refused_with_the_original_error() {
        let (host_side, mut guest_side) = tokio::io::duplex(4096);
        let mut client = Client::from_stream(
            Box::new(host_side),
            Transport::Vsock {
                cid: 0,
                port: CONTROL_WIRE_VSOCK_PORT,
            },
        );

        let huge = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::PtyData {
                session_id: 1,
                direction: tillandsias_control_wire::PtyDirection::ToGuest,
                bytes: vec![0xEEu8; MAX_MESSAGE_BYTES + 1],
            },
        };
        let err = client
            .send_envelope(&huge)
            .await
            .expect_err("an envelope over MAX_MESSAGE_BYTES must be refused");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert_eq!(err.to_string(), "control frame too large");

        // And nothing reached the peer: the refusal is local, before the wire.
        drop(client);
        let mut sink = Vec::new();
        guest_side.read_to_end(&mut sink).await.expect("drain peer");
        assert!(
            sink.is_empty(),
            "an oversize frame must not put bytes on the wire, got {} byte(s)",
            sink.len()
        );
    }

    /// Inbound: a hostile length prefix is refused with the pre-migration
    /// string, and the body it declares is never read.
    #[tokio::test]
    async fn oversize_inbound_length_prefix_is_refused_with_the_original_error() {
        let (host_side, mut guest_side) = tokio::io::duplex(4096);
        let mut client = Client::from_stream(
            Box::new(host_side),
            Transport::Vsock {
                cid: 0,
                port: CONTROL_WIRE_VSOCK_PORT,
            },
        );

        // Hand-rolled hostile peer: declares one byte over the maximum, then
        // sends only a few bytes. A reader without a bound would sit here
        // holding a 64 KiB+ allocation waiting for a body that never comes.
        let mut hostile = ((MAX_MESSAGE_BYTES + 1) as u32).to_be_bytes().to_vec();
        hostile.extend_from_slice(b"short");
        guest_side.write_all(&hostile).await.unwrap();

        let err = client
            .next_envelope()
            .await
            .expect_err("a length prefix over MAX_MESSAGE_BYTES must be refused");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert_eq!(err.to_string(), "inbound control frame too large");
    }

    /// A frame exactly AT the limit is still accepted — the bound is inclusive,
    /// and this is the half that catches an off-by-one tightening.
    #[tokio::test]
    async fn inbound_frame_exactly_at_the_limit_is_accepted() {
        let (host_side, mut guest_side) = tokio::io::duplex(MAX_MESSAGE_BYTES * 4);
        let mut client = Client::from_stream(
            Box::new(host_side),
            Transport::Vsock {
                cid: 0,
                port: CONTROL_WIRE_VSOCK_PORT,
            },
        );

        // Grow a PtyData envelope until its ENCODED length is exactly the
        // maximum, so this pins the boundary rather than approaching it.
        let mut payload = vec![0xAAu8; MAX_MESSAGE_BYTES - 64];
        let env = loop {
            let candidate = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 5,
                body: ControlMessage::PtyData {
                    session_id: 1,
                    direction: tillandsias_control_wire::PtyDirection::ToHost,
                    bytes: payload.clone(),
                },
            };
            match encode(&candidate).expect("encode").len() {
                n if n == MAX_MESSAGE_BYTES => break candidate,
                n if n < MAX_MESSAGE_BYTES => payload.push(0xAA),
                _ => panic!("overshot MAX_MESSAGE_BYTES while sizing the fixture"),
            }
        };
        let framed = encode_frame(&env);
        assert_eq!(framed.len(), 4 + MAX_MESSAGE_BYTES);

        tokio::spawn(async move {
            guest_side.write_all(&framed).await.unwrap();
        });

        let got = client
            .next_envelope()
            .await
            .expect("a frame exactly at MAX_MESSAGE_BYTES must be accepted");
        assert_eq!(got.seq, 5);
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
        spawn_hello_responder_with_version(path, WIRE_VERSION).await
    }

    /// The same responder with the HelloAck's advertised wire version under the
    /// caller's control, so the mismatch arm can be driven without a second
    /// harness. ORDER 1032-62rx: a copy would be a second implementation of
    /// "what a server says on handshake", which is how the two come to
    /// disagree; this is the existing fixture with one field parameterised.
    async fn spawn_hello_responder_with_version(
        path: std::path::PathBuf,
        ack_version: u16,
    ) -> tokio::task::JoinHandle<()> {
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
                    wire_version: ack_version,
                    server_caps: vec![
                        "v1".to_string(),
                        tillandsias_control_wire::CAP_EXEC_ARGV_VECTOR.to_string(),
                    ],
                    build_version: None,
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

    /// ORDER 1032-62rx: the CLIENT-SIDE wire-version refusal actually fires.
    ///
    /// vsock_client.rs's mismatch arm existed with NOTHING exercising it. The
    /// six assertions in the tree that mention WIRE_VERSION are all
    /// `assert_eq!(wire_version, WIRE_VERSION)` after a SUCCESSFUL handshake —
    /// tautological, because the value came back from a peer built in the same
    /// build from the same constant. They cannot fail whatever WIRE_VERSION is
    /// set to, so none of them is a version check.
    ///
    /// This drives a server that advertises WIRE_VERSION + 1 and asserts the
    /// handshake REFUSES with InvalidData. Deleting the arm at vsock_client.rs
    /// turns this red — which is the whole point, and is checked rather than
    /// assumed (1032-62rx criterion 3).
    ///
    /// KNOWN ASYMMETRY, deliberately not asserted here: against a CURRENT
    /// server this arm is unreachable, because vsock_server validates the
    /// client's Hello and returns BEFORE sending any HelloAck, and when it does
    /// answer it fills the ack with its own WIRE_VERSION. So the arm serves
    /// only a peer old enough to answer without validating — which is exactly
    /// the peer that cannot be fixed from here, and why the branch must stay.
    ///
    /// @trace order:1032-62rx, spec:vsock-transport
    #[tokio::test]
    async fn handshake_refuses_a_server_advertising_a_different_wire_version() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("control.sock");
        let _server = spawn_hello_responder_with_version(path.clone(), WIRE_VERSION + 1).await;
        tokio::time::sleep(Duration::from_millis(50)).await;

        // `expect_err` needs `T: Debug` and `Client` does not derive it, so match
        // instead. (Windows hid this: the module is `cfg(all(test, unix))`, so a
        // Windows `cargo test` compiled none of it and reported 0 tests run.)
        let err =
            match connect_with_handshake(Transport::Unix(path), DEFAULT_HANDSHAKE_TIMEOUT).await {
                Ok(_) => panic!("a server advertising a different wire version must be REFUSED"),
                Err(e) => e,
            };
        assert_eq!(
            err.kind(),
            io::ErrorKind::InvalidData,
            "the refusal must be InvalidData, not a timeout or a transport error: {err}"
        );
        let msg = err.to_string();
        assert!(
            msg.contains("wire version mismatch"),
            "the error must name the mismatch so an operator can act: {msg}"
        );
        assert!(
            msg.contains(&WIRE_VERSION.to_string())
                && msg.contains(&(WIRE_VERSION + 1).to_string()),
            "and must name BOTH versions, local and peer: {msg}"
        );
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

        // Order 823-u5zf: the guest's advertised capabilities must SURVIVE the
        // handshake. They were destructured away, so CAP_EXEC_ARGV_VECTOR's own
        // rule — "hosts MUST feature-detect on this ... read
        // HelloAck.server_caps, never compare wire versions" — could not be
        // followed by any caller.
        assert!(
            client.supports(tillandsias_control_wire::CAP_EXEC_ARGV_VECTOR),
            "advertised capability must be readable after handshake, got {:?}",
            client.server_caps()
        );
        assert!(client.supports("v1"));
        assert!(
            !client.supports("definitely-not-advertised"),
            "an unadvertised capability must report absent"
        );
    }

    /// Fails CLOSED: a client that has not handshaked reports every capability
    /// absent, so a caller that forgets takes the conservative path rather than
    /// sending a shape the guest may refuse.
    /// @trace spec:vsock-transport
    #[tokio::test]
    async fn capabilities_are_absent_before_handshake() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("control.sock");
        let _server = spawn_hello_responder(path.clone()).await;
        tokio::time::sleep(Duration::from_millis(50)).await;

        let client = Client::connect(Transport::Unix(path))
            .await
            .expect("connect succeeds");
        assert!(client.server_caps().is_empty());
        assert!(!client.supports(tillandsias_control_wire::CAP_EXEC_ARGV_VECTOR));
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
        let (wire, _guest_version) = client.handshake().await.expect("handshake succeeds");
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
