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

/// The CA node's state KIND, the generation stripped: the vocabulary of the
/// declared transition table below (order 472, exit criterion 1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaStateKind {
    Absent,
    Current,
}

impl CaStateKind {
    /// The kind of a wire state produced by [`ca_state`]; `None` for anything
    /// else, so an undeclared state cannot be classified by accident.
    pub fn of(state: &str) -> Option<CaStateKind> {
        match state {
            "absent" => Some(CaStateKind::Absent),
            s if s.strip_prefix("current:").is_some_and(|g| !g.is_empty()) => {
                Some(CaStateKind::Current)
            }
            _ => None,
        }
    }
}

/// THE DECLARED CA TRANSITIONS (order 472, exit criterion 1). Every transition
/// [`ca_transition`] can announce is one of these rows and every row is
/// reachable; the tests below fail on an undeclared transition or a dead row.
///
/// `unreadable` (the research's third state) is NOT a row yet: slice 4 refuses
/// an unreadable certificate host-side (`container_deps::ca_bundle_trustable`)
/// before any consumer mounts it, but `ca_generation` cannot tell unreadable
/// from absent, so the wire still says `absent` for it. Adding the row means
/// first making the generation read distinguish the two; until then declaring
/// it would be a row no code can reach.
pub const CA_TRANSITIONS: &[(CaStateKind, CaStateKind, &str)] = &[
    (CaStateKind::Absent, CaStateKind::Current, "minted"),
    (CaStateKind::Current, CaStateKind::Current, "rotated"),
    (CaStateKind::Current, CaStateKind::Absent, "lost"),
];

/// Whether a (from, to, reason) announcement is a declared transition.
pub fn ca_transition_declared(from: &str, to: &str, reason: &str) -> bool {
    match (CaStateKind::of(from), CaStateKind::of(to)) {
        (Some(f), Some(t)) => CA_TRANSITIONS
            .iter()
            .any(|&(df, dt, dr)| df == f && dt == t && dr == reason),
        _ => false,
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

    /// Criterion 1: every announcement over the whole input space is a declared
    /// row, and every declared row is announced for some input (no dead rows).
    #[test]
    fn every_announced_transition_is_declared_and_every_row_is_reachable() {
        let inputs = [None, Some("aa"), Some("bb")];
        let mut seen = Vec::new();
        for before in inputs {
            for after in inputs {
                if let Some((from, to, reason)) = ca_transition(before, after) {
                    assert!(
                        ca_transition_declared(&from, &to, reason),
                        "undeclared CA transition {from} -> {to} ({reason})"
                    );
                    seen.push((
                        CaStateKind::of(&from).unwrap(),
                        CaStateKind::of(&to).unwrap(),
                        reason,
                    ));
                }
            }
        }
        for row in CA_TRANSITIONS {
            assert!(
                seen.contains(row),
                "declared CA transition never announced: {row:?}"
            );
        }
    }

    #[test]
    fn undeclared_states_and_transitions_are_refused() {
        assert!(!ca_transition_declared("absent", "absent", "lost"));
        assert!(!ca_transition_declared("absent", "current:aa", "rotated"));
        assert!(!ca_transition_declared(
            "unreadable",
            "current:aa",
            "minted"
        ));
        assert!(!ca_transition_declared("absent", "current:", "minted"));
        assert!(ca_transition_declared("absent", "current:aa", "minted"));
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
