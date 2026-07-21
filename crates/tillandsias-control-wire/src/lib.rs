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
        #[serde(default)]
        build_version: Option<String>,
    },
    /// Server reply to `Hello`. `wire_version` mismatch closes the stream
    /// with a single trailing `Error { code: Unsupported }` envelope.
    HelloAck {
        wire_version: u16,
        server_caps: Vec<String>,
        #[serde(default)]
        build_version: Option<String>,
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

/// Host-side, platform-agnostic guest **crash-loop DETECTION**.
///
/// The host tier must be able to tell that the guest is *looping* (restarting
/// over and over, never converging) instead of *progressing slowly* — and say
/// so, both to itself (auto-recovery trigger) and to the user (tray state +
/// `--diagnose`). This is the RESILIENCE layer for the class of runtime wedge
/// described in
/// `plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md`
/// (operator directive after a live Windows crash-loop): a repeated
/// restart/unseal/handshake pattern degrades to a falsifiable
/// `crash-loop:<subsystem>` verdict, never to "flashing terminals with no
/// recourse".
///
/// Lives in `tillandsias-control-wire` (not a tray crate) because the verdict
/// grammar is a CROSS-PLATFORM surface: both the Windows NotifyIcon tray and
/// the macOS AppKit tray consume the exact same detector + grammar so the two
/// hosts cannot drift. The detector is a **pure, clock-injected state machine**
/// (mirrors `wsl_lifecycle::KeepaliveSupervisor`'s counting idiom, order 417,
/// but is the general cross-host surface rather than that narrow wsl.exe
/// respawn sub-loop guard) so it is fully unit-pinnable without spawning a VM.
///
/// Distinguishing LOOP from a slow-but-progressing bring-up is the whole point:
/// monotonic `Provisioning → Starting → Ready` progress — even multi-minute,
/// even with repeated same-phase observations — is NEVER counted. Only a phase
/// *regression* (the guest fell back toward `Failed`/`Provisioning` after having
/// advanced), or an explicit subsystem failure signal (vault unseal failure,
/// wire-handshake connect timeout), lands an event. `threshold` such events
/// inside the sliding `window_secs` trip the verdict.
///
/// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
pub mod crashloop {
    use std::collections::VecDeque;
    use std::fmt;
    use std::path::Path;

    use super::VmPhase;

    /// Default sliding-window width. 180s is comfortably longer than a normal
    /// (even slow) first provision's *monotonic* progression, so a healthy but
    /// slow start never accumulates events; a genuine loop produces many
    /// regressions well inside it.
    pub const DEFAULT_WINDOW_SECS: u64 = 180;

    /// Default regression/failure count within `DEFAULT_WINDOW_SECS` that trips
    /// the `crash-loop:<subsystem>` verdict. Three restarts in three minutes is
    /// a loop; a single Quit+relaunch (one regression) is not.
    pub const DEFAULT_THRESHOLD: u32 = 3;

    /// The subsystem a crash-loop is attributed to. The slug is the
    /// `<subsystem>` half of the `crash-loop:<subsystem>` grammar and MUST match
    /// `[a-z0-9-]+`.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum CrashLoopSubsystem {
        /// Repeated guest VM restart/regression (stop→start cycles): the phase
        /// stream fell back toward `Provisioning`/`Failed` over and over.
        Guest,
        /// Repeated Vault unseal failures (the concrete windows-260717-2
        /// trigger): the guest cannot finish bootstrap because the vault will
        /// not unseal, and keeps restarting.
        VaultUnseal,
        /// Repeated control-wire handshake connect timeouts: the host can never
        /// reach the in-VM headless within the connect window.
        Handshake,
    }

    impl CrashLoopSubsystem {
        /// Grammar-safe slug (`[a-z0-9-]+`).
        pub fn slug(self) -> &'static str {
            match self {
                CrashLoopSubsystem::Guest => "guest",
                CrashLoopSubsystem::VaultUnseal => "vault-unseal",
                CrashLoopSubsystem::Handshake => "handshake",
            }
        }

        fn from_slug(s: &str) -> Option<Self> {
            match s {
                "guest" => Some(CrashLoopSubsystem::Guest),
                "vault-unseal" => Some(CrashLoopSubsystem::VaultUnseal),
                "handshake" => Some(CrashLoopSubsystem::Handshake),
                _ => None,
            }
        }
    }

    /// The falsifiable guest-health verdict surfaced by `--diagnose` and the
    /// tray status line. Renders to the PINNED grammar
    /// `^(healthy|starting|crash-loop:[a-z0-9-]+)$`.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum GuestHealth {
        /// Reached `Ready` and is not looping.
        Healthy,
        /// Still bringing up (progressing, or not yet `Ready`) and not looping.
        Starting,
        /// A repeated restart/failure pattern tripped the counter.
        CrashLoop(CrashLoopSubsystem),
    }

    impl GuestHealth {
        /// Render to the pinned grammar string.
        pub fn verdict(self) -> String {
            match self {
                GuestHealth::Healthy => "healthy".to_string(),
                GuestHealth::Starting => "starting".to_string(),
                GuestHealth::CrashLoop(sub) => format!("crash-loop:{}", sub.slug()),
            }
        }

        /// True iff this is a tripped crash-loop verdict (the single
        /// most-important tray notification / auto-recovery trigger).
        pub fn is_crash_loop(self) -> bool {
            matches!(self, GuestHealth::CrashLoop(_))
        }
    }

    impl fmt::Display for GuestHealth {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str(&self.verdict())
        }
    }

    /// Falsifiable validator for the pinned grammar
    /// `^(healthy|starting|crash-loop:[a-z0-9-]+)$` — implemented without the
    /// `regex` crate (control-wire has no such dep) so litmus/unit pins can
    /// assert every rendered verdict conforms.
    pub fn verdict_matches_grammar(s: &str) -> bool {
        if s == "healthy" || s == "starting" {
            return true;
        }
        match s.strip_prefix("crash-loop:") {
            Some(sub) => {
                !sub.is_empty()
                    && sub
                        .bytes()
                        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            }
            None => false,
        }
    }

    /// Progression rank for regression detection. `Failed` is the floor so a
    /// drop *into* Failed always counts. `Draining`/`Stopping` are intentional
    /// lifecycle transitions (a clean stop), NOT progression — they return
    /// `None` and so never advance nor regress the tracked phase; the crash
    /// signal is the guest *re-entering* `Provisioning`/`Starting` (or `Failed`)
    /// from a higher phase.
    fn phase_rank(phase: VmPhase) -> Option<u8> {
        match phase {
            VmPhase::Failed => Some(0),
            VmPhase::Provisioning => Some(1),
            VmPhase::Starting => Some(2),
            VmPhase::Ready => Some(3),
            VmPhase::Draining | VmPhase::Stopping => None,
        }
    }

    /// A `next` phase REGRESSES relative to `prev` when both are ranked and
    /// next's rank is strictly lower. Monotonic forward progress (Provisioning →
    /// Starting → Ready), a repeated same phase, and any transition through the
    /// unranked shutdown phases are all NON-regressions — this is the guard that
    /// keeps a slow-but-healthy start from ever tripping the counter.
    pub fn is_phase_regression(prev: VmPhase, next: VmPhase) -> bool {
        match (phase_rank(prev), phase_rank(next)) {
            (Some(p), Some(n)) => n < p,
            _ => false,
        }
    }

    fn phase_slug(phase: VmPhase) -> &'static str {
        match phase {
            VmPhase::Provisioning => "provisioning",
            VmPhase::Starting => "starting",
            VmPhase::Ready => "ready",
            VmPhase::Draining => "draining",
            VmPhase::Stopping => "stopping",
            VmPhase::Failed => "failed",
        }
    }

    fn phase_from_slug(s: &str) -> Option<VmPhase> {
        match s {
            "provisioning" => Some(VmPhase::Provisioning),
            "starting" => Some(VmPhase::Starting),
            "ready" => Some(VmPhase::Ready),
            "draining" => Some(VmPhase::Draining),
            "stopping" => Some(VmPhase::Stopping),
            "failed" => Some(VmPhase::Failed),
            _ => None,
        }
    }

    /// Classify a headless `last_event` string into the subsystem it names, so a
    /// regression carrying an explanatory event is attributed
    /// (`crash-loop:vault-unseal` / `:handshake`) rather than the generic
    /// `:guest`. Pure + case-insensitive substring match; unknown text →
    /// `None` (the regression is still counted, just as `Guest`).
    pub fn classify_last_event(last_event: &str) -> Option<CrashLoopSubsystem> {
        let lc = last_event.to_ascii_lowercase();
        if lc.contains("unseal") || lc.contains("vault seal") || lc.contains("sealed vault") {
            Some(CrashLoopSubsystem::VaultUnseal)
        } else if lc.contains("handshake")
            || lc.contains("connect timeout")
            || lc.contains("wire timeout")
            || lc.contains("connect timed out")
        {
            Some(CrashLoopSubsystem::Handshake)
        } else {
            None
        }
    }

    #[derive(Clone, Copy, Debug)]
    struct Event {
        at_unix: u64,
        subsystem: CrashLoopSubsystem,
    }

    /// Bounded, time-windowed guest crash-loop detector. Clock-injected: every
    /// method takes `now_unix` (seconds) so the state machine is deterministic
    /// and unit-pinnable. Cheap to serialize to a small state file so the
    /// long-lived tray process can persist it and a separate `--diagnose`
    /// process (notably macOS, whose `--diagnose` is static/filesystem-only —
    /// no live wire handle) can read the verdict.
    #[derive(Clone, Debug)]
    pub struct CrashLoopDetector {
        window_secs: u64,
        threshold: u32,
        events: VecDeque<Event>,
        last_ranked_phase: Option<VmPhase>,
        ever_ready: bool,
    }

    impl Default for CrashLoopDetector {
        fn default() -> Self {
            Self::with_defaults()
        }
    }

    impl CrashLoopDetector {
        /// Construct with explicit thresholds.
        pub fn new(window_secs: u64, threshold: u32) -> Self {
            Self {
                window_secs,
                threshold: threshold.max(1),
                events: VecDeque::new(),
                last_ranked_phase: None,
                ever_ready: false,
            }
        }

        /// Construct with the shipped defaults ([`DEFAULT_WINDOW_SECS`],
        /// [`DEFAULT_THRESHOLD`]).
        pub fn with_defaults() -> Self {
            Self::new(DEFAULT_WINDOW_SECS, DEFAULT_THRESHOLD)
        }

        pub fn window_secs(&self) -> u64 {
            self.window_secs
        }

        pub fn threshold(&self) -> u32 {
            self.threshold
        }

        /// Number of live (un-pruned) events currently in the window. Test/pin
        /// helper.
        pub fn event_count(&self) -> usize {
            self.events.len()
        }

        fn prune(&mut self, now_unix: u64) {
            let floor = now_unix.saturating_sub(self.window_secs);
            while let Some(front) = self.events.front() {
                if front.at_unix < floor {
                    self.events.pop_front();
                } else {
                    break;
                }
            }
        }

        /// Feed a live `VmPhase` observation (from a `VmStatusPush`/poll reply)
        /// plus the accompanying `last_event`. A regression lands one event,
        /// attributed to the subsystem named by `last_event` when recognized.
        /// Returns the post-observation verdict.
        pub fn observe_phase(
            &mut self,
            phase: VmPhase,
            last_event: Option<&str>,
            now_unix: u64,
        ) -> GuestHealth {
            if phase_rank(phase).is_some() {
                if let Some(prev) = self.last_ranked_phase
                    && is_phase_regression(prev, phase)
                {
                    let subsystem = last_event
                        .and_then(classify_last_event)
                        .unwrap_or(CrashLoopSubsystem::Guest);
                    self.events.push_back(Event {
                        at_unix: now_unix,
                        subsystem,
                    });
                }
                self.last_ranked_phase = Some(phase);
                if matches!(phase, VmPhase::Ready) {
                    self.ever_ready = true;
                }
            }
            self.verdict(now_unix)
        }

        /// Record an explicit subsystem failure signal that is NOT expressed as
        /// a phase regression — e.g. a control-wire handshake connect timeout
        /// the host observed directly, or a vault-unseal failure surfaced out of
        /// band. Returns the post-record verdict.
        pub fn record_failure(
            &mut self,
            subsystem: CrashLoopSubsystem,
            now_unix: u64,
        ) -> GuestHealth {
            self.events.push_back(Event {
                at_unix: now_unix,
                subsystem,
            });
            self.verdict(now_unix)
        }

        /// Current verdict (prunes stale events at `now_unix`). Called by
        /// `--diagnose` after `load`.
        pub fn verdict(&mut self, now_unix: u64) -> GuestHealth {
            self.prune(now_unix);
            if self.events.len() as u32 >= self.threshold {
                // Attribute to the MOST-RECENT event's subsystem: that is the
                // subsystem currently looping.
                let subsystem = self
                    .events
                    .back()
                    .map(|e| e.subsystem)
                    .unwrap_or(CrashLoopSubsystem::Guest);
                return GuestHealth::CrashLoop(subsystem);
            }
            if self.ever_ready && matches!(self.last_ranked_phase, Some(VmPhase::Ready)) {
                GuestHealth::Healthy
            } else {
                GuestHealth::Starting
            }
        }

        /// Serialize to the small line-based state format (std-only; no
        /// serde_json dep in this crate). Forward-compatible: readers ignore
        /// unknown lines.
        pub fn to_state_string(&self) -> String {
            let mut out = String::new();
            out.push_str("tillandsias-crashloop-state v1\n");
            out.push_str(&format!("window_secs {}\n", self.window_secs));
            out.push_str(&format!("threshold {}\n", self.threshold));
            out.push_str(&format!(
                "ever_ready {}\n",
                if self.ever_ready { 1 } else { 0 }
            ));
            if let Some(phase) = self.last_ranked_phase {
                out.push_str(&format!("last_phase {}\n", phase_slug(phase)));
            }
            for ev in &self.events {
                out.push_str(&format!("event {} {}\n", ev.at_unix, ev.subsystem.slug()));
            }
            out
        }

        /// Parse the line-based state format. Missing/garbage fields fall back
        /// to defaults; unknown lines are ignored (forward-compat).
        pub fn from_state_string(s: &str) -> Self {
            let mut det = Self::with_defaults();
            det.events.clear();
            det.last_ranked_phase = None;
            det.ever_ready = false;
            for line in s.lines() {
                let mut parts = line.split_whitespace();
                match parts.next() {
                    Some("window_secs") => {
                        if let Some(v) = parts.next().and_then(|v| v.parse::<u64>().ok()) {
                            det.window_secs = v;
                        }
                    }
                    Some("threshold") => {
                        if let Some(v) = parts.next().and_then(|v| v.parse::<u32>().ok()) {
                            det.threshold = v.max(1);
                        }
                    }
                    Some("ever_ready") => {
                        det.ever_ready = parts.next() == Some("1");
                    }
                    Some("last_phase") => {
                        det.last_ranked_phase = parts.next().and_then(phase_from_slug);
                    }
                    Some("event") => {
                        if let (Some(at), Some(sub)) = (
                            parts.next().and_then(|v| v.parse::<u64>().ok()),
                            parts.next().and_then(CrashLoopSubsystem::from_slug),
                        ) {
                            det.events.push_back(Event {
                                at_unix: at,
                                subsystem: sub,
                            });
                        }
                    }
                    _ => {}
                }
            }
            det
        }

        /// Read a detector from `path`. A missing/unreadable/garbage file yields
        /// a fresh default detector — the absence of state is "no loop observed
        /// yet", never a hard failure.
        pub fn load(path: &Path) -> Self {
            match std::fs::read_to_string(path) {
                Ok(s) => Self::from_state_string(&s),
                Err(_) => Self::with_defaults(),
            }
        }

        /// Persist the detector to `path` (creating parent dirs). Best-effort:
        /// the live tray calls this after each observation so a separate
        /// `--diagnose` process can read the current verdict.
        pub fn save(&self, path: &Path) -> std::io::Result<()> {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(path, self.to_state_string())
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use crate::VmPhase;

        /// The three verdict shapes all render to — and only to — the pinned
        /// grammar `^(healthy|starting|crash-loop:[a-z0-9-]+)$`.
        #[test]
        fn verdicts_render_to_pinned_grammar() {
            assert_eq!(GuestHealth::Healthy.verdict(), "healthy");
            assert_eq!(GuestHealth::Starting.verdict(), "starting");
            assert_eq!(
                GuestHealth::CrashLoop(CrashLoopSubsystem::Guest).verdict(),
                "crash-loop:guest"
            );
            assert_eq!(
                GuestHealth::CrashLoop(CrashLoopSubsystem::VaultUnseal).verdict(),
                "crash-loop:vault-unseal"
            );
            assert_eq!(
                GuestHealth::CrashLoop(CrashLoopSubsystem::Handshake).verdict(),
                "crash-loop:handshake"
            );
            for v in [
                GuestHealth::Healthy,
                GuestHealth::Starting,
                GuestHealth::CrashLoop(CrashLoopSubsystem::Guest),
                GuestHealth::CrashLoop(CrashLoopSubsystem::VaultUnseal),
                GuestHealth::CrashLoop(CrashLoopSubsystem::Handshake),
            ] {
                assert!(
                    verdict_matches_grammar(&v.verdict()),
                    "verdict {:?} must match the pinned grammar",
                    v.verdict()
                );
            }
        }

        /// The grammar validator rejects malformed strings (uppercase, spaces,
        /// empty subsystem, unknown top-level word).
        #[test]
        fn grammar_validator_rejects_malformed() {
            assert!(verdict_matches_grammar("healthy"));
            assert!(verdict_matches_grammar("starting"));
            assert!(verdict_matches_grammar("crash-loop:guest"));
            assert!(verdict_matches_grammar("crash-loop:vault-unseal"));
            assert!(!verdict_matches_grammar("Healthy"));
            assert!(!verdict_matches_grammar("crash-loop:"));
            assert!(!verdict_matches_grammar("crash-loop:Guest"));
            assert!(!verdict_matches_grammar("crash-loop:vault unseal"));
            assert!(!verdict_matches_grammar("crashing"));
            assert!(!verdict_matches_grammar(""));
        }

        /// POSITIVE: a driven stop→start series (Ready → Provisioning → …
        /// repeated) flips to `crash-loop:guest` within the window. This is the
        /// litmus's core falsifiable behavior.
        #[test]
        fn driven_restart_series_trips_crash_loop() {
            let mut det = CrashLoopDetector::new(180, 3);
            let mut t = 1_000u64;
            // Reach Ready once (a first healthy provision).
            det.observe_phase(VmPhase::Provisioning, None, t);
            t += 1;
            det.observe_phase(VmPhase::Starting, None, t);
            t += 1;
            let v = det.observe_phase(VmPhase::Ready, None, t);
            assert_eq!(
                v,
                GuestHealth::Healthy,
                "first Ready is healthy, not a loop"
            );

            // Now drive three stop→start regressions inside the window.
            for _ in 0..3 {
                t += 5;
                // A clean stop passes through Stopping (unranked — not a
                // regression by itself) …
                det.observe_phase(VmPhase::Stopping, None, t);
                t += 5;
                // … then the guest re-enters Provisioning from Ready: REGRESSION.
                det.observe_phase(VmPhase::Provisioning, None, t);
                t += 1;
                det.observe_phase(VmPhase::Starting, None, t);
                t += 1;
                det.observe_phase(VmPhase::Ready, None, t);
            }
            let v = det.verdict(t);
            assert_eq!(
                v,
                GuestHealth::CrashLoop(CrashLoopSubsystem::Guest),
                "three Ready→Provisioning regressions in-window must trip crash-loop:guest"
            );
            assert!(verdict_matches_grammar(&v.verdict()));
        }

        /// POSITIVE: a sealed-vault loop (repeated bootstrap ending in `Failed`
        /// with an unseal-failure `last_event`) trips `crash-loop:vault-unseal`.
        #[test]
        fn sealed_vault_loop_trips_vault_unseal_subsystem() {
            let mut det = CrashLoopDetector::new(180, 3);
            let mut t = 500u64;
            for _ in 0..3 {
                det.observe_phase(VmPhase::Provisioning, None, t);
                t += 2;
                det.observe_phase(VmPhase::Starting, None, t);
                t += 2;
                // Bootstrap dies: Starting → Failed regression, carrying the
                // vault-unseal reason on last_event.
                det.observe_phase(VmPhase::Failed, Some("vault unseal failed: sealed"), t);
                t += 3;
            }
            let v = det.verdict(t);
            assert_eq!(
                v,
                GuestHealth::CrashLoop(CrashLoopSubsystem::VaultUnseal),
                "repeated unseal-failure regressions must attribute to vault-unseal"
            );
        }

        /// POSITIVE: explicit handshake connect-timeout signals trip
        /// `crash-loop:handshake`.
        #[test]
        fn repeated_handshake_timeouts_trip_handshake_subsystem() {
            let mut det = CrashLoopDetector::new(120, 3);
            let mut t = 0u64;
            det.record_failure(CrashLoopSubsystem::Handshake, t);
            t += 10;
            det.record_failure(CrashLoopSubsystem::Handshake, t);
            t += 10;
            let v = det.record_failure(CrashLoopSubsystem::Handshake, t);
            assert_eq!(v, GuestHealth::CrashLoop(CrashLoopSubsystem::Handshake));
        }

        /// NEGATIVE (explicit exit criterion): a normal, slow, monotonically
        /// progressing provision — several minutes, repeated same-phase
        /// observations — NEVER trips crash-loop. No false positive on slow
        /// starts.
        #[test]
        fn slow_but_progressing_provision_never_trips() {
            let mut det = CrashLoopDetector::new(180, 3);
            let mut t = 0u64;
            // Five minutes of Provisioning, polled every 10s (repeats, never a
            // regression).
            for _ in 0..30 {
                let v = det.observe_phase(VmPhase::Provisioning, None, t);
                assert_eq!(v, GuestHealth::Starting, "still provisioning => starting");
                t += 10;
            }
            // Then Starting for a while.
            for _ in 0..12 {
                let v = det.observe_phase(VmPhase::Starting, None, t);
                assert_eq!(v, GuestHealth::Starting);
                t += 10;
            }
            // Finally Ready.
            let v = det.observe_phase(VmPhase::Ready, None, t);
            assert_eq!(v, GuestHealth::Healthy);
            assert_eq!(
                det.event_count(),
                0,
                "monotonic progression records no events"
            );
        }

        /// NEGATIVE: a single Quit+relaunch (one regression) does not trip — it
        /// takes `threshold` regressions inside the window.
        #[test]
        fn single_relaunch_does_not_trip() {
            let mut det = CrashLoopDetector::new(180, 3);
            let mut t = 100u64;
            det.observe_phase(VmPhase::Provisioning, None, t);
            t += 1;
            det.observe_phase(VmPhase::Starting, None, t);
            t += 1;
            det.observe_phase(VmPhase::Ready, None, t);
            t += 10;
            // Clean quit, then relaunch: one regression.
            det.observe_phase(VmPhase::Draining, None, t);
            t += 1;
            det.observe_phase(VmPhase::Stopping, None, t);
            t += 30;
            let v = det.observe_phase(VmPhase::Provisioning, None, t);
            assert!(!v.is_crash_loop(), "one relaunch must not be a crash-loop");
            assert_eq!(det.event_count(), 1);
        }

        /// Stale events age out of the window: a loop that stops looping
        /// self-clears back to a non-crash verdict.
        #[test]
        fn events_age_out_of_window() {
            let mut det = CrashLoopDetector::new(60, 3);
            let mut t = 0u64;
            det.record_failure(CrashLoopSubsystem::Guest, t);
            t += 5;
            det.record_failure(CrashLoopSubsystem::Guest, t);
            t += 5;
            assert!(
                det.record_failure(CrashLoopSubsystem::Guest, t)
                    .is_crash_loop()
            );
            // Jump past the window: all three events expire.
            t += 200;
            let v = det.verdict(t);
            assert!(
                !v.is_crash_loop(),
                "events older than the window must expire"
            );
            assert_eq!(det.event_count(), 0);
        }

        /// `is_phase_regression` truth table: only a strict rank DROP between
        /// ranked phases is a regression; shutdown phases and forward/equal
        /// moves are not.
        #[test]
        fn phase_regression_truth_table() {
            assert!(is_phase_regression(VmPhase::Ready, VmPhase::Provisioning));
            assert!(is_phase_regression(VmPhase::Ready, VmPhase::Starting));
            assert!(is_phase_regression(
                VmPhase::Starting,
                VmPhase::Provisioning
            ));
            assert!(is_phase_regression(VmPhase::Ready, VmPhase::Failed));
            assert!(is_phase_regression(VmPhase::Starting, VmPhase::Failed));
            // Forward / equal — never a regression.
            assert!(!is_phase_regression(
                VmPhase::Provisioning,
                VmPhase::Starting
            ));
            assert!(!is_phase_regression(VmPhase::Starting, VmPhase::Ready));
            assert!(!is_phase_regression(
                VmPhase::Provisioning,
                VmPhase::Provisioning
            ));
            assert!(!is_phase_regression(VmPhase::Ready, VmPhase::Ready));
            // Unranked shutdown phases — never a regression in either direction.
            assert!(!is_phase_regression(VmPhase::Ready, VmPhase::Draining));
            assert!(!is_phase_regression(VmPhase::Ready, VmPhase::Stopping));
            assert!(!is_phase_regression(
                VmPhase::Stopping,
                VmPhase::Provisioning
            ));
        }

        /// `classify_last_event` attributes known subsystems and leaves unknown
        /// text unattributed.
        #[test]
        fn last_event_classification() {
            assert_eq!(
                classify_last_event("vault unseal failed: sealed"),
                Some(CrashLoopSubsystem::VaultUnseal)
            );
            assert_eq!(
                classify_last_event("control wire handshake timeout"),
                Some(CrashLoopSubsystem::Handshake)
            );
            assert_eq!(classify_last_event("forge-foo created"), None);
            assert_eq!(classify_last_event(""), None);
        }

        /// Persistence round-trips every field, and a loaded detector yields the
        /// SAME verdict as the live one — the tray writes, `--diagnose` reads.
        #[test]
        fn state_file_round_trip_preserves_verdict() {
            let mut det = CrashLoopDetector::new(180, 3);
            let mut t = 1_000u64;
            for _ in 0..3 {
                det.observe_phase(VmPhase::Ready, None, t);
                t += 2;
                det.observe_phase(VmPhase::Provisioning, Some("vault unseal failed"), t);
                t += 2;
            }
            let live = det.verdict(t);
            assert_eq!(
                live,
                GuestHealth::CrashLoop(CrashLoopSubsystem::VaultUnseal)
            );

            let serialized = det.to_state_string();
            let mut reloaded = CrashLoopDetector::from_state_string(&serialized);
            assert_eq!(reloaded.window_secs(), 180);
            assert_eq!(reloaded.threshold(), 3);
            assert_eq!(
                reloaded.verdict(t),
                live,
                "a reloaded detector must render the same verdict as the live one"
            );
        }

        /// `load` on a missing path is a fresh detector (Starting), never a
        /// panic — absence of state is "nothing observed yet".
        #[test]
        fn load_missing_file_is_fresh_starting() {
            let path = std::path::Path::new("/nonexistent/tillandsias/crashloop.state");
            let mut det = CrashLoopDetector::load(path);
            assert_eq!(det.verdict(0), GuestHealth::Starting);
        }

        /// save→load through a real temp file preserves the tripped verdict.
        #[test]
        fn save_then_load_via_tempfile() {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("sub").join("crashloop.state");
            let mut det = CrashLoopDetector::new(120, 3);
            let mut t = 10u64;
            det.record_failure(CrashLoopSubsystem::Handshake, t);
            t += 1;
            det.record_failure(CrashLoopSubsystem::Handshake, t);
            t += 1;
            det.record_failure(CrashLoopSubsystem::Handshake, t);
            det.save(&path).unwrap();

            let mut loaded = CrashLoopDetector::load(&path);
            assert_eq!(
                loaded.verdict(t),
                GuestHealth::CrashLoop(CrashLoopSubsystem::Handshake)
            );
        }
    }
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
                build_version: None,
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
                build_version: None,
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
                    build_version: None,
                },
                "Hello",
            ),
            (
                ControlMessage::HelloAck {
                    wire_version: WIRE_VERSION,
                    server_caps: vec![],
                    build_version: None,
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
                build_version: None,
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
