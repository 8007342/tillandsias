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

/// The CA bundle as the generation read sees it: the 472 research's state
/// set, complete since slice 6.
///
/// `Absent` is no certificate file. `Unreadable` is a file the host would
/// refuse to hand a consumer: it cannot be read, or it is not a PEM
/// certificate, the same predicate slice 4's
/// `container_deps::ca_bundle_trustable` refuses on, so the wire says
/// `unreadable` exactly when a consumer launch is refused. `Current` carries
/// the generation (the first 16 hex digits of the certificate's SHA-256).
///
/// Before slice 6 the read was a bare `Option<generation>`, so a certificate
/// that was present but unreadable (the SELinux relabel incident, 1dda3032)
/// reached the wire as `absent`, which names the wrong remedy: a re-mint
/// where a repair of the existing file is what the incident needed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CaBundleState {
    Absent,
    Unreadable,
    Current(String),
}

impl CaBundleState {
    /// The state as the wire carries it: `absent`, `unreadable`, or
    /// `current:<generation>`.
    pub fn wire(&self) -> String {
        match self {
            CaBundleState::Absent => "absent".to_string(),
            CaBundleState::Unreadable => "unreadable".to_string(),
            CaBundleState::Current(g) => format!("current:{g}"),
        }
    }

    /// The state's kind, the generation stripped.
    pub fn kind(&self) -> CaStateKind {
        match self {
            CaBundleState::Absent => CaStateKind::Absent,
            CaBundleState::Unreadable => CaStateKind::Unreadable,
            CaBundleState::Current(_) => CaStateKind::Current,
        }
    }

    /// The generation when the bundle is current; `None` for the two states a
    /// consumer cannot be given (an absent or an unreadable certificate reads
    /// the same to a proxy label or a proxy comparison: nothing to compare).
    pub fn into_generation(self) -> Option<String> {
        match self {
            CaBundleState::Current(g) => Some(g),
            CaBundleState::Absent | CaBundleState::Unreadable => None,
        }
    }
}

/// The CA node's state KIND, the generation stripped: the vocabulary of the
/// declared transition table below (order 472, exit criterion 1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaStateKind {
    Absent,
    Unreadable,
    Current,
}

impl CaStateKind {
    /// The kind of a wire state produced by [`CaBundleState::wire`]; `None`
    /// for anything else, so an undeclared state cannot be classified by
    /// accident.
    pub fn of(state: &str) -> Option<CaStateKind> {
        match state {
            "absent" => Some(CaStateKind::Absent),
            "unreadable" => Some(CaStateKind::Unreadable),
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
/// Slice 6 added the `unreadable` rows once the generation read could tell
/// the state from `absent`. `repaired` is the 25-day refresh rewriting a
/// certificate that had become unreadable (the refresh predicate reads only
/// mtimes, so an unreadable certificate young enough is NOT refreshed: it
/// stays `unreadable`, the host refuses consumers, and no transition is
/// announced, which is the correct silence). The two `corrupted` rows and
/// `unreadable -> absent` are reachable by the pure function and, in
/// practice, only by something other than this process changing the file
/// between the two reads, which is exactly the kind of event the wire exists
/// to make visible.
pub const CA_TRANSITIONS: &[(CaStateKind, CaStateKind, &str)] = &[
    (CaStateKind::Absent, CaStateKind::Current, "minted"),
    (CaStateKind::Current, CaStateKind::Current, "rotated"),
    (CaStateKind::Current, CaStateKind::Absent, "lost"),
    (CaStateKind::Unreadable, CaStateKind::Current, "repaired"),
    (CaStateKind::Unreadable, CaStateKind::Absent, "lost"),
    (CaStateKind::Absent, CaStateKind::Unreadable, "corrupted"),
    (CaStateKind::Current, CaStateKind::Unreadable, "corrupted"),
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
/// `before` to `after`, with its reason; `None` when nothing changed.
pub fn ca_transition(
    before: &CaBundleState,
    after: &CaBundleState,
) -> Option<(String, String, &'static str)> {
    if before == after {
        return None;
    }
    let reason = match (before.kind(), after.kind()) {
        (CaStateKind::Absent, CaStateKind::Current) => "minted",
        (CaStateKind::Current, CaStateKind::Current) => "rotated",
        (CaStateKind::Current, CaStateKind::Absent)
        | (CaStateKind::Unreadable, CaStateKind::Absent) => "lost",
        (CaStateKind::Unreadable, CaStateKind::Current) => "repaired",
        (CaStateKind::Absent, CaStateKind::Unreadable)
        | (CaStateKind::Current, CaStateKind::Unreadable) => "corrupted",
        // Both payload-less, so equal kinds here means equal states, which
        // returned above; nothing to announce.
        (CaStateKind::Absent, CaStateKind::Absent)
        | (CaStateKind::Unreadable, CaStateKind::Unreadable) => return None,
    };
    Some((before.wire(), after.wire(), reason))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn current(g: &str) -> CaBundleState {
        CaBundleState::Current(g.to_string())
    }

    #[test]
    fn an_unchanged_ca_announces_nothing() {
        assert_eq!(ca_transition(&current("aa"), &current("aa")), None);
        assert_eq!(
            ca_transition(&CaBundleState::Absent, &CaBundleState::Absent),
            None
        );
        assert_eq!(
            ca_transition(&CaBundleState::Unreadable, &CaBundleState::Unreadable),
            None
        );
    }

    /// Criterion 1: every announcement over the whole input space is a declared
    /// row, and every declared row is announced for some input (no dead rows).
    #[test]
    fn every_announced_transition_is_declared_and_every_row_is_reachable() {
        let inputs = [
            CaBundleState::Absent,
            CaBundleState::Unreadable,
            current("aa"),
            current("bb"),
        ];
        let mut seen = Vec::new();
        for before in &inputs {
            for after in &inputs {
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
        // The unreadable -> current row exists, under its own reason.
        assert!(!ca_transition_declared(
            "unreadable",
            "current:aa",
            "minted"
        ));
        assert!(ca_transition_declared(
            "unreadable",
            "current:aa",
            "repaired"
        ));
        assert!(!ca_transition_declared(
            "unreadable",
            "unreadable",
            "corrupted"
        ));
        assert!(!ca_transition_declared("absent", "current:", "minted"));
        assert!(!ca_transition_declared("broken", "current:aa", "repaired"));
        assert!(ca_transition_declared("absent", "current:aa", "minted"));
    }

    #[test]
    fn mint_rotate_and_loss_are_distinct_transitions() {
        assert_eq!(
            ca_transition(&CaBundleState::Absent, &current("aa")),
            Some(("absent".into(), "current:aa".into(), "minted"))
        );
        assert_eq!(
            ca_transition(&current("aa"), &current("bb")),
            Some(("current:aa".into(), "current:bb".into(), "rotated"))
        );
        assert_eq!(
            ca_transition(&current("aa"), &CaBundleState::Absent),
            Some(("current:aa".into(), "absent".into(), "lost"))
        );
    }

    /// Slice 6: `unreadable` is a state of its own on the wire, never spelled
    /// `absent`, and leaving it by a refresh is a repair, not a mint.
    #[test]
    fn unreadable_is_its_own_state_and_leaving_it_is_a_repair() {
        assert_eq!(CaBundleState::Unreadable.wire(), "unreadable");
        assert_eq!(CaStateKind::of("unreadable"), Some(CaStateKind::Unreadable));
        assert_eq!(CaBundleState::Unreadable.into_generation(), None);
        assert_eq!(
            ca_transition(&CaBundleState::Unreadable, &current("aa")),
            Some(("unreadable".into(), "current:aa".into(), "repaired"))
        );
        assert_eq!(
            ca_transition(&current("aa"), &CaBundleState::Unreadable),
            Some(("current:aa".into(), "unreadable".into(), "corrupted"))
        );
        assert_eq!(
            ca_transition(&CaBundleState::Absent, &CaBundleState::Unreadable),
            Some(("absent".into(), "unreadable".into(), "corrupted"))
        );
        assert_eq!(
            ca_transition(&CaBundleState::Unreadable, &CaBundleState::Absent),
            Some(("unreadable".into(), "absent".into(), "lost"))
        );
    }
}
