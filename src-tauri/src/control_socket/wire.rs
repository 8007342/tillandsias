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
//! @trace spec:tray-host-control-socket
//! @cheatsheet languages/rust.md

use serde::{Deserialize, Serialize};

/// Current wire version. Incremented when the envelope shape itself changes
/// (renaming `seq`, adding a required field). Adding a new `ControlMessage`
/// variant does NOT bump this — postcard's additive enum encoding handles
/// that case as `Error::UnknownVariant` on older readers.
pub const WIRE_VERSION: u16 = 1;

/// Maximum permitted single-message length on the wire. Length prefixes
/// greater than this trigger an `Error::PayloadTooLarge` response and the
/// connection is closed.
pub const MAX_MESSAGE_BYTES: usize = 65_536;

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

    #[test]
    fn hello_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::Hello {
                from: "router".to_string(),
                capabilities: vec!["IssueWebSession".to_string()],
            },
        });
    }

    #[test]
    fn hello_ack_roundtrip() {
        roundtrip(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 2,
            body: ControlMessage::HelloAck {
                wire_version: WIRE_VERSION,
                server_caps: vec!["v1".to_string()],
            },
        });
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

    #[test]
    fn wire_version_constant_is_one() {
        // Locked at v1. Bumping requires an additive OpenSpec change with
        // a tombstoned-compat shim per project convention.
        assert_eq!(WIRE_VERSION, 1);
    }

    #[test]
    fn max_message_bytes_is_64_kib() {
        assert_eq!(MAX_MESSAGE_BYTES, 64 * 1024);
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
