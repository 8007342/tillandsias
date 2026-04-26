//! Per-message dispatch for the tray-host control socket.
//!
//! v1 implements only the `Hello` / `HelloAck` handshake and the generic
//! `Error` reply. `IssueWebSession` and other capability-specific variants
//! land via additive OpenSpec changes (e.g., `opencode-web-session-otp`,
//! `host-browser-mcp`).
//!
//! The dispatcher returns an `Option<ControlMessage>` reply: `Some(msg)`
//! frames the reply onto the wire; `None` means no reply (fire-and-forget
//! variants — none in v1).
//!
//! @trace spec:tray-host-control-socket

use super::wire::{ControlMessage, ErrorCode, WIRE_VERSION};

/// Server capability tags advertised in `HelloAck`. Consumers consult this
/// list to decide which optional message classes they can use.
///
/// v1 advertises only `"v1"`. Future additive changes append capability
/// tags here without bumping `WIRE_VERSION`.
pub const SERVER_CAPS: &[&str] = &["v1"];

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
/// v1 handler logic:
///
/// - `Hello` → `HelloAck` (or `Error::Unsupported` + close on `wire_version` mismatch).
/// - `HelloAck` → no reply (server doesn't expect to receive this).
/// - `IssueWebSession` → `Error::Unsupported` (wired in OTP change).
/// - `IssueAck` → no reply (just bookkeeping; v1 has no pending state).
/// - `Error` → no reply (consumers send these on their own faults).
///
/// @trace spec:tray-host-control-socket
pub fn dispatch(inbound_seq: u64, message: &ControlMessage) -> DispatchOutcome {
    match message {
        ControlMessage::Hello { .. } => DispatchOutcome::Reply(ControlMessage::HelloAck {
            wire_version: WIRE_VERSION,
            server_caps: SERVER_CAPS.iter().map(|s| s.to_string()).collect(),
        }),
        ControlMessage::HelloAck { .. } => DispatchOutcome::NoReply,
        ControlMessage::IssueWebSession { .. } => {
            // OTP issuance lands with opencode-web-session-otp; for v1 we
            // surface a clear "not yet implemented" error so consumers can
            // distinguish "unknown variant" from "known but not wired up".
            DispatchOutcome::Reply(ControlMessage::Error {
                seq_in_reply_to: Some(inbound_seq),
                code: ErrorCode::Unsupported,
                message: "IssueWebSession not yet implemented (waiting on opencode-web-session-otp)".to_string(),
            })
        }
        ControlMessage::IssueAck { .. } => DispatchOutcome::NoReply,
        ControlMessage::Error { .. } => DispatchOutcome::NoReply,
    }
}

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
                assert_eq!(server_caps, vec!["v1".to_string()]);
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
    fn issue_web_session_returns_unsupported_in_v1() {
        let outcome = dispatch(
            7,
            &ControlMessage::IssueWebSession {
                project_label: "demo".to_string(),
                cookie_value: [0; 32],
            },
        );
        match outcome {
            DispatchOutcome::Reply(ControlMessage::Error {
                seq_in_reply_to,
                code,
                ..
            }) => {
                assert_eq!(seq_in_reply_to, Some(7));
                assert_eq!(code, ErrorCode::Unsupported);
            }
            other => panic!("expected Unsupported error, got {:?}", other),
        }
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
