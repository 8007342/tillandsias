//! The process-wide destination for flow and dependency-node state transitions
//! (order 472, slice 3). Same shape as `progress_sink`: emitters call
//! [`emit`] without knowing whether a control wire exists, and the vsock
//! server, when this process runs one, calls [`install`] once so transitions
//! reach its `FlowState` subscribers. With nothing installed, [`emit`] is a
//! no-op.
//!
//! The first emitter is the CA bundle (see [`ca_transition`]): the research on
//! 472 found that every CA incident was a transition nobody observed, so the
//! transition is made observable before any consumer is made to react to it.
//!
//! @trace order:472

use std::sync::OnceLock;
use tillandsias_control_wire::FlowSource;

type Sink = Box<dyn Fn(FlowSource, String, String, Option<String>) + Send + Sync>;

static SINK: OnceLock<Sink> = OnceLock::new();

/// Install the sink; the first install wins.
#[cfg_attr(not(feature = "listen-vsock"), allow(dead_code))]
pub fn install(
    sink: impl Fn(FlowSource, String, String, Option<String>) + Send + Sync + 'static,
) -> bool {
    SINK.set(Box::new(sink)).is_ok()
}

/// Deliver one transition to the installed sink, if any.
pub fn emit(source: FlowSource, from: String, to: String, reason: Option<String>) {
    if let Some(sink) = SINK.get() {
        sink(source, from, to, reason);
    }
}

/// The CA bundle's node name on the wire.
pub const CA_BUNDLE_NODE: &str = "ca_bundle";

/// The CA bundle's state, from the 472 research's minimal state set:
/// `absent` (no readable certificate) or `current:<generation>`.
pub fn ca_state(generation: Option<&str>) -> String {
    match generation {
        Some(g) => format!("current:{g}"),
        None => "absent".to_string(),
    }
}

/// The transition to announce when `ensure_ca_bundle` moved the CA from
/// `before` to `after` (each a generation, `None` when absent), with its
/// reason; `None` when nothing changed.
pub fn ca_transition(
    before: Option<&str>,
    after: Option<&str>,
) -> Option<(String, String, &'static str)> {
    if before == after {
        return None;
    }
    let reason = match (before, after) {
        (None, Some(_)) => "minted",
        (Some(_), Some(_)) => "rotated",
        (_, None) => "lost",
    };
    Some((ca_state(before), ca_state(after), reason))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unchanged_ca_announces_nothing() {
        assert_eq!(ca_transition(Some("aa"), Some("aa")), None);
        assert_eq!(ca_transition(None, None), None);
    }

    #[test]
    fn mint_rotate_and_loss_are_distinct_transitions() {
        assert_eq!(
            ca_transition(None, Some("aa")),
            Some(("absent".into(), "current:aa".into(), "minted"))
        );
        assert_eq!(
            ca_transition(Some("aa"), Some("bb")),
            Some(("current:aa".into(), "current:bb".into(), "rotated"))
        );
        assert_eq!(
            ca_transition(Some("aa"), None),
            Some(("current:aa".into(), "absent".into(), "lost"))
        );
    }
}
