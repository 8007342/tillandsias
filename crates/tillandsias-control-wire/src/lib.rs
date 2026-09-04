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
/// **Version 2**: introduced the `transport` module + new VM-lifecycle /
/// remote-enumeration variants required by the cross-platform host shells.
/// Breaking because new consumers reject older `Hello` frames carrying
/// `wire_version: 1`.
///
/// **Version 3** (this revision, order 997-e4v2): REMOVES
/// `EnumerateLocalProjects`, `LocalProjectsReply` and `LocalProjectsPush`.
/// AND NOTHING ELSE — if a diff bumps this constant for a second reason, that
/// reason is a stowaway and belongs in its own version (890-y72v's
/// `DeliverCredentialsReply` discriminator is ruled to version 4).
///
/// REMOVAL IS NOT THE INVERSE OF ADDITION, which is why this bump exists at
/// all. The note above says adding a variant needs no bump — true, because
/// postcard's additive encoding gives an older reader `UnknownVariant` on a
/// TRAILING addition. Removal from the MIDDLE renumbers every later variant:
/// measured before this change, `EnumerateLocalProjects`=10,
/// `LocalProjectsReply`=11, `CloudRefreshRequest`=12. Delete 10 and 11 and
/// `CloudRefreshRequest` INHERITS INDEX 10 — and both carry `{seq: u64}`, an
/// identical payload shape. An old peer would not see a malformed frame; it
/// would decode a structurally valid WRONG VARIANT and answer a cloud refresh
/// with a local-projects reply, with no error at either end. The frames behind
/// the hole are the credential and pty traffic.
///
/// So the bump is the guard: the handshake refuses a mismatched peer at
/// `vsock_server.rs` and `host-shell/src/vsock_client.rs` BEFORE any frame is
/// decoded. A refused connection is loud and recoverable; a misdecoded
/// credentials frame is neither.
///
/// `SubscriptionTopic::LocalProjects` was TRAILING in its own enum and
/// renumbers nothing; it is removed here for tidiness, not for safety.
///
/// @trace spec:vsock-transport, spec:host-shell-architecture
/// @trace order:997-e4v2
pub const WIRE_VERSION: u16 = 3;

pub mod guest_transport;
pub mod transport;

/// Maximum permitted single-message length on the wire, and the ONLY frame
/// size ceiling the control wire has. Build the framing with
/// [`transport::control_frame_codec`], which pins this value.
///
/// A length prefix greater than this closes the connection with a local
/// `io::ErrorKind::InvalidData`; **no reply is sent**.
///
/// CORRECTED 2026-08-18 (order 795-5itp). The previous text claimed an
/// oversize prefix triggers "an `Error::PayloadTooLarge` response", and that
/// a per-variant cap "is enforced by the framing layer". Both were false, and
/// each was checked before being removed:
///
///  * [`ErrorCode::PayloadTooLarge`] is constructed nowhere outside this
///    crate's own tests. No framing site has ever sent it — they return an
///    `io::Error` and drop the connection, so a peer learns only that the
///    wire closed.
///  * No framing site has any per-variant logic whatsoever. Every one applies
///    this single flat bound.
///
/// The referenced "design.md Q-OPEN (size-cap reconciliation)" was likewise
/// stale, not open: it concerned `ControlMessage::McpFrame`, which order 505
/// retired. That variant is refused by the dispatch matrix, is constructed
/// nowhere in the tree, and the enforcement its cap pointed at lived in
/// `src-tauri/`, a directory that no longer exists. [`MAX_MCP_FRAME_BYTES`]
/// survives only as the per-LINE cap on the unrelated NDJSON MCP socket
/// (order 779-dqsv) — it is **not** a second framing ceiling, and nothing on
/// this wire is measured against it.
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

/// Capability advertised by exec clients that understand `PtyHeartbeat`
/// frames, which carry the guest's [`PtyInputState`] alongside liveness
/// (order 723-2yb3). A guest emits `PtyHeartbeat` ONLY to a peer advertising
/// this token; every other peer keeps receiving the v1 empty-`PtyData`
/// heartbeat, which is what lets a mixed-version fleet keep working unchanged.
pub const CAP_PTY_HEARTBEAT_V2: &str = "pty.heartbeat@v2";

/// Maximum permitted MCP payload size — 4 MiB, sized for screenshots and
/// large tool responses.
///
/// Capability a guest advertises when its exec allowlist accepts a VERBATIM
/// argv vector — an absolute, non-shell `argv[0]` with its arguments passed
/// through untouched (order 795-zshi).
///
/// Hosts MUST feature-detect on this before sending that shape: a guest
/// predating it refuses the request, and this fleet routinely runs a host
/// newer than the guest binary staged beside it. The detection path is the
/// one metrics already uses — read `HelloAck.server_caps`, never compare
/// wire versions.
///
/// @trace spec:vsock-exec-authz
pub const CAP_EXEC_ARGV_VECTOR: &str = "ExecArgvVector";

/// Order 795-zshi slice 4: this guest heals a widened ephemeral CA key mode on
/// the path that actually happens — `ensure_proxy_running`'s already-running
/// EARLY RETURN — not only on the cold path that reaches `ensure_ca_bundle`.
///
/// Hosts feature-detect on THIS before dropping the `chmod 600` from their exec
/// preamble. It is a SEPARATE capability from `CAP_EXEC_ARGV_VECTOR` on purpose,
/// and the reason is a dated fact rather than a style preference: the argv arm
/// shipped in `cc4bee155` and the heal in `d4e12b425` — two distinct commits.
/// A guest built from anything in between advertises `ExecArgvVector` and does
/// NOT have the heal, so gating the preamble's `chmod` on the argv capability
/// would silently drop the clamp for exactly that build window and reintroduce
/// 772-shi9 (a 0644 key surviving the VM's whole lifetime) on the guests the
/// clamp exists to protect.
///
/// The general rule this instance illustrates: a capability must name the
/// BEHAVIOUR a caller depends on, never a neighbouring behaviour that happened
/// to land nearby. Reusing a capability as a proxy for "built after roughly
/// then" is version-comparison wearing a capability's clothes, and it fails on
/// exactly the builds a mixed-version fleet actually produces.
///
/// @trace spec:vsock-exec-authz
pub const CAP_PROXY_CA_KEY_HEAL: &str = "ProxyCaKeyHeal";

/// Capability a peer advertises when it understands an explicit end-of-stdin
/// signal on the exec wire (order 924-eof7). RESERVED BY A DESIGN SLICE — the
/// frame itself is deliberately NOT added yet; this constant and its reasoning
/// are the decision record the implementer inherits.
///
/// THE DEFECT. Host->guest stdin is `PtyData { direction: ToGuest }` and
/// nothing else; there is no variant meaning "input is finished".
/// `exec_over_stream_with_input*` writes its chunks and goes straight to
/// draining ToHost, sending no terminator. The child sits on a PTY whose
/// master stays open for the session, so a reader that waits for EOF waits
/// forever: piped `cat > file` hangs while byte-exact `head -c N` succeeds.
/// The symptom PAIR is the discriminator — either alone admits other causes.
///
/// WHY NOT THE CHEAPER OPTION. The obvious alternative is to send VEOF (0x04)
/// as a final ToGuest frame: no wire change, works today. It was rejected on
/// MEASUREMENT, not taste — three trials on a real PTY, macOS 2026-08-29:
///
///   1. BINARY STDIN IS DESTROYED. A 64-byte payload legitimately containing
///      0x04 (at offsets 4, 12, 20, ...) delivered ZERO bytes to the child,
///      which exited at the first embedded 0x04. Any stdin that is not text is
///      silently truncated at its first 0x04 byte.
///   2. IT DOES NOTHING IN RAW MODE. The same payload in raw mode left the
///      child running — 0x04 is just a byte there, so the "EOF" is a no-op and
///      the hang this is meant to fix persists, silently.
///   3. ONE 0x04 IS NOT ENOUGH, AND THE COUNT DEPENDS ON THE PAYLOAD. After
///      unterminated input, the first 0x04 only FLUSHES the pending line; the
///      child exited only on a second. So a correct in-band implementation must
///      know whether its own payload ended in a newline to know whether to send
///      one 0x04 or two — a caller obligation that will be got wrong.
///
/// Hazards 1 and 2 were recorded in the packet as reasoning; hazard 3 was found
/// by running it and is the one that makes the option untenable rather than
/// merely awkward.
///
/// WHY THIS SHAPE, AND THE RULE IT MUST FOLLOW. `ControlMessage` is
/// `#[non_exhaustive]`, which buys forward compatibility for MATCH ARMS and
/// nothing at all on the wire: postcard encodes a variant as a varint INDEX,
/// and a decoder built before the variant exists returns an ERROR rather than
/// skipping the frame — pinned by
/// `unknown_future_variant_is_a_decode_error_not_a_silent_skip`. So an ungated
/// new frame sent to an older guest does not degrade to today's hang; it fails
/// the decode and takes the SESSION down, which is strictly worse than the bug
/// being fixed. The frame must therefore be gated on this capability read from
/// `HelloAck.server_caps`, exactly as `CAP_EXEC_ARGV_VECTOR` requires, and
/// never on a wire-version comparison.
///
/// It is also a capability of its OWN, not a rider on a neighbouring one, per
/// the rule `CAP_PROXY_CA_KEY_HEAL` states: a capability must name the
/// behaviour a caller depends on, because reusing a nearby token as a proxy for
/// "built after roughly then" is version comparison wearing a capability's
/// clothes.
///
/// WHAT THE FALLBACK MUST DO, and this is the half most likely to be skipped:
/// when the peer does NOT advertise this, the caller must not quietly send the
/// input and hope. Today's silence is precisely the failure this milestone
/// exists to remove, so the un-negotiated path should REFUSE a request whose
/// semantics need EOF, and say that the guest is too old to be told when stdin
/// ends — a loud, named refusal instead of a wait that never returns.
///
/// @trace spec:vsock-transport, spec:vsock-exec-authz
pub const CAP_PTY_STDIN_EOF: &str = "pty.stdin.eof@v1";

/// Capability a peer advertises when it can open a DATA session — one whose
/// stdin is a PIPE rather than the PTY slave (order 926-bin4). RESERVED BY A
/// DESIGN SLICE: the frame is deliberately not added yet, and this constant
/// carries the decision the implementer inherits.
///
/// THE DEFECT. Exec stdin travels as `PtyData{ToGuest}` and is written to a PTY
/// master whose line discipline INTERPRETS it. Measured on a live guest,
/// `AB<byte>CD` per byte with md5 compared end to end: 0x13 WEDGES the session
/// (unrecoverable, one data byte); 0x03 KILLS the child (rc 130); 0x04 and 0x11
/// silently eat a byte; 0x15 and 0x1a silently discard EVERYTHING buffered
/// before them; 0x7f additionally destroys the preceding byte. Six of nine
/// bytes, five of them at rc=0 with the caller told it succeeded. 0x08 and a
/// plain 0x41 arrive intact — the latter is the negative control that makes the
/// rest of the table trustworthy.
///
/// WHY NOT JUST USE RAW MODE. Because canonical mode is simultaneously the
/// corruption mechanism AND the only stdin-EOF mechanism a PTY has: a reader
/// sees EOF when the master closes (which ends the session) or when the
/// discipline interprets VEOF, which requires ICANON (924-eof7, 925-eofi).
/// Switching the exec PTY to raw fixes all six bytes and reinstates the hang
/// 925-eofi fixed. The two packets are two horns of one structural choice.
///
/// WHY NOT TOGGLE RAW AROUND WRITES. It is correct for data and silently wrong
/// for terminals: on an interactive attach, 0x03 MUST raise SIGINT, because it
/// is a user pressing Ctrl-C rather than a byte to preserve. Both kinds share
/// the same guest path today.
///
/// THE SHAPE: A PIPE FOR STDIN ONLY. Wire the child's fd 0 to a pipe and leave
/// fd 1/2 on the PTY slave. A pipe has no line discipline, so all six bytes
/// arrive by construction; closing the write end is a REAL end-of-input, which
/// makes `PtyStdinEof` on this path a pipe close rather than a VEOF injection
/// and drops the canonical-mode dependency entirely. Output streaming, combined
/// stdout/stderr ordering and `isatty(1)` are unchanged because fd 1/2 still
/// point at the slave, and the interactive attach path is untouched.
///
/// WHY A NEW VARIANT AND NOT A FIELD ON `PtyOpen` — the part that is easy to
/// get backwards, so it is measured
/// (`postcard_field_skew_is_asymmetric_and_the_old_reader_fails_silently`).
/// postcard field skew is ASYMMETRIC: an OLD decoder handed a frame with an
/// extra trailing field DECODES IT FINE and ignores the surplus, while a NEW
/// decoder handed an old frame errors on the missing field. So widening
/// `PtyOpen` would not break an older guest loudly — it would make that guest
/// silently ignore the session kind and treat a data session as a terminal one,
/// which is exactly this packet's corruption, arriving with no error anywhere.
/// A new variant is rejected by NAME instead
/// (`unknown_future_variant_is_a_decode_error_not_a_silent_skip`), which is why
/// the additive move here must be a variant gated on this capability.
///
/// FALLBACK, and it must stay loud: a peer without this capability keeps
/// today's PTY-stdin behaviour, so a caller sending non-text stdin to it should
/// be told the payload may be altered rather than discovering it downstream.
///
/// @trace spec:vsock-transport, spec:vsock-exec-authz
pub const CAP_PTY_DATA_SESSION: &str = "pty.data-session@v1";

/// Order 779-dqsv: this number OUTLIVED the transport it was written for.
/// It was the per-variant cap on `McpFrame`, which order 505 retired (that
/// path is now refused; see `host-browser-mcp` spec). The live MCP transport
/// is the per-lane NDJSON socket, and it enforces this same number as a
/// per-LINE cap — `tray::MAX_MCP_LINE_BYTES` re-exports it rather than
/// inventing a second limit, so there is exactly one MCP payload ceiling in
/// the tree. The constant stays here because control-wire is where wire
/// limits live and the refused variant still exists.
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
        /// 731-eupn: whether `projects` is an ANSWER or the residue of a
        /// failed fetch. `#[serde(default)]` yields
        /// [`CloudRefreshOutcome::Unknown`] for a guest that predates this
        /// field, so an old guest's empty list is never mistaken for a
        /// confirmed zero. See [`CloudRefreshOutcome`] for why the default
        /// fails closed.
        #[serde(default)]
        outcome: CloudRefreshOutcome,
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
    /// Guest → host: a liveness heartbeat that also SAYS SOMETHING (order
    /// 723-2yb3). Trailing addition, appended per this enum's own rule.
    ///
    /// The v1 heartbeat is an empty `PtyData{ToHost}` frame, which proves the
    /// wire is alive and nothing else — it is why a 70-minute wedge was
    /// externally indistinguishable from healthy progress. This carries the
    /// guest's answer to the one question the host cannot answer for itself:
    /// is the child blocked reading its terminal?
    ///
    /// Emitted ONLY to a peer that advertised [`CAP_PTY_HEARTBEAT_V2`]. A v1
    /// host would decode this as `Error::UnknownVariant`, so negotiation is
    /// not decoration — it is what keeps a mixed-version fleet working.
    PtyHeartbeat {
        session_id: u32,
        input_state: PtyInputState,
    },
    /// Host → in-VM headless: request a guest metrics snapshot (per-container
    /// cgroup v2 CPU/mem/blkio + per-mount cumulative I/O) over the control
    /// wire — the idiomatic VM-boundary crossing for the macOS/Windows trays
    /// and `--diagnose --json`, which cannot reach the guest's TCP `/metrics`
    /// endpoint (order 333, guest-container-metrics-over-control-wire).
    ///
    /// New trailing variant: additive per the `WIRE_VERSION` doc (does not
    /// bump the version). Older in-VM headless binaries reject it with
    /// `Error::UnknownVariant`; same-generation binaries without the handler
    /// reply `Error { Unsupported }`.
    ///
    /// @trace spec:observability-metrics, spec:vsock-transport
    MetricsSnapshotRequest { seq: u64 },
    /// In-VM headless → host: the requested metrics snapshot. A collection
    /// failure travels as a populated `error` field on the affected entry
    /// with its values `None` — never a fabricated healthy sample
    /// (spec:observability-metrics).
    ///
    /// @trace spec:observability-metrics, spec:vsock-transport
    MetricsSnapshotReply {
        seq_in_reply_to: u64,
        snapshot: MetricsSnapshotWire,
    },
    /// Host → guest: the host has no more stdin for this session's child
    /// (order 925-eofi, implementing the 924-eof7 decision).
    ///
    /// IT CARRIES INTENT, NOT A BYTE, AND THAT IS THE WHOLE POINT. The child
    /// runs on a PTY with the slave as its controlling tty and the master open
    /// for the session, so there is no stdin handle to close — "EOF" on a PTY
    /// means the line discipline seeing VEOF. 924-eof7 measured why the HOST
    /// must not send that byte itself: in raw mode 0x04 is ordinary data and
    /// the signal silently does nothing, and after unterminated input a single
    /// 0x04 only FLUSHES (a second is needed). Both facts depend on termios
    /// state and on what was last written — which the GUEST knows and the host
    /// does not. So the host declares that input is finished and the guest,
    /// which can be correct about it, decides what to write.
    ///
    /// New trailing variant: additive per the `WIRE_VERSION` doc. A guest
    /// predating it rejects the frame with `Error::UnknownVariant`, which on
    /// this wire ENDS THE SESSION — so a host MUST NOT send this without
    /// having seen `CAP_PTY_STDIN_EOF` in `HelloAck.server_caps`. See that
    /// constant for the full reasoning and the mandatory fallback.
    ///
    /// @trace spec:vsock-transport
    PtyStdinEof { session_id: u32 },
    /// Host → guest: open a DATA session (order 926-bin4). Same shape as
    /// [`ControlMessage::PtyOpen`], and deliberately a SEPARATE VARIANT rather
    /// than a flag on it — see `CAP_PTY_DATA_SESSION` for the measurement that
    /// forced that choice (an older peer silently ignores a widened variant's
    /// extra field and would treat a data session as a terminal one, which is
    /// the corruption this exists to prevent, arriving with no error).
    ///
    /// The guest wires the child's fd 0 to a PIPE instead of the PTY slave,
    /// leaving fd 1/2 on the slave. Stdin therefore crosses NO line discipline:
    /// the six control bytes measured corrupting, killing or wedging an exec
    /// session (0x03, 0x04, 0x11, 0x13, 0x15, 0x1a, 0x7f) arrive as data. End
    /// of input is a real pipe close rather than a VEOF injection.
    ///
    /// Use it for stdin that is DATA. A terminal session must keep using
    /// `PtyOpen`, because there 0x03 SHOULD raise SIGINT — it is a user
    /// pressing Ctrl-C, not a byte to preserve.
    ///
    /// @trace spec:vsock-transport
    PtyOpenData {
        session_id: u32,
        rows: u16,
        cols: u16,
        argv: Vec<String>,
        env: Vec<(String, String)>,
        cwd: Option<String>,
    },
}

/// What the guest established about a PTY session's foreground process.
///
/// Three-valued on the wire for the same reason it is three-valued in the
/// probe: `/proc/<pid>/syscall` is not readable on every kernel, and a host
/// that cannot distinguish "not blocked" from "could not tell" would act
/// confidently on an absent measurement. `Unknown` obliges the host to behave
/// exactly as it did before v2.
///
/// @trace spec:vsock-transport
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PtyInputState {
    /// Blocked reading the terminal. It will not proceed until someone writes.
    BlockedOnInput,
    /// Running, or blocked on something that is not the terminal.
    NotBlocked,
    /// The guest could not establish the answer on this kernel.
    Unknown,
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
}

/// A single VM-visible project entry.
///
/// ORDER 997-e4v2: the wire variants that carried this
/// (`EnumerateLocalProjects`, `LocalProjectsReply`, `LocalProjectsPush`) are
/// GONE. The type is deliberately RETAINED because
/// `tillandsias-headless/src/local_projects.rs` still returns it — order 505's
/// project-label validation is fed by `scan_project_root`, and 1031-q4pb owns
/// giving that control a source outside this crate. It is a plain struct with
/// no discriminant, so keeping it changes no byte of the encoding. It dies with
/// that validation, not with the wire.
///
/// @trace spec:host-shell-architecture
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalProjectEntry {
    pub label: String,
    pub guest_path: String,
    pub last_seen_unix: u64,
}

/// Whether a `CloudRefreshReply`'s project list is an ANSWER or an ARTIFACT
/// of a failed fetch (731-eupn).
///
/// Before this existed, `cloud_projects.rs` returned an empty `Vec` for a
/// non-zero `gh` exit, a missing `gh` binary, missing auth, AND for an account
/// that genuinely has no repos — four outcomes, one representation. The tray
/// then latched "confirmed empty" and rendered `(no repos)` with the tooltip
/// "no GitHub repos visible to the in-VM gh client": a confirmation nobody
/// made, from a message that only ever meant "here is a list".
///
/// `Unknown` IS THE DEFAULT ON PURPOSE, and it is the mixed-version half of
/// this fix. A guest predating this field serializes no `outcome`, so serde
/// fills `Unknown` and the host treats the list as unconfirmed rather than
/// authoritative. Defaulting to `Ok` would make an old guest's every reply —
/// including its failures — read as a confirmed answer, which is the exact bug
/// this type exists to end. Fail closed: an absent discriminator is not a
/// success discriminator.
///
/// @trace spec:host-shell-architecture, order:731-eupn
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum CloudRefreshOutcome {
    /// The guest ran the query and this list is what it found. An empty list
    /// under `Ok` means the account genuinely has no visible repos.
    Ok,
    /// The guest could not complete the query. `projects` carries no
    /// information — it is empty because there is nothing to say, not because
    /// the answer is zero. `reason` is a short operator-facing phrase.
    Failed { reason: String },
    /// No discriminator was carried: a guest older than 731-eupn. Treat
    /// exactly as `Failed` for display purposes — the list is not an answer —
    /// but distinguishable in logs so a version skew is not misread as a
    /// broken `gh`.
    #[default]
    Unknown,
}

impl CloudRefreshOutcome {
    /// True only when the list may be presented as an authoritative answer.
    /// The one predicate every consumer should branch on, so `Unknown` cannot
    /// be forgotten at a call site the way a bare `matches!(.., Failed { .. })`
    /// invites.
    pub fn is_confirmed(&self) -> bool {
        matches!(self, CloudRefreshOutcome::Ok)
    }
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

/// Guest metrics snapshot carried by `MetricsSnapshotReply`.
///
/// Standalone wire types (no dependency on `tillandsias-metrics` — this
/// crate stays dependency-light for sidecar consumers); the guest-side
/// conversion from the sampler's types lands with the vsock handler.
/// `sampled_at_unix` is seconds since the Unix epoch, guest clock.
///
/// @trace spec:observability-metrics
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MetricsSnapshotWire {
    pub sampled_at_unix: u64,
    pub containers: Vec<ContainerMetricWire>,
    pub mounts: Vec<MountIoMetricWire>,
}

/// Per-container cgroup v2 sample on the wire. Counters are cumulative:
/// `cpu_usec` microseconds of CPU time, `memory_current_bytes` current
/// bytes, `blkio_*` bytes/ops summed across devices. `None` means "could
/// not be collected" — `error` says why. A failure never travels as a
/// fabricated healthy zero (spec:observability-metrics).
///
/// @trace spec:observability-metrics
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContainerMetricWire {
    pub name: String,
    pub cpu_usec: Option<u64>,
    pub memory_current_bytes: Option<u64>,
    pub blkio_read_bytes: Option<u64>,
    pub blkio_write_bytes: Option<u64>,
    pub blkio_read_ops: Option<u64>,
    pub blkio_write_ops: Option<u64>,
    pub error: Option<String>,
}

/// Per-mount cumulative I/O counters on the wire, attributed to the mount's
/// backing block device. Paths without a diskstats-visible backing device
/// (tmpfs, virtiofs, overlay) carry `error: "unavailable: <fstype>"` with
/// all counters `None`.
///
/// @trace spec:observability-metrics
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MountIoMetricWire {
    pub path: String,
    pub device: Option<String>,
    pub read_bytes: Option<u64>,
    pub write_bytes: Option<u64>,
    pub read_ops: Option<u64>,
    pub write_ops: Option<u64>,
    pub error: Option<String>,
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
            ControlMessage::CloudRefreshRequest { .. } => "CloudRefreshRequest",
            ControlMessage::CloudRefreshReply { .. } => "CloudRefreshReply",
            ControlMessage::PtyOpen { .. } => "PtyOpen",
            ControlMessage::PtyData { .. } => "PtyData",
            ControlMessage::PtyResize { .. } => "PtyResize",
            ControlMessage::PtyClose { .. } => "PtyClose",
            ControlMessage::PtyHeartbeat { .. } => "PtyHeartbeat",
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
            ControlMessage::MetricsSnapshotRequest { .. } => "MetricsSnapshotRequest",
            ControlMessage::MetricsSnapshotReply { .. } => "MetricsSnapshotReply",
            ControlMessage::PtyStdinEof { .. } => "PtyStdinEof",
            ControlMessage::PtyOpenData { .. } => "PtyOpenData",
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

    /// Default cap on consecutive automatic guest resets before the policy
    /// defers to the MANUAL reset affordance. Two automatic attempts cover
    /// the "one reset fixes it" happy path plus a single retry; anything
    /// still looping after that needs a human (never an unbounded loop —
    /// that is the very failure this work fixes).
    pub const AUTO_RESET_MAX_ATTEMPTS: u32 = 2;

    /// Default base backoff between automatic reset attempts (doubles per
    /// attempt). 300s comfortably exceeds a full wipe+reprovision cycle, so
    /// two auto-resets can never overlap and a persistently-looping guest is
    /// re-poked ever more gently.
    pub const AUTO_RESET_BASE_BACKOFF_SECS: u64 = 300;

    /// What the auto-reset policy tells the host tier to do for one observed
    /// verdict.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum AutoResetDecision {
        /// Trigger an automatic wipe+reprovision now (`attempt` is 1-based).
        Reset { attempt: u32 },
        /// A crash-loop is tripped but the backoff window since the last
        /// attempt has not elapsed — do nothing yet.
        Wait,
        /// The attempt cap is exhausted: defer to the manual reset
        /// affordance (the `--reset-guest` CLI verb). Stays terminal
        /// until the guest reaches `Healthy` again.
        Defer,
        /// No crash-loop is tripped — nothing to do.
        NotTripped,
    }

    /// Bounded, backed-off AUTO-RESET policy for the intentional ephemeral
    /// reset (windows-260717-4). Pure + clock-injected like
    /// [`CrashLoopDetector`], and deliberately housed here in control-wire so
    /// the Windows NotifyIcon tray and the macOS AppKit tray consume the
    /// exact same cap/backoff semantics (cross-platform by construction —
    /// the packet's design note asked for exactly this placement).
    ///
    /// Semantics:
    /// - Only a tripped `crash-loop:<subsystem>` verdict may trigger a reset.
    /// - The first attempt fires immediately on a trip; attempt `n+1` only
    ///   after `base_backoff_secs * 2^(n-1)` seconds since attempt `n`.
    /// - After `max_attempts`, every further tripped observation yields
    ///   [`AutoResetDecision::Defer`] — the manual affordance is the only
    ///   path forward (no unbounded loop).
    /// - A `Healthy` observation (the guest reached Ready and is not
    ///   looping) clears the attempt budget so a NEW loop next month gets a
    ///   fresh budget. `Starting` does NOT clear — the guest is always
    ///   `starting` right after a reset, and treating that as recovery would
    ///   un-bound the loop.
    ///
    /// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
    #[derive(Clone, Debug)]
    pub struct AutoResetPolicy {
        max_attempts: u32,
        base_backoff_secs: u64,
        attempts: u32,
        last_attempt_unix: Option<u64>,
    }

    impl Default for AutoResetPolicy {
        fn default() -> Self {
            Self::with_defaults()
        }
    }

    impl AutoResetPolicy {
        pub fn new(max_attempts: u32, base_backoff_secs: u64) -> Self {
            Self {
                max_attempts: max_attempts.max(1),
                base_backoff_secs,
                attempts: 0,
                last_attempt_unix: None,
            }
        }

        pub fn with_defaults() -> Self {
            Self::new(AUTO_RESET_MAX_ATTEMPTS, AUTO_RESET_BASE_BACKOFF_SECS)
        }

        /// Attempts consumed so far (test/pin helper).
        pub fn attempts(&self) -> u32 {
            self.attempts
        }

        /// Backoff required after `attempts` consumed attempts (doubles per
        /// attempt, from `base_backoff_secs`).
        fn backoff_secs(&self) -> u64 {
            let exp = self.attempts.saturating_sub(1).min(16);
            self.base_backoff_secs.saturating_mul(1u64 << exp)
        }

        /// Consult the policy with the latest observed verdict. Mutates the
        /// attempt budget only when a reset is actually granted (or on a
        /// `Healthy` recovery, which clears it).
        pub fn consult(&mut self, verdict: GuestHealth, now_unix: u64) -> AutoResetDecision {
            match verdict {
                GuestHealth::Healthy => {
                    self.attempts = 0;
                    self.last_attempt_unix = None;
                    AutoResetDecision::NotTripped
                }
                GuestHealth::Starting => AutoResetDecision::NotTripped,
                GuestHealth::CrashLoop(_) => {
                    if self.attempts >= self.max_attempts {
                        return AutoResetDecision::Defer;
                    }
                    if let Some(last) = self.last_attempt_unix
                        && now_unix < last.saturating_add(self.backoff_secs())
                    {
                        return AutoResetDecision::Wait;
                    }
                    self.attempts += 1;
                    self.last_attempt_unix = Some(now_unix);
                    AutoResetDecision::Reset {
                        attempt: self.attempts,
                    }
                }
            }
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

        /// AUTO-RESET (windows-260717-4 exit criterion 3): the policy is
        /// BOUNDED — after `max_attempts` it defers to the manual affordance
        /// forever (until a genuine recovery), never an unbounded loop.
        #[test]
        fn auto_reset_is_bounded_and_defers_after_cap() {
            let mut policy = AutoResetPolicy::new(2, 300);
            let loop_verdict = GuestHealth::CrashLoop(CrashLoopSubsystem::Guest);
            let mut t = 1_000u64;

            assert_eq!(
                policy.consult(loop_verdict, t),
                AutoResetDecision::Reset { attempt: 1 },
                "first trip resets immediately"
            );
            // Attempt 2 only after the base backoff elapses.
            t += 10;
            assert_eq!(policy.consult(loop_verdict, t), AutoResetDecision::Wait);
            t += 300;
            assert_eq!(
                policy.consult(loop_verdict, t),
                AutoResetDecision::Reset { attempt: 2 }
            );
            // Cap reached: every further tripped observation defers to the
            // manual affordance — even far in the future.
            for dt in [1u64, 600, 86_400, 8_640_000] {
                t += dt;
                assert_eq!(
                    policy.consult(loop_verdict, t),
                    AutoResetDecision::Defer,
                    "after the cap the policy must defer to the manual reset"
                );
            }
        }

        /// AUTO-RESET: the inter-attempt backoff doubles (300s → 600s with the
        /// default base), so a persistently-looping guest is re-poked ever more
        /// gently.
        #[test]
        fn auto_reset_backoff_doubles_between_attempts() {
            let mut policy = AutoResetPolicy::new(3, 100);
            let loop_verdict = GuestHealth::CrashLoop(CrashLoopSubsystem::VaultUnseal);
            let mut t = 0u64;
            assert_eq!(
                policy.consult(loop_verdict, t),
                AutoResetDecision::Reset { attempt: 1 }
            );
            // After attempt 1: 100s backoff.
            t += 99;
            assert_eq!(policy.consult(loop_verdict, t), AutoResetDecision::Wait);
            t += 1;
            assert_eq!(
                policy.consult(loop_verdict, t),
                AutoResetDecision::Reset { attempt: 2 }
            );
            // After attempt 2: 200s backoff (doubled).
            t += 199;
            assert_eq!(policy.consult(loop_verdict, t), AutoResetDecision::Wait);
            t += 1;
            assert_eq!(
                policy.consult(loop_verdict, t),
                AutoResetDecision::Reset { attempt: 3 }
            );
        }

        /// AUTO-RESET: a `Healthy` recovery clears the attempt budget (a NEW
        /// loop later gets fresh attempts), but `Starting` does NOT — the
        /// guest is always `starting` right after a reset, and treating that
        /// as recovery would un-bound the loop.
        #[test]
        fn auto_reset_budget_clears_on_healthy_not_on_starting() {
            let mut policy = AutoResetPolicy::new(1, 100);
            let loop_verdict = GuestHealth::CrashLoop(CrashLoopSubsystem::Guest);
            let mut t = 0u64;
            assert_eq!(
                policy.consult(loop_verdict, t),
                AutoResetDecision::Reset { attempt: 1 }
            );
            // Post-reset bring-up: Starting must NOT restore the budget.
            t += 50;
            assert_eq!(
                policy.consult(GuestHealth::Starting, t),
                AutoResetDecision::NotTripped
            );
            t += 50;
            assert_eq!(
                policy.consult(loop_verdict, t),
                AutoResetDecision::Defer,
                "cap of 1 exhausted; Starting must not have cleared it"
            );
            // A genuine Healthy recovery clears the budget.
            t += 100;
            assert_eq!(
                policy.consult(GuestHealth::Healthy, t),
                AutoResetDecision::NotTripped
            );
            assert_eq!(policy.attempts(), 0);
            t += 100;
            assert_eq!(
                policy.consult(loop_verdict, t),
                AutoResetDecision::Reset { attempt: 1 },
                "a fresh loop after recovery gets a fresh budget"
            );
        }

        /// AUTO-RESET: non-tripped verdicts never grant a reset.
        #[test]
        fn auto_reset_never_fires_without_a_tripped_verdict() {
            let mut policy = AutoResetPolicy::with_defaults();
            for verdict in [GuestHealth::Healthy, GuestHealth::Starting] {
                assert_eq!(
                    policy.consult(verdict, 1_000),
                    AutoResetDecision::NotTripped
                );
            }
            assert_eq!(policy.attempts(), 0);
        }
    }
}

#[cfg(test)]
mod tests {

    /// ORDER 926-bin4 — HOW POSTCARD ACTUALLY BEHAVES UNDER FIELD SKEW, in
    /// both directions, measured rather than assumed. I expected widening a
    /// variant to break older decoders and wrote this to confirm it. It does
    /// NOT, and the real behaviour is ASYMMETRIC, which is what the session-kind
    /// design has to be built on:
    ///
    ///   OLD reader / NEW frame (extra trailing field) -> DECODES FINE. The
    ///     surplus bytes are simply not consumed. An older guest would silently
    ///     ignore a session kind it does not understand — and silently treat a
    ///     data session as a terminal one, which is the corruption this packet
    ///     is about, arriving without a single error.
    ///   NEW reader / OLD frame (missing field) -> DECODE ERROR. It runs out of
    ///     input for a field it requires.
    ///
    /// So widening `PtyOpen` is not a compile-time break but something worse: a
    /// SILENT MISINTERPRETATION on exactly the peers a mixed-version fleet
    /// produces. A new VARIANT is the safe additive move, because an older peer
    /// rejects an unknown variant index by NAME (see
    /// `unknown_future_variant_is_a_decode_error_not_a_silent_skip`) instead of
    /// quietly mis-reading a frame it thinks it understands.
    #[test]
    fn postcard_field_skew_is_asymmetric_and_the_old_reader_fails_silently() {
        let env = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 7,
            body: ControlMessage::PtyResize {
                session_id: 1,
                rows: 24,
                cols: 80,
            },
        };
        let encoded = encode(&env).expect("encode");

        // OLD reader, NEW frame: one extra trailing field.
        let mut widened = encoded.clone();
        widened.push(0x01);
        let old_reads_new = decode(&widened);
        assert!(
            old_reads_new.is_ok(),
            "expected postcard to ignore surplus trailing bytes; if this now \
             ERRORS, widening a variant became a loud break and 926-bin4's \
             new-variant argument can be revisited"
        );
        assert_eq!(
            old_reads_new.unwrap(),
            env,
            "the surplus byte must not disturb the fields that WERE understood \
             — this is precisely why the misinterpretation is silent"
        );

        // NEW reader, OLD frame: truncate a field's worth of input.
        let mut narrowed = encoded.clone();
        narrowed.pop();
        assert!(
            decode(&narrowed).is_err(),
            "a decoder expecting more fields than the frame carries must fail, \
             not invent a default"
        );
    }

    /// ORDER 924-eof7 — the skew fact the EOF design turns on, pinned by
    /// experiment rather than by reading postcard's docs.
    ///
    /// postcard encodes an enum variant as a varint INDEX. A decoder built
    /// before a variant existed has no case for that index, so it returns an
    /// error — it does NOT skip the frame and carry on. `#[non_exhaustive]`
    /// buys source-level forward compatibility for MATCH ARMS; it buys nothing
    /// on the wire. That is why any new ControlMessage variant must be gated on
    /// a capability the peer advertised, and never merely on "we are newer".
    #[test]
    fn unknown_future_variant_is_a_decode_error_not_a_silent_skip() {
        // Hand-roll an envelope whose body names a variant index far beyond
        // anything this build knows: wire_version(varint) seq(varint)
        // variant_index(varint).
        let bytes: Vec<u8> = vec![
            1,   // wire_version = 1
            0,   // seq = 0
            200, // variant index, low 7 bits + continuation
            1,   // ... second varint byte: comfortably past the real count
        ];
        let err = decode(&bytes);
        assert!(
            err.is_err(),
            "an unknown variant index must FAIL to decode; if this ever starts \
             succeeding, the EOF capability gate in 924-eof7 rests on a false \
             premise and must be revisited"
        );
    }

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

    /// The constant is pinned so a bump cannot be incidental — it has to be
    /// someone editing this number and saying why. It caught the 997-e4v2 bump
    /// as designed, which is the only evidence that it works.
    ///
    /// v2: the `transport` module + VM-lifecycle / remote-enumeration variants
    /// for the cross-platform host shells.
    /// v3 (997-e4v2): removal of `EnumerateLocalProjects`,
    /// `LocalProjectsReply` and `LocalProjectsPush`. A mid-enum removal
    /// renumbers every later variant, so an un-bumped peer would decode a
    /// structurally valid WRONG variant rather than fail — see the
    /// `WIRE_VERSION` doc for the measured indices.
    ///
    /// @trace spec:vsock-transport, spec:host-shell-architecture
    /// @trace order:997-e4v2
    #[test]
    fn wire_version_constant_is_three() {
        assert_eq!(WIRE_VERSION, 3);
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

    /// One sample of EVERY declared `ControlMessage` variant, with its name.
    ///
    /// Shared by `control_message_kind_names_every_declared_variant` (which
    /// reads the names) and `every_variant_discriminant_is_pinned_against_literals`
    /// (which reads the encoded bytes). It is ONE list because two lists drift:
    /// before 1029-5wvd this table held 19 of 32 variants, and its own comment
    /// said the wire shape "doesn't matter" — true for the name lookup, and
    /// the reason nobody noticed it was not a variant census.
    ///
    /// EXHAUSTIVENESS IS NOT MAINTAINED BY HAND. The contiguity assertion in
    /// the discriminant test fails if this list misses a variant, and
    /// `pinned_discriminant` fails to COMPILE if the enum gains one.
    ///
    /// @trace spec:vsock-transport
    /// @trace order:1029-5wvd
    fn one_sample_per_variant() -> Vec<(ControlMessage, &'static str)> {
        vec![
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
                ControlMessage::CloudRefreshRequest { seq: 1 },
                "CloudRefreshRequest",
            ),
            (
                ControlMessage::CloudRefreshReply {
                    seq_in_reply_to: 1,
                    projects: vec![],
                    outcome: CloudRefreshOutcome::Ok,
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
                ControlMessage::MetricsSnapshotRequest { seq: 1 },
                "MetricsSnapshotRequest",
            ),
            (
                ControlMessage::MetricsSnapshotReply {
                    seq_in_reply_to: 1,
                    snapshot: MetricsSnapshotWire {
                        sampled_at_unix: 0,
                        containers: vec![],
                        mounts: vec![],
                    },
                },
                "MetricsSnapshotReply",
            ),
            // ADDED 1029-5wvd: the 13 variants this table never sampled.
            (
                ControlMessage::PtyOpen {
                    session_id: 1,
                    rows: 24,
                    cols: 80,
                    argv: vec![],
                    env: vec![],
                    cwd: None,
                },
                "PtyOpen",
            ),
            (
                ControlMessage::PtyData {
                    session_id: 1,
                    direction: PtyDirection::ToGuest,
                    bytes: vec![],
                },
                "PtyData",
            ),
            (
                ControlMessage::PtyResize {
                    session_id: 1,
                    rows: 24,
                    cols: 80,
                },
                "PtyResize",
            ),
            (
                ControlMessage::PtyClose {
                    session_id: 1,
                    exit: PtyExit {
                        code: 0,
                        signal: None,
                    },
                },
                "PtyClose",
            ),
            (
                ControlMessage::DeliverCredentials {
                    seq: 1,
                    unseal_share_b64: None,
                    installation_uuid: "u".into(),
                    root_token: None,
                },
                "DeliverCredentials",
            ),
            (
                ControlMessage::DeliverCredentialsReply {
                    seq_in_reply_to: 1,
                    success: true,
                },
                "DeliverCredentialsReply",
            ),
            (
                ControlMessage::GetVaultHandover { seq: 1 },
                "GetVaultHandover",
            ),
            (
                ControlMessage::VaultHandoverReply {
                    seq_in_reply_to: 1,
                    unseal_share_b64: None,
                    root_token: None,
                },
                "VaultHandoverReply",
            ),
            (
                ControlMessage::GithubLoginStatusRequest { seq: 1 },
                "GithubLoginStatusRequest",
            ),
            (
                ControlMessage::GithubLoginStatusReply {
                    seq_in_reply_to: 1,
                    logged_in: true,
                    handle: None,
                },
                "GithubLoginStatusReply",
            ),
            (
                ControlMessage::PtyHeartbeat {
                    session_id: 1,
                    input_state: PtyInputState::NotBlocked,
                },
                "PtyHeartbeat",
            ),
            (ControlMessage::PtyStdinEof { session_id: 1 }, "PtyStdinEof"),
            (
                ControlMessage::PtyOpenData {
                    session_id: 1,
                    rows: 24,
                    cols: 80,
                    argv: vec![],
                    env: vec![],
                    cwd: None,
                },
                "PtyOpenData",
            ),
        ]
    }

    #[test]
    fn control_message_kind_names_every_declared_variant() {
        for (msg, expected) in one_sample_per_variant() {
            assert_eq!(
                msg.kind(),
                expected,
                "kind() mismatch for {expected}: got {}",
                msg.kind()
            );
        }
    }

    /// The wire index of every `ControlMessage` variant, as an INDEPENDENT
    /// LITERAL.
    ///
    /// WHY LITERALS AND NOT `mem::discriminant` OR A DERIVED TABLE. postcard
    /// encodes an enum variant by its INDEX in the declaration, so the index
    /// is the wire contract. Any expectation COMPUTED from the enum — a
    /// discriminant, an iterator over variants, a parse of declaration order —
    /// moves when the enum moves, and agrees with it by construction. That is
    /// the defect 1029-5wvd was filed for: a pure reorder of two adjacent
    /// variants repointed every later frame and the whole gate stayed green,
    /// because everything checking the wire was built from the same source as
    /// the wire.
    ///
    /// These numbers were MEASURED by encoding a sample of each variant on the
    /// merged tree at 2562769bb (`postcard::to_allocvec`, first byte), not
    /// read off the declaration. Six of them — VmShutdownRequest 9,
    /// CloudRefreshRequest 10, DeliverCredentials 16, DeliverCredentialsReply
    /// 17, GetVaultHandover 18, PtyStdinEof 30 — were independently measured
    /// on windows-next by yolanda across 997-e4v2's mid-enum removal, chosen
    /// to straddle the renumbering hole rather than to be easy; they agree.
    ///
    /// NO WILDCARD ARM, DELIBERATELY. A new variant fails to COMPILE here
    /// (`error[E0004]`) rather than silently inheriting a neighbour's number.
    ///
    /// IF A TEST BELOW GOES RED, THE TIEBREAKER IS NOT IN THIS FILE. Ask
    /// whether the renumbering was intended. If it was, the peers that speak
    /// this wire must be updated together and WIRE_VERSION bumped (see its
    /// doc: removal is not the inverse of addition); only then update these
    /// literals. Editing a number here to restore green is how a silent
    /// renumbering ships.
    ///
    /// @trace spec:vsock-transport
    /// @trace order:1029-5wvd
    fn pinned_discriminant(msg: &ControlMessage) -> u8 {
        match msg {
            ControlMessage::Hello { .. } => 0,
            ControlMessage::HelloAck { .. } => 1,
            ControlMessage::IssueWebSession { .. } => 2,
            ControlMessage::IssueAck { .. } => 3,
            ControlMessage::Error { .. } => 4,
            ControlMessage::EvictProject { .. } => 5,
            ControlMessage::McpFrame { .. } => 6,
            ControlMessage::VmStatusRequest { .. } => 7,
            ControlMessage::VmStatusReply { .. } => 8,
            ControlMessage::VmShutdownRequest { .. } => 9,
            ControlMessage::CloudRefreshRequest { .. } => 10,
            ControlMessage::CloudRefreshReply { .. } => 11,
            ControlMessage::PtyOpen { .. } => 12,
            ControlMessage::PtyData { .. } => 13,
            ControlMessage::PtyResize { .. } => 14,
            ControlMessage::PtyClose { .. } => 15,
            ControlMessage::DeliverCredentials { .. } => 16,
            ControlMessage::DeliverCredentialsReply { .. } => 17,
            ControlMessage::GetVaultHandover { .. } => 18,
            ControlMessage::VaultHandoverReply { .. } => 19,
            ControlMessage::GithubLoginStatusRequest { .. } => 20,
            ControlMessage::GithubLoginStatusReply { .. } => 21,
            ControlMessage::Subscribe { .. } => 22,
            ControlMessage::SubscribeAck => 23,
            ControlMessage::VmStatusPush { .. } => 24,
            ControlMessage::LoginStatePush { .. } => 25,
            ControlMessage::CloudProjectsPush { .. } => 26,
            ControlMessage::PtyHeartbeat { .. } => 27,
            ControlMessage::MetricsSnapshotRequest { .. } => 28,
            ControlMessage::MetricsSnapshotReply { .. } => 29,
            ControlMessage::PtyStdinEof { .. } => 30,
            ControlMessage::PtyOpenData { .. } => 31,
        }
    }

    /// Every declared variant encodes to its pinned index, and the pinned set
    /// is exactly 0..N with no holes.
    ///
    /// TWO SEPARATE EXHAUSTIVENESS CHECKS, because one is not enough and I
    /// shipped the wrong claim first. Contiguity catches a variant left
    /// unsampled in the MIDDLE of the enum: the sampled discriminants then
    /// skip a number and the sorted set is not 0..len. It is BLIND to a
    /// TRAILING one — 32 samples measuring 0..31 is contiguous whether or not
    /// a 33rd variant sits at index 32 — and a trailing addition is the
    /// ordinary way this enum grows.
    ///
    /// MEASURED, not reasoned: the mutation that adds a trailing variant to
    /// the enum, to `kind()`, and to `pinned_discriminant` while leaving it
    /// out of the sample list passed 64/64 GREEN against the contiguity
    /// check alone. An earlier draft of this doc claimed contiguity made the
    /// list "prove its own exhaustiveness"; that was false, and the sabotage
    /// arm for this test is what caught it.
    ///
    /// So `DECLARED_VARIANTS` is a hand-maintained literal, deliberately. The
    /// chain is: a new variant fails to compile in `pinned_discriminant`
    /// (E0004) -> the author gives it a number -> this count then fails until
    /// they also SAMPLE it. Each step forces the next, and none of them can be
    /// satisfied by a value derived from the enum.
    ///
    /// @trace spec:vsock-transport
    /// @trace order:1029-5wvd
    #[test]
    fn every_variant_discriminant_is_pinned_against_literals() {
        /// The number of `ControlMessage` variants. An independent literal for
        /// the same reason the discriminants are: anything computed from the
        /// enum agrees with the enum by construction.
        const DECLARED_VARIANTS: usize = 32;

        let samples = one_sample_per_variant();
        assert_eq!(
            samples.len(),
            DECLARED_VARIANTS,
            "one_sample_per_variant covers {} of {DECLARED_VARIANTS} declared \
             variants. A variant that is declared and pinned but never sampled \
             is never encoded, so its wire index is unchecked — and if it is \
             the LAST variant, the contiguity assert below cannot see it.",
            samples.len()
        );
        assert!(
            samples.len() < 128,
            "{} variants: postcard's varint discriminant no longer fits one \
             byte, so encoded[0] is not the whole index and this test is \
             reading a prefix",
            samples.len()
        );

        let mut seen: Vec<u8> = Vec::new();
        for (msg, name) in &samples {
            let encoded = postcard::to_allocvec(msg).expect("encode sample");
            let actual = encoded[0];
            let expected = pinned_discriminant(msg);
            assert_eq!(
                actual, expected,
                "{name} encodes as discriminant {actual}, pinned at {expected}. \
                 A peer built before this change reads frame {actual} as \
                 whatever variant IT has at that index. See pinned_discriminant's \
                 doc before touching the literal."
            );
            seen.push(actual);
        }

        // THE TRAILING-VARIANT PROBE, and the only check here that cannot go
        // stale alongside the thing it guards. DECLARED_VARIANTS and the
        // sample list are both hand-maintained, so an author who adds a
        // variant and updates NEITHER leaves them agreeing with each other
        // (32 == 32) while the enum has 33 — measured: that mutation passed
        // 64/64 green against the count assert alone.
        //
        // The decoder cannot be fooled that way. If index DECLARED_VARIANTS
        // is a real variant, this frame DECODES; on an enum that genuinely
        // stops at DECLARED_VARIANTS - 1 it must be an unknown-variant error.
        // So this asks the wire itself how many variants exist, rather than
        // asking a number that someone had to remember to change.
        let one_past_the_end = [DECLARED_VARIANTS as u8, 0, 0, 0, 0, 0, 0, 0, 0];
        assert!(
            postcard::from_bytes::<ControlMessage>(&one_past_the_end).is_err(),
            "discriminant {DECLARED_VARIANTS} decoded successfully, so the enum \
             has at least {} variants while DECLARED_VARIANTS says \
             {DECLARED_VARIANTS}. A variant was added without being pinned or \
             sampled.",
            DECLARED_VARIANTS + 1
        );

        seen.sort_unstable();
        let expected_set: Vec<u8> = (0..samples.len() as u8).collect();
        assert_eq!(
            seen, expected_set,
            "sampled discriminants are not contiguous from 0: a variant is \
             declared and pinned but never sampled, so it is unchecked"
        );
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
    fn metrics_snapshot_request_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 300,
            body: ControlMessage::MetricsSnapshotRequest { seq: 300 },
        });
    }

    #[test]
    fn metrics_snapshot_reply_empty_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 301,
            body: ControlMessage::MetricsSnapshotReply {
                seq_in_reply_to: 300,
                snapshot: MetricsSnapshotWire {
                    sampled_at_unix: 1_760_000_000,
                    containers: vec![],
                    mounts: vec![],
                },
            },
        });
    }

    #[test]
    fn metrics_snapshot_reply_with_entries_roundtrip() {
        // One healthy container, one degraded container, one block-backed
        // mount, one unavailable (tmpfs) mount — the error-not-fabrication
        // contract must survive the wire byte-for-byte.
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 302,
            body: ControlMessage::MetricsSnapshotReply {
                seq_in_reply_to: 300,
                snapshot: MetricsSnapshotWire {
                    sampled_at_unix: 1_760_000_000,
                    containers: vec![
                        ContainerMetricWire {
                            name: "proxy".into(),
                            cpu_usec: Some(24_487_858),
                            memory_current_bytes: Some(104_857_600),
                            blkio_read_bytes: Some(91_889_664),
                            blkio_write_bytes: Some(613_781_504),
                            blkio_read_ops: Some(9_142),
                            blkio_write_ops: Some(1_605),
                            error: None,
                        },
                        ContainerMetricWire {
                            name: "vault".into(),
                            cpu_usec: None,
                            memory_current_bytes: None,
                            blkio_read_bytes: None,
                            blkio_write_bytes: None,
                            blkio_read_ops: None,
                            blkio_write_ops: None,
                            error: Some("cgroup scope libpod-….scope not found".into()),
                        },
                    ],
                    mounts: vec![
                        MountIoMetricWire {
                            path: "/home/forge/src".into(),
                            device: Some("vdb1".into()),
                            read_bytes: Some(790_528),
                            write_bytes: Some(45_056),
                            read_ops: Some(77),
                            write_ops: Some(11),
                            error: None,
                        },
                        MountIoMetricWire {
                            path: "/opt/cheatsheets".into(),
                            device: None,
                            read_bytes: None,
                            write_bytes: None,
                            read_ops: None,
                            write_ops: None,
                            error: Some("unavailable: tmpfs".into()),
                        },
                    ],
                },
            },
        });
    }

    #[test]
    fn metrics_snapshot_kinds() {
        assert_eq!(
            ControlMessage::MetricsSnapshotRequest { seq: 1 }.kind(),
            "MetricsSnapshotRequest"
        );
        assert_eq!(
            ControlMessage::MetricsSnapshotReply {
                seq_in_reply_to: 1,
                snapshot: MetricsSnapshotWire {
                    sampled_at_unix: 0,
                    containers: vec![],
                    mounts: vec![],
                },
            }
            .kind(),
            "MetricsSnapshotReply"
        );
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
