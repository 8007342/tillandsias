// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md
// @trace spec:tray-host-control-socket, spec:vsock-transport
//! Pure routing matrix for the two control-socket dispatchers.
//!
//! `tillandsias-headless` ships two control-wire dispatchers — one for the
//! local Unix socket (tray-side, sync, in `tray/mod.rs`) and one for
//! virtio-vsock (in-VM, async, in `vsock_server.rs`). Until now each
//! transport handled its own subset of `ControlMessage` variants and the
//! "other" arm wrote an `Error{Unsupported}` frame back. The matrices
//! were duplicated by hand and a new variant could easily land in one
//! dispatcher but not the other.
//!
//! This module is the FIRST step of the convergence packet:
//!
//!   1. A pure decision function `decide_route(msg, transport)`
//!      returns `DispatchOutcome::Handle` when the transport supports
//!      the variant, `Unsupported` when it doesn't, `ResponseOnly`
//!      for response-shaped variants that should never appear as the
//!      first frame.
//!   2. The two existing dispatchers consult this function (step 2-3
//!      of the convergence packet, a follow-on slice).
//!
//! The matrix encodes the design-question answers from
//! `plan/issues/control-socket-protocol-convergence-2026-05-25.md`:
//!
//!   * Q1: `IssueWebSession` and `EvictProject` are unix-only (OTP
//!     issuance is host-scope; the in-VM headless has no business
//!     issuing browser cookies).
//!   * Q2: `VmStatusRequest` and `VmShutdownRequest` are available
//!     on BOTH transports (Linux native has a "phase" too — useful
//!     for in-process tray ↔ headless UI consistency).
//!   * Q4: `EnumerateLocalProjects` and `CloudRefreshRequest` are on
//!     BOTH (each host's local scanner populates them).
//!   * PTY family (`PtyOpen`/`PtyData`/`PtyResize`/`PtyClose`) is
//!     vsock-only — the in-VM headless is the PTY producer.

use tillandsias_control_wire::ControlMessage;

// STAGED: items below are consumed by the convergence-packet
// items 2-3 (wiring into `tray::handle_control_connection` and
// `vsock_server::serve_connection`). Until that follow-on slice
// lands, the pure-decision surface lives here for unit testing
// without triggering `dead_code` warnings.
#[allow(dead_code)]
/// Which transport the incoming envelope arrived on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportKind {
    /// Local Unix socket (host-side, sync, served by `tray::handle_control_connection`).
    UnixSocket,
    /// Virtio-vsock (in-VM, async, served by `vsock_server::serve_connection`).
    Vsock,
}

/// Outcome of routing one `ControlMessage` variant on one transport.
///
/// Kept narrow on purpose: today both dispatchers only need to know
/// "should I run my handler" vs "should I write an Error{Unsupported}".
/// Broadcast and subscribe semantics live in the unix dispatcher's body
/// and don't need a separate enum variant yet — they're implementation
/// details, not routing decisions.
#[allow(dead_code)] // staged for convergence-packet items 2-3
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DispatchOutcome {
    /// The transport supports this variant — run its handler.
    Handle,
    /// The transport does NOT support this variant — reply with
    /// `Error{Unsupported}` so the client doesn't hang.
    Unsupported,
    /// A response-shaped variant that should never arrive as the first
    /// frame of a connection. Treat as a protocol violation; close the
    /// connection cleanly (with an `Error{Unsupported}` if a seq is
    /// available, otherwise just drop).
    ResponseOnly,
}

/// Decide whether `transport` should handle `msg`. Pure function — no
/// I/O, no allocation, no global state. Unit-pinnable.
///
/// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md
///   (Q1/Q2/Q4 design answers)
#[allow(dead_code)] // staged for convergence-packet items 2-3
pub fn decide_route(msg: &ControlMessage, transport: TransportKind) -> DispatchOutcome {
    use ControlMessage::*;
    use DispatchOutcome::*;
    use TransportKind::*;

    match (msg, transport) {
        // Hello opens every connection on both transports.
        (Hello { .. }, _) => Handle,

        // Q1: web-session OTP issuance is unix-only.
        // The in-VM headless has no browser to issue cookies for.
        (IssueWebSession { .. } | EvictProject { .. }, UnixSocket) => Handle,
        (IssueWebSession { .. } | EvictProject { .. }, Vsock) => Unsupported,

        // Q2: VM lifecycle queries on BOTH transports. Linux native has
        // a "phase" (Provisioning/Starting/Ready/...) too — useful for
        // UI state consistency even without a real VM.
        (VmStatusRequest { .. } | VmShutdownRequest { .. }, _) => Handle,

        // Q4: project enumeration + cloud refresh on BOTH transports.
        // Each host's local scanner populates the response from its own
        // filesystem / `gh` invocation.
        (EnumerateLocalProjects { .. } | CloudRefreshRequest { .. }, _) => Handle,

        // PTY family is vsock-only — the in-VM headless is the PTY
        // producer (it owns the forge container's session). The unix
        // dispatcher would have nothing useful to do here.
        (PtyOpen { .. } | PtyData { .. } | PtyResize { .. } | PtyClose { .. }, Vsock) => Handle,
        (PtyOpen { .. } | PtyData { .. } | PtyResize { .. } | PtyClose { .. }, UnixSocket) => {
            Unsupported
        }

        // DeliverCredentials and GetVaultHandover are vsock-only (for in-VM credential delivery/handover)
        (DeliverCredentials { .. } | GetVaultHandover { .. }, Vsock) => Handle,
        (DeliverCredentials { .. } | GetVaultHandover { .. }, UnixSocket) => Unsupported,

        // McpFrame is the host-browser-mcp tunnel between forge and tray
        // — it flows ONLY across the local Unix socket (the forge in-VM
        // has no direct host-browser dependency). Vsock side rejects.
        (McpFrame { .. }, UnixSocket) => Handle,
        (McpFrame { .. }, Vsock) => Unsupported,

        // Response-shaped variants: HelloAck, IssueAck, Error, every *Reply.
        // These NEVER appear as the first frame of a connection — they're
        // the SERVER's writes to a client's request seq. Arriving as an
        // inbound first frame means a peer is confused; reject.
        (
            HelloAck { .. }
            | IssueAck { .. }
            | Error { .. }
            | VmStatusReply { .. }
            | LocalProjectsReply { .. }
            | CloudRefreshReply { .. }
            | DeliverCredentialsReply { .. }
            | VaultHandoverReply { .. },
            _,
        ) => ResponseOnly,

        // `#[non_exhaustive]` on the enum: a future variant we haven't
        // taught the matrix about. Default to Unsupported so the
        // operator sees an explicit Error{Unsupported} rather than
        // silent drop. The unit test below catches this for every
        // currently-declared variant; the wildcard is forward-defence
        // only.
        _ => Unsupported,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tillandsias_control_wire::{ControlMessage, ErrorCode, PtyDirection, PtyExit, VmPhase};

    /// Construct one envelope per variant for the matrix tests. Keeps
    /// the test bodies short.
    fn one_of_each() -> Vec<(ControlMessage, &'static str)> {
        vec![
            (
                ControlMessage::Hello {
                    from: "x".into(),
                    capabilities: vec![],
                },
                "Hello",
            ),
            (
                ControlMessage::HelloAck {
                    wire_version: 2,
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
                ControlMessage::PtyOpen {
                    session_id: 1,
                    rows: 24,
                    cols: 80,
                    argv: vec!["/bin/sh".into()],
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
                    cols: 80,
                    rows: 24,
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
                    installation_uuid: "uuid".to_string(),
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
        ]
    }

    /// Exhaustively pin the unix-socket matrix against the
    /// `control-socket-protocol-convergence-2026-05-25` Q1/Q2/Q4 answers.
    #[test]
    fn unix_socket_routing_matrix() {
        for (msg, name) in one_of_each() {
            let expected = match name {
                "Hello"
                | "IssueWebSession"
                | "EvictProject"
                | "McpFrame"
                | "VmStatusRequest"
                | "VmShutdownRequest"
                | "EnumerateLocalProjects"
                | "CloudRefreshRequest" => DispatchOutcome::Handle,
                "PtyOpen" | "PtyData" | "PtyResize" | "PtyClose" | "DeliverCredentials"
                | "GetVaultHandover" => DispatchOutcome::Unsupported,
                "HelloAck"
                | "IssueAck"
                | "Error"
                | "VmStatusReply"
                | "LocalProjectsReply"
                | "CloudRefreshReply"
                | "DeliverCredentialsReply"
                | "VaultHandoverReply" => DispatchOutcome::ResponseOnly,
                _ => unreachable!("test fixture missing case for {name}"),
            };
            assert_eq!(
                decide_route(&msg, TransportKind::UnixSocket),
                expected,
                "unix-socket routing mismatch for {name}"
            );
        }
    }

    /// Exhaustively pin the vsock matrix. Diverges from unix on:
    ///   * IssueWebSession / EvictProject → Unsupported (Q1)
    ///   * McpFrame                       → Unsupported (host-only tunnel)
    ///   * PTY family                     → Handle (vsock is the PTY producer)
    #[test]
    fn vsock_routing_matrix() {
        for (msg, name) in one_of_each() {
            let expected = match name {
                "Hello"
                | "VmStatusRequest"
                | "VmShutdownRequest"
                | "EnumerateLocalProjects"
                | "CloudRefreshRequest"
                | "PtyOpen"
                | "PtyData"
                | "PtyResize"
                | "PtyClose"
                | "DeliverCredentials"
                | "GetVaultHandover" => DispatchOutcome::Handle,
                "IssueWebSession" | "EvictProject" | "McpFrame" => DispatchOutcome::Unsupported,
                "HelloAck"
                | "IssueAck"
                | "Error"
                | "VmStatusReply"
                | "LocalProjectsReply"
                | "CloudRefreshReply"
                | "DeliverCredentialsReply"
                | "VaultHandoverReply" => DispatchOutcome::ResponseOnly,
                _ => unreachable!("test fixture missing case for {name}"),
            };
            assert_eq!(
                decide_route(&msg, TransportKind::Vsock),
                expected,
                "vsock routing mismatch for {name}"
            );
        }
    }

    /// Symmetric variants pinned at once: every variant that the
    /// convergence packet says is "both transports" must agree.
    #[test]
    fn symmetric_variants_match_on_both_transports() {
        let symmetric = [
            ControlMessage::Hello {
                from: "x".into(),
                capabilities: vec![],
            },
            ControlMessage::VmStatusRequest { seq: 1 },
            ControlMessage::VmShutdownRequest {
                seq: 1,
                drain_timeout_ms: 0,
            },
            ControlMessage::EnumerateLocalProjects { seq: 1 },
            ControlMessage::CloudRefreshRequest { seq: 1 },
        ];
        for msg in &symmetric {
            assert_eq!(
                decide_route(msg, TransportKind::UnixSocket),
                decide_route(msg, TransportKind::Vsock),
                "symmetric variant routed differently: {msg:?}"
            );
        }
    }

    /// A `ResponseOnly` arrival is a protocol violation regardless of
    /// transport. Pin it.
    #[test]
    fn response_shaped_variants_are_response_only_on_both_transports() {
        let resp = [
            ControlMessage::HelloAck {
                wire_version: 2,
                server_caps: vec![],
            },
            ControlMessage::IssueAck { seq_acked: 1 },
            ControlMessage::Error {
                seq_in_reply_to: None,
                code: ErrorCode::Unsupported,
                message: "x".into(),
            },
            ControlMessage::VmStatusReply {
                seq_in_reply_to: 1,
                phase: VmPhase::Ready,
                podman_ready: true,
                last_event: None,
            },
            ControlMessage::LocalProjectsReply {
                seq_in_reply_to: 1,
                entries: vec![],
            },
            ControlMessage::CloudRefreshReply {
                seq_in_reply_to: 1,
                projects: vec![],
            },
            ControlMessage::DeliverCredentialsReply {
                seq_in_reply_to: 1,
                success: true,
            },
            ControlMessage::VaultHandoverReply {
                seq_in_reply_to: 1,
                unseal_share_b64: None,
                root_token: None,
            },
        ];
        for msg in &resp {
            assert_eq!(
                decide_route(msg, TransportKind::UnixSocket),
                DispatchOutcome::ResponseOnly
            );
            assert_eq!(
                decide_route(msg, TransportKind::Vsock),
                DispatchOutcome::ResponseOnly
            );
        }
    }
}
