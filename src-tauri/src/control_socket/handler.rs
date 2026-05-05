//! Per-message dispatch for the tray-host control socket.
//!
//! v1 implements the `Hello` / `HelloAck` handshake, the generic `Error`
//! reply, and the `IssueWebSession` -> `IssueAck` exchange (wired by
//! `opencode-web-session-otp`).
//!
//! The dispatcher returns an `Option<ControlMessage>` reply: `Some(msg)`
//! frames the reply onto the wire; `None` means no reply (fire-and-forget
//! variants — none today).
//!
//! @trace spec:tray-host-control-socket, spec:opencode-web-session-otp

use super::wire::{ControlMessage, ErrorCode, WIRE_VERSION};

/// Server capability tags advertised in `HelloAck`. Consumers consult this
/// list to decide which optional message classes they can use.
///
/// `"v1"` — the base message classes (Hello, IssueAck, Error).
/// `"IssueWebSession"` — the per-window OTP issuance flow wired by
/// `opencode-web-session-otp`.
///
/// @trace spec:tray-host-control-socket, spec:opencode-web-session-otp
pub const SERVER_CAPS: &[&str] = &["v1", "IssueWebSession"];

/// Outcome of dispatching a single inbound `ControlMessage`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DispatchOutcome {
    /// Reply with this message envelope, then continue reading.
    Reply(ControlMessage),
    /// Reply with this error envelope, then close the stream gracefully.
    /// Reserved for future variants (wire-version mismatches, fatal
    /// per-connection errors); v1 dispatch never returns this directly —
    /// the version-mismatch path in `mod.rs` handles its own close.
    #[allow(dead_code)]
    ReplyAndClose(ControlMessage),
    /// No reply needed; continue reading.
    NoReply,
}

/// Handle a single inbound `ControlMessage` and produce the dispatch
/// outcome.
///
/// Handler logic:
///
/// - `Hello` → `HelloAck` (or `Error::Unsupported` + close on `wire_version` mismatch).
/// - `HelloAck` → no reply (server doesn't expect to receive this).
/// - `IssueWebSession` → push into `crate::otp::global()` and reply with
///   `IssueAck` carrying `seq_acked = inbound_seq`. Wired by
///   `opencode-web-session-otp`.
/// - `IssueAck` → no reply (just bookkeeping; senders consume these as
///   their proof of acceptance).
/// - `Error` → no reply (consumers send these on their own faults).
///
/// @trace spec:tray-host-control-socket, spec:opencode-web-session-otp
pub fn dispatch(inbound_seq: u64, message: &ControlMessage) -> DispatchOutcome {
    match message {
        ControlMessage::Hello { .. } => DispatchOutcome::Reply(ControlMessage::HelloAck {
            wire_version: WIRE_VERSION,
            server_caps: SERVER_CAPS.iter().map(|s| s.to_string()).collect(),
        }),
        ControlMessage::HelloAck { .. } => DispatchOutcome::NoReply,
        ControlMessage::IssueWebSession {
            project_label,
            cookie_value: _,
        } => {
            // @trace spec:opencode-web-session-otp
            // Inbound IssueWebSession at the tray-side dispatch is now a
            // defensive no-op. The production issuance path is
            // `crate::otp::issue_and_publish`, which writes to the
            // tray-local store and broadcasts to subscribed sidecars in
            // one step — there is no peer that legitimately PUSHES into
            // the tray today. Future CLI clients that want to register a
            // session would re-enter this arm; a dispatch-side push at
            // that point would diverge the tray's mirror from the
            // sidecar's authoritative store. We log + ack so misbehaving
            // clients at least see acknowledgement, but do nothing else.
            tracing::debug!(
                spec = "opencode-web-session-otp",
                project = %project_label,
                "IssueWebSession received at tray dispatch — sidecar owns the store; ignored"
            );
            DispatchOutcome::Reply(ControlMessage::IssueAck {
                seq_acked: inbound_seq,
            })
        }
        ControlMessage::IssueAck { .. } => DispatchOutcome::NoReply,
        ControlMessage::Error { .. } => DispatchOutcome::NoReply,
        // ControlMessage is `#[non_exhaustive]`. Future variants surface
        // here as a no-reply pass-through until a dispatch arm is added in
        // the change that introduces them. Logging at debug because an
        // unknown variant is interesting but not actionable.
        other => {
            tracing::debug!(
                spec = "tray-host-control-socket",
                discriminant = ?std::mem::discriminant(other),
                "Unhandled ControlMessage variant — no-reply pass-through"
            );
            DispatchOutcome::NoReply
        }
    }
}

/// Marker so the unused-import lint doesn't kick in when we strip the
/// IssueWebSession Unsupported branch in favour of the wired one.
const _: ErrorCode = ErrorCode::Unsupported;

/// Build an `Error::Unsupported` envelope used when the peer's
/// `wire_version` differs from ours. After flushing this frame the caller
/// closes the stream.
///
/// @trace spec:tray-host-control-socket
pub fn wire_version_mismatch(inbound_seq: u64, peer_version: u16) -> ControlMessage {
    ControlMessage::Error {
        seq_in_reply_to: Some(inbound_seq),
        code: ErrorCode::Unsupported,
        message: format!(
            "wire_version mismatch: server={} peer={}",
            WIRE_VERSION, peer_version
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_yields_hello_ack() {
        let outcome = dispatch(
            42,
            &ControlMessage::Hello {
                from: "router".to_string(),
                capabilities: vec![],
            },
        );
        match outcome {
            DispatchOutcome::Reply(ControlMessage::HelloAck {
                wire_version,
                server_caps,
            }) => {
                assert_eq!(wire_version, WIRE_VERSION);
                assert_eq!(
                    server_caps,
                    SERVER_CAPS.iter().map(|s| s.to_string()).collect::<Vec<_>>()
                );
                assert!(server_caps.contains(&"v1".to_string()));
                assert!(server_caps.contains(&"IssueWebSession".to_string()));
            }
            other => panic!("expected HelloAck reply, got {:?}", other),
        }
    }

    #[test]
    fn hello_ack_yields_no_reply() {
        let outcome = dispatch(
            1,
            &ControlMessage::HelloAck {
                wire_version: WIRE_VERSION,
                server_caps: vec![],
            },
        );
        assert_eq!(outcome, DispatchOutcome::NoReply);
    }

    #[test]
    fn issue_web_session_at_tray_dispatch_acks_without_pushing() {
        // Post-chunk-6: the tray-side dispatch arm is defensive — the
        // sidecar owns the authoritative store, the tray's
        // issue_and_publish path writes the local mirror directly. Any
        // peer that pushes IssueWebSession at us today is unexpected; we
        // ack so the peer sees acknowledgement, but the tray-local store
        // does NOT grow.
        let project = "opencode.handler-test.localhost";
        let cookie: [u8; 32] = std::array::from_fn(|i| i as u8 ^ 0x42);
        let before = crate::otp::global().session_count(project);
        let outcome = dispatch(
            7,
            &ControlMessage::IssueWebSession {
                project_label: project.to_string(),
                cookie_value: cookie,
            },
        );
        match outcome {
            DispatchOutcome::Reply(ControlMessage::IssueAck { seq_acked }) => {
                assert_eq!(seq_acked, 7);
            }
            other => panic!("expected IssueAck reply, got {:?}", other),
        }
        let after = crate::otp::global().session_count(project);
        assert_eq!(
            after, before,
            "tray-local store must NOT grow on dispatch — sidecar owns it"
        );
    }

    #[test]
    fn wire_version_mismatch_builds_unsupported_error() {
        let env = wire_version_mismatch(99, 7);
        match env {
            ControlMessage::Error {
                seq_in_reply_to,
                code,
                message,
            } => {
                assert_eq!(seq_in_reply_to, Some(99));
                assert_eq!(code, ErrorCode::Unsupported);
                assert!(message.contains("wire_version"));
            }
            other => panic!("expected Error envelope, got {:?}", other),
        }
    }
}
