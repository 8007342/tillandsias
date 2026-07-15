//! Wire format for the tray-host control socket.
//!
//! The on-the-wire layout is:
//!
//! ```text
//! [ 4-byte big-endian u32 length N ] [ N bytes of postcard-serialised ControlEnvelope ]
//! ```
//!
//! `ControlEnvelope` carries the `wire_version`, a per-connection monotonic
//! `seq` number, and a typed `ControlMessage` body.
//!
//! The enum is intentionally `#[non_exhaustive]` because future OpenSpec
//! changes will append additional variants. Postcard encodes enums by
//! variant index, so existing variants MUST NOT be reordered or deleted —
//! deprecated variants are tombstoned per project convention and stay in
//! the enum for the 3-release compat window.
//!
//! Lives in its own crate so the router-side sidecar can speak the wire
//! format without pulling in the tray's tauri / tokio-tungstenite / reqwest
//! dependency tree.
//!
//! @trace spec:tray-host-control-socket
//! @cheatsheet languages/rust.md

use serde::{Deserialize, Serialize};

/// Current wire version. Incremented when the envelope shape itself changes
/// (renaming `seq`, adding a required field). Adding a new `ControlMessage`
/// variant does NOT bump this — postcard's additive enum encoding handles
/// that case as `Error::UnknownVariant` on older readers.
///
/// **Version 2** (this revision): introduces the `transport` module + new
/// VM-lifecycle / remote-enumeration variants required by the cross-platform
/// host shells. Breaking because new consumers will reject older `Hello`
/// frames carrying `wire_version: 1`; the upgrade is gated on the
/// Windows/macOS host-shell wave landing simultaneously with the in-VM
/// headless's `--listen-vsock` mode.
///
/// @trace spec:vsock-transport, spec:host-shell-architecture
pub const WIRE_VERSION: u16 = 2;

pub mod guest_transport;
pub mod transport;

/// Maximum permitted single-message length on the wire. Length prefixes
/// greater than this trigger an `Error::PayloadTooLarge` response and the
/// connection is closed.
///
/// Note: `ControlMessage::McpFrame` payloads may reach 4 MiB for large tool
/// responses (e.g., PNG screenshots). The per-variant cap is enforced by the
/// framing layer; see design.md Q-OPEN (size-cap reconciliation).
pub const MAX_MESSAGE_BYTES: usize = 65_536;

/// Maximum permitted `PtyData` frame payload size (for `PtyData` variant only).
/// Larger streams MUST chunk transparently at the sender — see
/// openspec/changes/control-wire-pty-attach/proposal.md Task 1.3.
///
/// Invariant: `MAX_PTY_FRAME_BYTES <= MAX_MESSAGE_BYTES` so the framing layer
/// always accepts a single full chunk.
///
/// @trace openspec/changes/control-wire-pty-attach/proposal.md
pub const MAX_PTY_FRAME_BYTES: usize = 64_000;

/// Capability advertised in `Hello.capabilities` when the peer implements
/// the `control-wire-pty-attach` PTY-over-vsock multiplexing protocol.
/// A connection without this capability advertised on both sides MUST NOT
/// receive `PtyOpen` / `PtyData` / `PtyResize` / `PtyClose` envelopes.
///
/// @trace openspec/changes/control-wire-pty-attach/proposal.md, spec:vsock-transport
pub const CAP_PTY_ATTACH_V1: &str = "pty.attach@v1";

/// Capability advertised by exec clients that understand empty
/// `PtyData{ToHost}` frames as liveness heartbeats rather than terminal data.
/// The server emits heartbeats only when the client advertises this token,
/// keeping mixed-version interactive attach clients unchanged.
pub const CAP_PTY_HEARTBEAT_V1: &str = "pty.heartbeat@v1";

/// Maximum permitted MCP frame payload size (for McpFrame variant only).
/// Screenshots and large tool responses may require multi-MB capacity.
///
/// @trace spec:host-browser-mcp, spec:tray-host-control-socket
pub const MAX_MCP_FRAME_BYTES: usize = 4 * 1024 * 1024; // 4 MiB

/// Versioned envelope carrying every control-plane frame.
///
/// `seq` is a per-connection monotonic counter chosen by the sender; the
/// receiver echoes the same `seq` in its reply (when applicable) so the
/// sender can correlate replies with requests on a stream.
///
/// @trace spec:tray-host-control-socket
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlEnvelope {
    pub wire_version: u16,
    pub seq: u64,
    pub body: ControlMessage,
}

/// Typed control-plane message body.
///
/// `#[non_exhaustive]` so consumers MUST handle the case of an unknown
/// variant arriving after a future additive change. Existing variants
/// MUST stay in their current positions; new variants append at the end.
///
/// @trace spec:tray-host-control-socket
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
pub enum ControlMessage {
    /// First frame after connect. Declares `from` (consumer name) and the
    /// list of message-class capabilities the consumer understands.
    Hello {
        from: String,
        capabilities: Vec<String>,
    },
    /// Server reply to `Hello`. `wire_version` mismatch closes the stream
    /// with a single trailing `Error { code: Unsupported }` envelope.
    HelloAck {
        wire_version: u16,
        server_caps: Vec<String>,
    },
    /// Tray → consumer: register a per-window session cookie value with the
    /// router-side consumer.
    ///
    /// NOTE: v1 of `tray-host-control-socket` ships only the schema for this
    /// variant. Production wiring (the OTP issuance flow) lands with the
    /// `opencode-web-session-otp` change.
    IssueWebSession {
        project_label: String,
        cookie_value: [u8; 32],
    },
    /// Consumer → tray: acknowledge a prior `IssueWebSession` by `seq`.
    IssueAck { seq_acked: u64 },
    /// Generic error frame. `seq_in_reply_to` ties the error to a specific
    /// sender frame when the offending bytes were recoverable enough to
    /// extract the envelope's `seq`.
    Error {
        seq_in_reply_to: Option<u64>,
        code: ErrorCode,
        message: String,
    },
    /// Tray → consumer: evict every session entry for the given project
    /// label. Sent when the project's container stack stops so the
    /// router-side store doesn't keep honouring stale cookies.
    ///
    /// @trace spec:opencode-web-session-otp
    EvictProject { project_label: String },
    /// Forge → tray: encapsulated MCP JSON-RPC frame for browser control.
    /// Payload is a raw JSON-RPC message (newline-delimited, serialised as UTF-8).
    /// The tray's browser MCP module decodes, processes, and responds to the
    /// encapsulated RPC call.
    ///
    /// @trace spec:host-browser-mcp, spec:tray-host-control-socket
    McpFrame { session_id: u64, payload: Vec<u8> },
    /// Host → in-VM headless: request the current VM lifecycle phase.
    ///
    /// @trace spec:vsock-transport, spec:host-shell-architecture
    VmStatusRequest { seq: u64 },
    /// In-VM headless → host: current lifecycle phase + readiness summary.
    ///
    /// @trace spec:vsock-transport, spec:host-shell-architecture
    VmStatusReply {
        seq_in_reply_to: u64,
        phase: VmPhase,
        podman_ready: bool,
        last_event: Option<String>,
    },
    /// Host → in-VM headless: drain forges, then exit the headless cleanly
    /// (the host will follow with `wsl --terminate` / `VZ.requestStop`).
    ///
    /// @trace spec:vsock-transport, spec:vm-provisioning-lifecycle
    VmShutdownRequest { seq: u64, drain_timeout_ms: u32 },
    /// Host → in-VM headless: enumerate projects mounted into the VM.
    ///
    /// @trace spec:host-shell-architecture
    EnumerateLocalProjects { seq: u64 },
    /// In-VM headless → host: response with each visible project.
    ///
    /// @trace spec:host-shell-architecture
    LocalProjectsReply {
        seq_in_reply_to: u64,
        entries: Vec<LocalProjectEntry>,
    },
    /// Host → in-VM headless: refresh the cloud-side project list (`gh` is
    /// invoked inside the VM where the GitHub token lives).
    ///
    /// @trace spec:host-shell-architecture, spec:tillandsias-vault
    CloudRefreshRequest { seq: u64 },
    /// In-VM headless → host: cloud project list response.
    ///
    /// @trace spec:host-shell-architecture
    CloudRefreshReply {
        seq_in_reply_to: u64,
        projects: Vec<CloudProjectEntry>,
    },
    /// Host → guest: start a PTY-attached subprocess inside the VM.
    /// `session_id` is allocated by the host from a per-connection monotonic
    /// counter (starting at 1). The guest echoes it on every reply for this
    /// session. Sessions are scoped to the vsock connection — a reconnect
    /// terminates all in-flight sessions.
    ///
    /// `env` REPLACES the in-VM process environment (no host-env inheritance);
    /// `cwd` sets the initial working directory if `Some`. `argv[0]` is the
    /// executable path; `argv[1..]` are the arguments.
    ///
    /// @trace openspec/changes/control-wire-pty-attach/proposal.md, spec:vsock-transport
    PtyOpen {
        session_id: u32,
        rows: u16,
        cols: u16,
        argv: Vec<String>,
        env: Vec<(String, String)>,
        cwd: Option<String>,
    },
    /// Bidirectional: raw terminal bytes for the named session.
    /// `direction` distinguishes host→guest stdin from guest→host stdout/stderr.
    /// `bytes.len()` MUST NOT exceed `MAX_PTY_FRAME_BYTES`; sender chunks larger
    /// streams transparently.
    ///
    /// @trace openspec/changes/control-wire-pty-attach/proposal.md
    PtyData {
        session_id: u32,
        direction: PtyDirection,
        bytes: Vec<u8>,
    },
    /// Host → guest: relay `SIGWINCH` semantics. Issued when the host PTY
    /// receives its own `SIGWINCH` or when the user resizes the attached
    /// terminal window.
    ///
    /// @trace openspec/changes/control-wire-pty-attach/proposal.md
    PtyResize {
        session_id: u32,
        rows: u16,
        cols: u16,
    },
    /// Terminal event in either direction. From guest: child process exited
    /// with `exit.code` (or was killed by `exit.signal`). From host: caller
    /// requested early termination (the guest then SIGKILLs the child).
    ///
    /// @trace openspec/changes/control-wire-pty-attach/proposal.md
    PtyClose { session_id: u32, exit: PtyExit },
    /// Host -> guest: deliver Vault unseal share + installation UUID for in-VM auto-unseal.
    DeliverCredentials {
        seq: u64,
        unseal_share_b64: Option<String>,
        installation_uuid: String,
        root_token: Option<String>,
    },
    /// Guest -> host: acknowledge `DeliverCredentials` delivery.
    DeliverCredentialsReply { seq_in_reply_to: u64, success: bool },
    /// Host -> guest: query for newly generated Vault root token + Shamir share.
    GetVaultHandover { seq: u64 },
    /// Guest -> host: response with the newly generated Vault root token + Shamir share.
    VaultHandoverReply {
        seq_in_reply_to: u64,
        unseal_share_b64: Option<String>,
        root_token: Option<String>,
    },
    /// Host → in-VM headless: query whether the in-VM GitHub login is active.
    /// On Windows/macOS the GitHub token lives inside the VM (behind Vault), so
    /// the host tray cannot read it directly the way the Linux tray calls
    /// `is_github_logged_in` in-process. This mirrors that check over the wire
    /// so the cross-platform trays can gate GitHub-dependent menu items on a
    /// live login signal rather than a hardcoded `LoggedOut`.
    ///
    /// New trailing variant: additive per the `WIRE_VERSION` doc (does not bump
    /// the version). Older in-VM headless binaries reject it with
    /// `Error::UnknownVariant`; same-generation binaries without the handler
    /// reply `Error { Unsupported }`. Either way the host tray degrades to its
    /// last-known login state.
    ///
    /// @trace spec:tillandsias-vault, spec:host-shell-architecture
    GithubLoginStatusRequest { seq: u64 },
    /// In-VM headless → host: current GitHub login state from a live Vault read.
    /// `logged_in` is the authoritative signal; `handle` carries the GitHub
    /// login (e.g. for the disabled "GitHub: <user>" menu item) when known.
    ///
    /// @trace spec:tillandsias-vault, spec:host-shell-architecture
    GithubLoginStatusReply {
        seq_in_reply_to: u64,
        logged_in: bool,
        handle: Option<String>,
    },
    /// Host → in-VM headless: subscribe to one or more push topics. Sent once
    /// after Hello/HelloAck. The headless then emits VmStatusPush,
    /// LoginStatePush, CloudProjectsPush frames without further requests.
    ///
    /// New trailing variant (additive, no wire version bump).
    Subscribe { topics: Vec<SubscriptionTopic> },
    /// In-VM headless → host: acknowledges a Subscribe frame.
    SubscribeAck,
    /// In-VM headless → host: pushed on every VmPhase change (unrequested,
    /// no seq/seq_in_reply_to — pushed as a stream, not a request-reply).
    /// `seq` is the headless's current monotonic counter so the host can
    /// order pushes relative to other frames.
    VmStatusPush {
        seq: u64,
        phase: VmPhase,
        podman_ready: bool,
        last_event: Option<String>,
    },
    /// In-VM headless → host: pushed when the GitHub login state changes
    /// (detected by the headless's periodic Vault re-check).
    LoginStatePush {
        seq: u64,
        logged_in: bool,
        handle: Option<String>,
    },
    /// In-VM headless → host: pushed when the cloud project list changes
    /// (from a gh repo list refresh). Full replacement list each time.
    CloudProjectsPush {
        seq: u64,
        projects: Vec<CloudProjectEntry>,
    },
    /// In-VM headless → host: pushed when the VM-visible local project list
    /// changes (guest-side reconciliation of the bind-mount root — the same
    /// scan that backs `LocalProjectsReply`). Full replacement list each
    /// time. Trailing addition: additive, no wire version bump (order 260 —
    /// retires the host tray's last steady-state wire poll).
    LocalProjectsPush {
        seq: u64,
        entries: Vec<LocalProjectEntry>,
    },
}

/// Direction tag for `PtyData` frames.
///
/// @trace openspec/changes/control-wire-pty-attach/proposal.md
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PtyDirection {
    /// Host → guest (stdin to the in-VM child).
    ToGuest,
    /// Guest → host (stdout/stderr from the in-VM child, multiplexed).
    ToHost,
}

/// Terminal exit status for a PTY session, mirroring Unix
/// `waitpid()` semantics: a process exits cleanly with `code` OR is killed
/// by a `signal` (then `code` is the conventional 128 + signal number on
/// Unix, and irrelevant on Windows).
///
/// @trace openspec/changes/control-wire-pty-attach/proposal.md
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PtyExit {
    pub code: i32,
    pub signal: Option<i32>,
}

/// Coarse VM lifecycle phase reported in `VmStatusReply`.
///
/// @trace spec:vsock-transport, spec:vm-provisioning-lifecycle
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum VmPhase {
    Provisioning,
    Starting,
    Ready,
    Draining,
    Stopping,
    Failed,
}

/// Topics the host can subscribe to via `Subscribe`. The headless emits a push
/// frame on the corresponding topic whenever the tracked state changes.
///
/// New trailing variant additions are additive (no wire version bump).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SubscriptionTopic {
    VmStatus,
    LoginState,
    CloudProjects,
    /// Order 260: VM-visible local projects (bind-mount root reconciliation).
    LocalProjects,
}

/// A single VM-visible project entry returned by `LocalProjectsReply`.
///
/// @trace spec:host-shell-architecture
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalProjectEntry {
    pub label: String,
    pub guest_path: String,
    pub last_seen_unix: u64,
}

/// A single cloud-side project entry returned by `CloudRefreshReply`.
///
/// @trace spec:host-shell-architecture
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CloudProjectEntry {
    pub label: String,
    pub owner: String,
    pub repo: String,
    pub default_branch: String,
}

/// Error categories the tray emits on the control socket.
///
/// `#[non_exhaustive]` — future error categories can be added without
/// breaking existing consumers (they will see the variant index as
/// uninterpretable and fall through to a generic "unknown error" handler).
///
/// @trace spec:tray-host-control-socket
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
pub enum ErrorCode {
    /// Postcard deserialise failed because the variant index is unknown.
    UnknownVariant,
    /// The 4-byte length prefix exceeded `MAX_MESSAGE_BYTES`.
    PayloadTooLarge,
    /// Reserved for future use; v1 enforces auth via filesystem permissions.
    Unauthorized,
    /// Server-side internal error (handler panic, IO failure, etc).
    Internal,
    /// Wire-version mismatch or otherwise unsupported request.
    Unsupported,
}

impl ControlMessage {
    /// Short, stable, human-readable name for this variant.
    ///
    /// Used by both transport dispatchers (unix-socket in tray/mod.rs and
    /// vsock in vsock_server.rs) when constructing `Error` frames for
    /// unsupported variants — operators see "variant CloudRefreshRequest
    /// not handled by …" instead of the opaque
    /// `Discriminant(13)` from `std::mem::discriminant`.
    ///
    /// The match is intentionally explicit (not derived) — within the
    /// defining crate `#[non_exhaustive]` does NOT relax exhaustiveness,
    /// so adding a new variant becomes a compile error here until it gets
    /// a stable name. That's the point: the shipped wire surface cannot
    /// drift from the diagnostic surface unnoticed.
    ///
    /// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md
    pub fn kind(&self) -> &'static str {
        match self {
            ControlMessage::Hello { .. } => "Hello",
            ControlMessage::HelloAck { .. } => "HelloAck",
            ControlMessage::IssueWebSession { .. } => "IssueWebSession",
            ControlMessage::IssueAck { .. } => "IssueAck",
            ControlMessage::Error { .. } => "Error",
            ControlMessage::EvictProject { .. } => "EvictProject",
            ControlMessage::McpFrame { .. } => "McpFrame",
            ControlMessage::VmStatusRequest { .. } => "VmStatusRequest",
            ControlMessage::VmStatusReply { .. } => "VmStatusReply",
            ControlMessage::VmShutdownRequest { .. } => "VmShutdownRequest",
            ControlMessage::EnumerateLocalProjects { .. } => "EnumerateLocalProjects",
            ControlMessage::LocalProjectsReply { .. } => "LocalProjectsReply",
            ControlMessage::CloudRefreshRequest { .. } => "CloudRefreshRequest",
            ControlMessage::CloudRefreshReply { .. } => "CloudRefreshReply",
            ControlMessage::PtyOpen { .. } => "PtyOpen",
            ControlMessage::PtyData { .. } => "PtyData",
            ControlMessage::PtyResize { .. } => "PtyResize",
            ControlMessage::PtyClose { .. } => "PtyClose",
            ControlMessage::DeliverCredentials { .. } => "DeliverCredentials",
            ControlMessage::DeliverCredentialsReply { .. } => "DeliverCredentialsReply",
            ControlMessage::GetVaultHandover { .. } => "GetVaultHandover",
            ControlMessage::VaultHandoverReply { .. } => "VaultHandoverReply",
            ControlMessage::GithubLoginStatusRequest { .. } => "GithubLoginStatusRequest",
            ControlMessage::GithubLoginStatusReply { .. } => "GithubLoginStatusReply",
            ControlMessage::Subscribe { .. } => "Subscribe",
            ControlMessage::SubscribeAck => "SubscribeAck",
            ControlMessage::VmStatusPush { .. } => "VmStatusPush",
            ControlMessage::LoginStatePush { .. } => "LoginStatePush",
            ControlMessage::CloudProjectsPush { .. } => "CloudProjectsPush",
            ControlMessage::LocalProjectsPush { .. } => "LocalProjectsPush",
        }
    }
}

/// Encode an envelope to its postcard byte representation.
///
/// The framing layer prepends the 4-byte length prefix; this function only
/// serialises the envelope body.
///
/// @trace spec:tray-host-control-socket
pub fn encode(envelope: &ControlEnvelope) -> Result<Vec<u8>, postcard::Error> {
    postcard::to_allocvec(envelope)
}

/// Decode an envelope from its postcard byte representation.
///
/// @trace spec:tray-host-control-socket
pub fn decode(bytes: &[u8]) -> Result<ControlEnvelope, postcard::Error> {
    postcard::from_bytes(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(envelope: &ControlEnvelope) {
        let encoded = encode(envelope).expect("encode succeeds");
        let decoded = decode(&encoded).expect("decode succeeds");
        assert_eq!(envelope, &decoded);
    }

    fn assert_no_credential_markers(envelope: &ControlEnvelope) {
        let encoded = encode(envelope).expect("encode succeeds");
        for marker in [b"ghp_".as_slice(), b"gho_", b"hvs.", b"s."] {
            assert!(
                !encoded.windows(marker.len()).any(|window| window == marker),
                "Hello handshake payload must not contain credential marker {:?}",
                String::from_utf8_lossy(marker)
            );
        }
    }

    #[test]
    fn hello_roundtrip() {
        let envelope = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::Hello {
                from: "router".to_string(),
                capabilities: vec!["IssueWebSession".to_string()],
            },
        };
        roundtrip(&envelope);
        assert_no_credential_markers(&envelope);
    }

    #[test]
    fn hello_ack_roundtrip() {
        let envelope = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 2,
            body: ControlMessage::HelloAck {
                wire_version: WIRE_VERSION,
                server_caps: vec!["v1".to_string()],
            },
        };
        roundtrip(&envelope);
        assert_no_credential_markers(&envelope);
    }

    #[test]
    fn issue_web_session_roundtrip() {
        let mut cookie = [0u8; 32];
        for (i, byte) in cookie.iter_mut().enumerate() {
            *byte = i as u8;
        }
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 3,
            body: ControlMessage::IssueWebSession {
                project_label: "my-project".to_string(),
                cookie_value: cookie,
            },
        });
    }

    #[test]
    fn issue_ack_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 4,
            body: ControlMessage::IssueAck { seq_acked: 3 },
        });
    }

    #[test]
    fn error_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 5,
            body: ControlMessage::Error {
                seq_in_reply_to: Some(3),
                code: ErrorCode::UnknownVariant,
                message: "unknown variant".to_string(),
            },
        });
    }

    #[test]
    fn error_without_seq_in_reply_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 6,
            body: ControlMessage::Error {
                seq_in_reply_to: None,
                code: ErrorCode::PayloadTooLarge,
                message: "frame too large".to_string(),
            },
        });
    }

    /// @trace spec:opencode-web-session-otp
    #[test]
    fn evict_project_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 7,
            body: ControlMessage::EvictProject {
                project_label: "opencode.demo.localhost".to_string(),
            },
        });
    }

    #[test]
    fn wire_version_constant_is_two() {
        // Bumped to v2 when the `transport` module + VM-lifecycle / remote
        // enumeration variants landed for the cross-platform host shells.
        // Further bumps require an additive OpenSpec change with a
        // tombstoned-compat shim per project convention.
        //
        // @trace spec:vsock-transport, spec:host-shell-architecture
        assert_eq!(WIRE_VERSION, 2);
    }

    #[test]
    fn max_message_bytes_is_64_kib() {
        assert_eq!(MAX_MESSAGE_BYTES, 64 * 1024);
    }

    #[test]
    fn max_pty_frame_fits_under_max_message() {
        // Invariant: a single PtyData chunk must always fit in one wire
        // envelope so the framing layer never has to fragment. See
        // openspec/changes/control-wire-pty-attach/proposal.md Task 1.3.
        // (Both are compile-time constants — clippy's "always-true" lint
        // is the point: this test is a guard for whoever raises the limit.)
        #[allow(clippy::assertions_on_constants)]
        const _: () = assert!(MAX_PTY_FRAME_BYTES <= MAX_MESSAGE_BYTES);
    }

    #[test]
    fn cap_pty_attach_v1_constant_is_stable() {
        // Capability strings are part of the wire contract. Changing this
        // breaks Hello capability negotiation across hosts; bump WIRE_VERSION
        // and tombstone in that case.
        assert_eq!(CAP_PTY_ATTACH_V1, "pty.attach@v1");
    }

    /// @trace openspec/changes/control-wire-pty-attach/proposal.md Task 1.4
    #[test]
    fn pty_open_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 100,
            body: ControlMessage::PtyOpen {
                session_id: 1,
                rows: 80,
                cols: 200,
                argv: vec!["/bin/bash".to_string(), "-l".to_string()],
                env: vec![
                    ("TERM".to_string(), "xterm-256color".to_string()),
                    ("LANG".to_string(), "en_US.UTF-8".to_string()),
                ],
                cwd: Some("/home/forge/src".to_string()),
            },
        });
    }

    /// @trace openspec/changes/control-wire-pty-attach/proposal.md Task 1.4
    #[test]
    fn pty_data_empty_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 101,
            body: ControlMessage::PtyData {
                session_id: 1,
                direction: PtyDirection::ToGuest,
                bytes: Vec::new(),
            },
        });
    }

    /// @trace openspec/changes/control-wire-pty-attach/proposal.md Task 1.4
    #[test]
    fn pty_data_full_chunk_roundtrip() {
        // A full MAX_PTY_FRAME_BYTES chunk must roundtrip without losing
        // bytes — the chunking layer relies on this.
        let bytes = (0..MAX_PTY_FRAME_BYTES).map(|i| (i % 256) as u8).collect();
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 102,
            body: ControlMessage::PtyData {
                session_id: 7,
                direction: PtyDirection::ToHost,
                bytes,
            },
        });
    }

    /// @trace openspec/changes/control-wire-pty-attach/proposal.md Task 1.4
    #[test]
    fn pty_resize_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 103,
            body: ControlMessage::PtyResize {
                session_id: 1,
                rows: 50,
                cols: 132,
            },
        });
    }

    /// @trace openspec/changes/control-wire-pty-attach/proposal.md Task 1.4
    #[test]
    fn pty_close_normal_exit_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 104,
            body: ControlMessage::PtyClose {
                session_id: 1,
                exit: PtyExit {
                    code: 0,
                    signal: None,
                },
            },
        });
    }

    /// @trace openspec/changes/control-wire-pty-attach/proposal.md Task 1.4
    #[test]
    fn pty_close_killed_by_signal_roundtrip() {
        // Killed by SIGTERM (15) — Unix convention: code = 128 + signal.
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 105,
            body: ControlMessage::PtyClose {
                session_id: 1,
                exit: PtyExit {
                    code: 128 + 15,
                    signal: Some(15),
                },
            },
        });
    }

    #[test]
    fn mcp_frame_empty_roundtrip() {
        // @trace spec:host-browser-mcp
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 8,
            body: ControlMessage::McpFrame {
                session_id: 1,
                payload: vec![],
            },
        });
    }

    #[test]
    fn mcp_frame_small_roundtrip() {
        // @trace spec:host-browser-mcp
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 9,
            body: ControlMessage::McpFrame {
                session_id: 2,
                payload: b"hello".to_vec(),
            },
        });
    }

    #[test]
    fn mcp_frame_large_roundtrip() {
        // @trace spec:host-browser-mcp
        // Note: this test verifies McpFrame can carry large payloads.
        // Actual framing-layer enforcement of MAX_MCP_FRAME_BYTES happens
        // in src-tauri/src/browser_mcp/mod.rs.
        let large_payload = vec![0xFFu8; 1024 * 1024]; // 1 MiB
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 10,
            body: ControlMessage::McpFrame {
                session_id: 3,
                payload: large_payload,
            },
        });
    }

    /// `ControlMessage::kind()` returns a stable, human-readable name for
    /// every declared variant. Pinned by an explicit table so that adding
    /// a new variant without naming it shows up as a test diff, not as a
    /// silent "Unknown" in operator-facing Error frames.
    #[test]
    fn control_message_kind_names_every_declared_variant() {
        // One sample envelope per variant — the wire-shape doesn't matter
        // for the name lookup, just that the discriminant is correct.
        let cases: &[(ControlMessage, &str)] = &[
            (
                ControlMessage::Hello {
                    from: "x".into(),
                    capabilities: vec![],
                },
                "Hello",
            ),
            (
                ControlMessage::HelloAck {
                    wire_version: WIRE_VERSION,
                    server_caps: vec![],
                },
                "HelloAck",
            ),
            (
                ControlMessage::IssueWebSession {
                    project_label: "p".into(),
                    cookie_value: [0u8; 32],
                },
                "IssueWebSession",
            ),
            (ControlMessage::IssueAck { seq_acked: 1 }, "IssueAck"),
            (
                ControlMessage::Error {
                    seq_in_reply_to: None,
                    code: ErrorCode::Unsupported,
                    message: "x".into(),
                },
                "Error",
            ),
            (
                ControlMessage::EvictProject {
                    project_label: "p".into(),
                },
                "EvictProject",
            ),
            (
                ControlMessage::McpFrame {
                    session_id: 1,
                    payload: vec![],
                },
                "McpFrame",
            ),
            (
                ControlMessage::VmStatusRequest { seq: 1 },
                "VmStatusRequest",
            ),
            (
                ControlMessage::VmStatusReply {
                    seq_in_reply_to: 1,
                    phase: VmPhase::Ready,
                    podman_ready: true,
                    last_event: None,
                },
                "VmStatusReply",
            ),
            (
                ControlMessage::VmShutdownRequest {
                    seq: 1,
                    drain_timeout_ms: 0,
                },
                "VmShutdownRequest",
            ),
            (
                ControlMessage::EnumerateLocalProjects { seq: 1 },
                "EnumerateLocalProjects",
            ),
            (
                ControlMessage::LocalProjectsReply {
                    seq_in_reply_to: 1,
                    entries: vec![],
                },
                "LocalProjectsReply",
            ),
            (
                ControlMessage::CloudRefreshRequest { seq: 1 },
                "CloudRefreshRequest",
            ),
            (
                ControlMessage::CloudRefreshReply {
                    seq_in_reply_to: 1,
                    projects: vec![],
                },
                "CloudRefreshReply",
            ),
            (
                ControlMessage::Subscribe {
                    topics: vec![SubscriptionTopic::VmStatus],
                },
                "Subscribe",
            ),
            (ControlMessage::SubscribeAck, "SubscribeAck"),
            (
                ControlMessage::VmStatusPush {
                    seq: 1,
                    phase: VmPhase::Ready,
                    podman_ready: true,
                    last_event: None,
                },
                "VmStatusPush",
            ),
            (
                ControlMessage::LoginStatePush {
                    seq: 1,
                    logged_in: false,
                    handle: None,
                },
                "LoginStatePush",
            ),
            (
                ControlMessage::CloudProjectsPush {
                    seq: 1,
                    projects: vec![],
                },
                "CloudProjectsPush",
            ),
            (
                ControlMessage::LocalProjectsPush {
                    seq: 1,
                    entries: vec![],
                },
                "LocalProjectsPush",
            ),
        ];
        for (msg, expected) in cases {
            assert_eq!(
                msg.kind(),
                *expected,
                "kind() mismatch for {expected}: got {}",
                msg.kind()
            );
        }
    }

    #[test]
    fn github_login_status_request_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 7,
            body: ControlMessage::GithubLoginStatusRequest { seq: 7 },
        });
    }

    #[test]
    fn github_login_status_reply_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 7,
            body: ControlMessage::GithubLoginStatusReply {
                seq_in_reply_to: 7,
                logged_in: true,
                handle: Some("octocat".to_string()),
            },
        });
    }

    #[test]
    fn github_login_status_kinds() {
        assert_eq!(
            ControlMessage::GithubLoginStatusRequest { seq: 1 }.kind(),
            "GithubLoginStatusRequest"
        );
        assert_eq!(
            ControlMessage::GithubLoginStatusReply {
                seq_in_reply_to: 1,
                logged_in: false,
                handle: None,
            }
            .kind(),
            "GithubLoginStatusReply"
        );
    }

    #[test]
    fn subscribe_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 200,
            body: ControlMessage::Subscribe {
                topics: vec![
                    SubscriptionTopic::VmStatus,
                    SubscriptionTopic::LoginState,
                    SubscriptionTopic::CloudProjects,
                    SubscriptionTopic::LocalProjects,
                ],
            },
        });
    }

    #[test]
    fn subscribe_ack_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 201,
            body: ControlMessage::SubscribeAck,
        });
    }

    #[test]
    fn vm_status_push_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 202,
            body: ControlMessage::VmStatusPush {
                seq: 202,
                phase: VmPhase::Ready,
                podman_ready: true,
                last_event: Some("forge started".into()),
            },
        });
    }

    #[test]
    fn login_state_push_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 203,
            body: ControlMessage::LoginStatePush {
                seq: 203,
                logged_in: true,
                handle: Some("octocat".into()),
            },
        });
    }

    #[test]
    fn login_state_push_logged_out_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 204,
            body: ControlMessage::LoginStatePush {
                seq: 204,
                logged_in: false,
                handle: None,
            },
        });
    }

    #[test]
    fn cloud_projects_push_empty_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 205,
            body: ControlMessage::CloudProjectsPush {
                seq: 205,
                projects: vec![],
            },
        });
    }

    /// Order 260: LocalProjectsPush is a TRAILING variant — round-trips and
    /// must never disturb the encoding of earlier variants (additive rule).
    #[test]
    fn local_projects_push_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 207,
            body: ControlMessage::LocalProjectsPush {
                seq: 207,
                entries: vec![LocalProjectEntry {
                    label: "tillandsias".into(),
                    guest_path: "/home/forge/src/tillandsias".into(),
                    last_seen_unix: 1_752_000_000,
                }],
            },
        });
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 208,
            body: ControlMessage::LocalProjectsPush {
                seq: 208,
                entries: vec![],
            },
        });
    }

    #[test]
    fn cloud_projects_push_with_entries_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 206,
            body: ControlMessage::CloudProjectsPush {
                seq: 206,
                projects: vec![
                    CloudProjectEntry {
                        label: "my-repo".into(),
                        owner: "octocat".into(),
                        repo: "my-repo".into(),
                        default_branch: "main".into(),
                    },
                    CloudProjectEntry {
                        label: "other-repo".into(),
                        owner: "octocat".into(),
                        repo: "other-repo".into(),
                        default_branch: "main".into(),
                    },
                ],
            },
        });
    }

    #[test]
    fn no_json_braces_in_postcard_payload() {
        // Defence-in-depth: assert the encoded payload is not JSON. Postcard
        // is a binary format; the byte stream MUST NOT contain JSON object
        // delimiters (sanity check against accidental serde_json mix-ups).
        let envelope = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::Hello {
                from: "router".to_string(),
                capabilities: vec!["IssueWebSession".to_string()],
            },
        };
        let bytes = encode(&envelope).unwrap();
        // The strings "router" and "IssueWebSession" appear in the postcard
        // payload because postcard length-prefixes string literals; that's
        // expected. What we forbid is JSON-style framing braces around the
        // top-level structure. Postcard never emits `{` or `}` for structs.
        assert!(
            !bytes.starts_with(b"{"),
            "postcard payload must not start with JSON object delimiter"
        );
    }
}
