//! Order 977-56fd (rung 1 of 976-kk6x) — the obligation lattice, in code.
//!
//! `methodology/math-foundations.yaml` describes a seven-state obligation
//! lattice, a product order over spec and project states, a refinement operator
//! and a ranking function. Until this module, NONE of it existed: measured
//! 2026-09-03, `ObligationState`, `centicolon_function`, `evidence_bundled` and
//! `refine_obligation` each returned zero across `crates/` and `scripts/`.
//! Meanwhile `scripts/local-ci.sh:500` computes `total_cc`, a weighted checklist
//! of passing CI checks — a DIFFERENT object under the same name, which is how a
//! gap like this survives.
//!
//! THE MODEL COMES FIRST because property tests over a paper model test nothing.
//! Rung 2 (977-dpbj) tests this; rung 3 wires the scorer to it.
//!
//! # The two orders are not the same shape, and that is load-bearing
//!
//! [`ObligationState`] is a **chain**: any two values are comparable. So a
//! property test over single obligations can never exercise incomparability.
//!
//! [`SpecState`] and [`ProjectState`] are **products**, compared componentwise,
//! and most pairs of distinct states are INCOMPARABLE — one obligation better
//! here, another better there. That asymmetry is why rung 2 must generate
//! comparable pairs BY CONSTRUCTION: a generator drawing two independent spec
//! states discards nearly every case, and the property then passes over an
//! almost-empty sample while reporting thousands of successes.

use std::collections::{BTreeMap, BTreeSet};

/// The seven obligation states, ordered from least evidence to strongest.
///
/// DECLARATION ORDER IS THE ORDER. `PartialOrd`/`Ord` are derived, and a
/// fieldless enum derives them from declaration position — so the chain is
/// stated once, here, in the sequence `math-foundations.yaml` declares. Writing
/// the ordering a second time (a `rank()` match, a comparison impl) would be a
/// second place for it to drift, which is the defect this repository keeps
/// paying for. [`ObligationState::ALL`] exists so a test can assert the sequence
/// against the methodology rather than against itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ObligationState {
    Absent,
    Declared,
    Traced,
    PositivelyTested,
    NegativelyTested,
    RuntimeObserved,
    EvidenceBundled,
}

impl ObligationState {
    /// Every state, in methodology order. The chain's only enumeration.
    pub const ALL: [ObligationState; 7] = [
        ObligationState::Absent,
        ObligationState::Declared,
        ObligationState::Traced,
        ObligationState::PositivelyTested,
        ObligationState::NegativelyTested,
        ObligationState::RuntimeObserved,
        ObligationState::EvidenceBundled,
    ];

    /// The methodology's spelling, for round-tripping against the YAML.
    pub fn as_str(self) -> &'static str {
        match self {
            ObligationState::Absent => "absent",
            ObligationState::Declared => "declared",
            ObligationState::Traced => "traced",
            ObligationState::PositivelyTested => "positively_tested",
            ObligationState::NegativelyTested => "negatively_tested",
            ObligationState::RuntimeObserved => "runtime_observed",
            ObligationState::EvidenceBundled => "evidence_bundled",
        }
    }

    pub fn from_str_exact(s: &str) -> Option<ObligationState> {
        ObligationState::ALL.into_iter().find(|v| v.as_str() == s)
    }

    /// Bottom of the chain. An obligation nobody has recorded anything about is
    /// `Absent`, and that is what an ABSENT KEY means when two states are
    /// aligned — see [`SpecState::partial_cmp`].
    pub const BOTTOM: ObligationState = ObligationState::Absent;
}

/// A spec's obligations: stable ID -> state.
///
/// `BTreeMap` rather than `HashMap` deliberately: comparison and the eventual
/// score must not depend on iteration order, and a deterministic order makes a
/// failing property's shrunk output readable.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SpecState {
    obligations: BTreeMap<String, ObligationState>,
    /// Obligation ids that have been TOMBSTONED — the requirement they named
    /// changed meaning and was replaced by a new id (order 977-56fd, against
    /// methodology/proximity.yaml:47). They are excluded from the comparison
    /// domain entirely; see `aligned_ids`.
    tombstoned: BTreeSet<String>,
}

impl SpecState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with(mut self, id: &str, state: ObligationState) -> Self {
        self.obligations.insert(id.to_string(), state);
        self
    }

    pub fn set(&mut self, id: &str, state: ObligationState) {
        self.obligations.insert(id.to_string(), state);
    }

    /// The state of `id`, or `Absent` — an unrecorded obligation is at the
    /// bottom of the chain, not missing. This is the "aligning stable IDs and
    /// tombstones" the methodology asks for: alignment is total, so two states
    /// over different ID sets are still comparable in principle.
    pub fn get(&self, id: &str) -> ObligationState {
        self.obligations
            .get(id)
            .copied()
            .unwrap_or(ObligationState::BOTTOM)
    }

    pub fn ids(&self) -> impl Iterator<Item = &str> {
        self.obligations.keys().map(|s| s.as_str())
    }

    pub fn is_empty(&self) -> bool {
        self.obligations.is_empty()
    }

    /// Mark `id` tombstoned: the requirement it named changed MEANING and was
    /// replaced by a new id.
    ///
    /// THE OPERATOR'S RULE DECIDES WHAT THIS MUST NOT DO
    /// (methodology/proximity.yaml:47, verbatim): "If the meaning changes and no
    /// longer reflects the original intent then it's a tombstone plus a new id.
    /// If the change is a refinement over the original text and the original
    /// still stands then it's a stable id keeping."
    ///
    /// So a REFINEMENT keeps its identifier and needs nothing here — the state
    /// travels with the key, which is why that case was never at risk. A
    /// TOMBSTONE means the obligation is a DIFFERENT obligation, and evidence
    /// gathered for the old meaning is not evidence for the new one. There is
    /// therefore NO CARRY to the successor: the new id starts at `Absent`,
    /// because it genuinely has no evidence yet.
    ///
    /// Carrying would launder a score across exactly the break the operator's
    /// rule exists to mark. That is a decision, not an implementation detail,
    /// and it is decided by the ruling rather than by convenience — carry and
    /// refuse are not equivalent and the sentence picks refuse.
    pub fn tombstone(&mut self, id: &str) {
        self.tombstoned.insert(id.to_string());
    }

    pub fn is_tombstoned(&self, id: &str) -> bool {
        self.tombstoned.contains(id)
    }

    /// The domain a componentwise comparison runs over: the union of both ID
    /// sets, MINUS every id either side has tombstoned.
    ///
    /// THE DEFECT THIS FIXES, found by macuahuitl against 976-suab before rung 2
    /// was written. A tombstoned id disappears from the map, and `get` returns
    /// `Absent` for a missing key — so a legitimate identity change presented as
    /// a regression to the chain's bottom. Two consequences and the second is
    /// worse: the score silently dropped, and rung 2 would have reported a false
    /// MONOTONICITY VIOLATION about `math.fixpoint.convergence-target@v1` that
    /// was really an artifact of key handling. A finding about the methodology's
    /// own claim, manufactured by my map.
    ///
    /// So absence is THREE cases, not two:
    ///
    /// * never recorded — `Absent`, in the domain, genuinely the bottom.
    /// * tombstoned — OUT of the domain. The obligation ceased to exist, which
    ///   is not the same as having no evidence.
    /// * successor of a tombstone — a new id, in the domain, at `Absent`, with
    ///   no carry.
    fn aligned_ids(&self, other: &SpecState) -> BTreeSet<String> {
        self.obligations
            .keys()
            .chain(other.obligations.keys())
            .filter(|id| !self.tombstoned.contains(*id) && !other.tombstoned.contains(*id))
            .cloned()
            .collect()
    }
}

/// COMPONENTWISE ORDER, and it is a genuine PARTIAL order.
///
/// `a <= b` iff every aligned obligation satisfies `a[id] <= b[id]`. When one
/// obligation is stronger in `a` and another is stronger in `b`, the pair is
/// INCOMPARABLE and this returns `None` — it does not fall back to `Equal`, and
/// it does not compare some summary number instead. A partial order that
/// silently totalises is the failure this whole packet exists to prevent: it
/// would make monotonicity vacuously true in rung 2, because no pair could ever
/// witness a violation.
impl PartialOrd for SpecState {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        use std::cmp::Ordering;
        let mut saw_less = false;
        let mut saw_greater = false;
        for id in self.aligned_ids(other) {
            match self.get(&id).cmp(&other.get(&id)) {
                Ordering::Less => saw_less = true,
                Ordering::Greater => saw_greater = true,
                Ordering::Equal => {}
            }
            if saw_less && saw_greater {
                return None; // incomparable, and no further evidence can change it
            }
        }
        match (saw_less, saw_greater) {
            (false, false) => Some(Ordering::Equal),
            (true, false) => Some(Ordering::Less),
            (false, true) => Some(Ordering::Greater),
            (true, true) => unreachable!("returned above"),
        }
    }
}

/// The project: spec ID -> [`SpecState`], ordered componentwise the same way.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ProjectState {
    specs: BTreeMap<String, SpecState>,
}

impl ProjectState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with(mut self, spec: &str, state: SpecState) -> Self {
        self.specs.insert(spec.to_string(), state);
        self
    }

    pub fn get(&self, spec: &str) -> SpecState {
        self.specs.get(spec).cloned().unwrap_or_default()
    }

    pub fn spec_ids(&self) -> impl Iterator<Item = &str> {
        self.specs.keys().map(|s| s.as_str())
    }
}

impl PartialOrd for ProjectState {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        use std::cmp::Ordering;
        let ids: BTreeSet<String> = self
            .specs
            .keys()
            .chain(other.specs.keys())
            .cloned()
            .collect();
        let mut saw_less = false;
        let mut saw_greater = false;
        for id in ids {
            // An absent spec is the empty SpecState, whose every obligation is
            // Absent — the same bottom-alignment SpecState::get applies.
            match self.get(&id).partial_cmp(&other.get(&id)) {
                Some(Ordering::Less) => saw_less = true,
                Some(Ordering::Greater) => saw_greater = true,
                Some(Ordering::Equal) => {}
                // A single incomparable component makes the product
                // incomparable. Treating it as Equal would be the totalising
                // failure described on SpecState's impl.
                None => return None,
            }
            if saw_less && saw_greater {
                return None;
            }
        }
        match (saw_less, saw_greater) {
            (false, false) => Some(Ordering::Equal),
            (true, false) => Some(Ordering::Less),
            (false, true) => Some(Ordering::Greater),
            (true, true) => unreachable!("returned above"),
        }
    }
}

/// One validator's contribution to refinement: if `applies` holds of the current
/// state, `id` is raised to at least `to`.
///
/// WHY A PREDICATE RATHER THAN A FIXED EVIDENCE MAP, and this is the design
/// decision rung 2 depends on. `refine(s) = s ⊔ fixed_evidence` would be
/// monotone, inflationary and idempotent BY CONSTRUCTION, and every property in
/// rung 2 would hold trivially — a paper model with a passing test suite, which
/// is exactly the failure 976-kk6x was filed to avoid.
///
/// Real validators are conditional: a trace check that only runs once a
/// requirement is declared, a bundling step gated on a test having run. Those
/// conditions are where monotonicity can genuinely fail, so the operator has to
/// be able to express them. Whether the rules the fleet actually uses ARE
/// monotone is rung 2's question, and a NO there is a finding about the
/// methodology's claim rather than a bug in the test.
#[derive(Debug, Clone)]
pub struct Rule {
    pub id: String,
    pub to: ObligationState,
    pub applies: fn(&SpecState) -> bool,
}

impl Rule {
    pub fn new(id: &str, to: ObligationState, applies: fn(&SpecState) -> bool) -> Self {
        Rule {
            id: id.to_string(),
            to,
            applies,
        }
    }

    /// A rule that fires unconditionally — the monotone, inflationary base case.
    pub fn always(id: &str, to: ObligationState) -> Self {
        Rule::new(id, to, |_| true)
    }
}

/// The refinement operator over a finite snapshot of rules.
///
/// Each rule that applies raises its obligation to at least its target; a rule
/// never lowers one, so `refine` is inflationary by construction on the
/// component it touches. It is NOT monotone by construction, because a rule's
/// predicate may be non-monotone — which is the point (see [`Rule`]).
///
/// Applied to fixpoint with a bound, so a non-inflationary rule set cannot spin
/// forever. The bound is a REFUSAL, not a silent stop: a caller that hits it has
/// a rule set the methodology's convergence claim does not cover, and hiding
/// that behind a truncated answer would be the same defect as a check that
/// cannot fail.
#[derive(Debug, Clone, Default)]
pub struct Refiner {
    rules: Vec<Rule>,
}

/// How [`Refiner::refine`] terminated.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefineOutcome {
    /// Reached a fixed point in `steps` applications.
    Fixed { steps: usize },
    /// Hit the iteration bound without stabilising. The state is the last one
    /// computed and MUST NOT be treated as a fixed point.
    Unstable { bound: usize },
}

impl Refiner {
    pub fn new(rules: Vec<Rule>) -> Self {
        Refiner { rules }
    }

    /// One application of every rule.
    pub fn step(&self, state: &SpecState) -> SpecState {
        let mut next = state.clone();
        for rule in &self.rules {
            if (rule.applies)(state) {
                let current = next.get(&rule.id);
                if rule.to > current {
                    next.set(&rule.id, rule.to);
                }
            }
        }
        next
    }

    /// Iterate [`Refiner::step`] to a fixed point, bounded.
    pub fn refine(&self, state: &SpecState) -> (SpecState, RefineOutcome) {
        const BOUND: usize = 64;
        let mut current = state.clone();
        for step in 0..BOUND {
            let next = self.step(&current);
            if next == current {
                return (current, RefineOutcome::Fixed { steps: step });
            }
            current = next;
        }
        (current, RefineOutcome::Unstable { bound: BOUND })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// THE DEFECT THIS RUNG WAS REOPENED FOR. Before the tombstone domain, an
    /// id that was tombstoned and replaced vanished from the map, `get`
    /// returned `Absent`, and the pair compared as a REGRESSION — which rung 2
    /// would have reported as a monotonicity violation against
    /// `math.fixpoint.convergence-target@v1`. A false finding about the
    /// methodology's own claim, manufactured by key handling.
    #[test]
    fn tombstoned_id_is_not_a_regression() {
        use std::cmp::Ordering;
        let before = SpecState::new()
            .with("req-old", ObligationState::RuntimeObserved)
            .with("req-keep", ObligationState::Traced);

        // The requirement's MEANING changed: tombstone + a new id, per
        // methodology/proximity.yaml:47.
        let mut after = SpecState::new()
            .with("req-keep", ObligationState::Traced)
            .with("req-new", ObligationState::Absent);
        after.tombstone("req-old");

        // NOT Less. The obligation ceased to exist; it did not lose evidence.
        assert_eq!(before.partial_cmp(&after), Some(Ordering::Equal));
        assert!(after.is_tombstoned("req-old"));
    }

    /// NO CARRY, and this is the decided half rather than the convenient one.
    /// The successor starts at the bottom because it is a DIFFERENT obligation
    /// — evidence for the old meaning is not evidence for the new one. Carrying
    /// would launder a score across exactly the break the operator's rule marks.
    #[test]
    fn successor_starts_absent_with_no_carry() {
        let mut s = SpecState::new().with("req-old", ObligationState::EvidenceBundled);
        s.tombstone("req-old");
        s.set("req-new", ObligationState::Absent);
        assert_eq!(s.get("req-new"), ObligationState::Absent);
    }

    /// A REFINEMENT keeps its identifier, so the state travels with the key and
    /// this case was never at risk. Pinned as the negative control: a "fix"
    /// that tombstoned on every edit would break it.
    #[test]
    fn refinement_keeps_the_identifier_and_the_state() {
        use std::cmp::Ordering;
        let before = SpecState::new().with("req-a", ObligationState::Traced);
        let after = SpecState::new().with("req-a", ObligationState::RuntimeObserved);
        assert_eq!(before.partial_cmp(&after), Some(Ordering::Less));
    }

    /// A never-recorded id is still `Absent` and still IN the domain. The
    /// tombstone exclusion must not swallow the ordinary bottom case, or
    /// differing id sets would stop comparing at all.
    #[test]
    fn never_recorded_is_still_bottom_in_domain() {
        use std::cmp::Ordering;
        let fewer = SpecState::new().with("x", ObligationState::Traced);
        let more = SpecState::new()
            .with("x", ObligationState::Traced)
            .with("y", ObligationState::Declared);
        assert_eq!(fewer.partial_cmp(&more), Some(Ordering::Less));
        assert!(!fewer.is_tombstoned("y"));
    }

    /// The chain is the one the methodology declares, in that sequence. Asserted
    /// against the literal spellings rather than against ALL's own order, so a
    /// reordering of the enum fails here instead of silently redefining the
    /// lattice.
    #[test]
    fn chain_matches_methodology_order() {
        let spelled: Vec<&str> = ObligationState::ALL.iter().map(|s| s.as_str()).collect();
        assert_eq!(
            spelled,
            vec![
                "absent",
                "declared",
                "traced",
                "positively_tested",
                "negatively_tested",
                "runtime_observed",
                "evidence_bundled",
            ]
        );
        for pair in ObligationState::ALL.windows(2) {
            assert!(
                pair[0] < pair[1],
                "{:?} must precede {:?}",
                pair[0],
                pair[1]
            );
        }
    }

    #[test]
    fn obligation_states_are_a_total_order() {
        for a in ObligationState::ALL {
            for b in ObligationState::ALL {
                assert!(
                    a.partial_cmp(&b).is_some(),
                    "the chain must be total: {a:?} vs {b:?}"
                );
            }
        }
    }

    #[test]
    fn absent_key_reads_as_bottom() {
        let s = SpecState::new().with("a", ObligationState::Traced);
        assert_eq!(s.get("never-heard-of-it"), ObligationState::Absent);
    }

    /// THE CASE THE WHOLE MODEL EXISTS FOR. Two spec states, each stronger on a
    /// different obligation, must be INCOMPARABLE — not equal, not less. If this
    /// ever returns `Some`, rung 2's monotonicity property becomes vacuous,
    /// because no pair could witness a violation.
    #[test]
    fn opposite_directions_are_incomparable() {
        let a = SpecState::new()
            .with("x", ObligationState::RuntimeObserved)
            .with("y", ObligationState::Declared);
        let b = SpecState::new()
            .with("x", ObligationState::Declared)
            .with("y", ObligationState::RuntimeObserved);
        assert_eq!(a.partial_cmp(&b), None);
        assert_eq!(b.partial_cmp(&a), None);
        // Deliberately NOT `assert!(!(a <= b))`. Clippy refuses that form on a
        // partially ordered type, and its reasoning is this test's whole
        // subject: `!(a <= b)` reads as "a is greater" and actually means "a is
        // greater OR the two cannot be compared". Asserting on partial_cmp
        // keeps the third possibility visible, which is the one that exists
        // here.
        assert!(a.partial_cmp(&b).is_none());
    }

    #[test]
    fn componentwise_order_holds_when_all_components_agree() {
        use std::cmp::Ordering;
        let lo = SpecState::new()
            .with("x", ObligationState::Declared)
            .with("y", ObligationState::Absent);
        let hi = SpecState::new()
            .with("x", ObligationState::RuntimeObserved)
            .with("y", ObligationState::Traced);
        assert_eq!(lo.partial_cmp(&hi), Some(Ordering::Less));
        assert_eq!(hi.partial_cmp(&lo), Some(Ordering::Greater));
        assert_eq!(lo.partial_cmp(&lo.clone()), Some(Ordering::Equal));
    }

    /// Differing ID SETS still align, because an absent key is Absent. Comparing
    /// only the intersection would call these equal.
    #[test]
    fn differing_id_sets_align_through_bottom() {
        use std::cmp::Ordering;
        let fewer = SpecState::new().with("x", ObligationState::Traced);
        let more = SpecState::new()
            .with("x", ObligationState::Traced)
            .with("y", ObligationState::Declared);
        assert_eq!(fewer.partial_cmp(&more), Some(Ordering::Less));
    }

    #[test]
    fn project_state_inherits_incomparability_from_one_spec() {
        let a = ProjectState::new().with(
            "s1",
            SpecState::new()
                .with("x", ObligationState::RuntimeObserved)
                .with("y", ObligationState::Declared),
        );
        let b = ProjectState::new().with(
            "s1",
            SpecState::new()
                .with("x", ObligationState::Declared)
                .with("y", ObligationState::RuntimeObserved),
        );
        assert_eq!(a.partial_cmp(&b), None);
    }

    #[test]
    fn refine_raises_and_stabilises() {
        let r = Refiner::new(vec![
            Rule::always("x", ObligationState::Declared),
            // Conditional: only traceable once declared. This is the shape that
            // makes monotonicity a real question rather than a construction.
            Rule::new("x", ObligationState::Traced, |s| {
                s.get("x") >= ObligationState::Declared
            }),
        ]);
        let (out, outcome) = r.refine(&SpecState::new());
        assert_eq!(out.get("x"), ObligationState::Traced);
        assert!(matches!(outcome, RefineOutcome::Fixed { .. }));
    }

    /// refine never lowers a component, so its output is always >= its input.
    /// Rung 2 asserts this as a property; here it is a worked case so rung 1 is
    /// self-contained.
    #[test]
    fn refine_is_inflationary_on_a_worked_case() {
        let r = Refiner::new(vec![Rule::always("x", ObligationState::Declared)]);
        let start = SpecState::new().with("x", ObligationState::RuntimeObserved);
        let (out, _) = r.refine(&start);
        assert!(start <= out);
        // and it did NOT lower the already-stronger state
        assert_eq!(out.get("x"), ObligationState::RuntimeObserved);
    }

    /// The bound REFUSES rather than pretending. No rule set here can oscillate
    /// (rules only raise, the chain is finite), so this asserts the refusal
    /// exists and is reachable in principle by constructing the outcome value —
    /// a caller must be able to tell "stabilised" from "gave up".
    #[test]
    fn unstable_outcome_is_distinguishable_from_fixed() {
        assert_ne!(
            RefineOutcome::Fixed { steps: 3 },
            RefineOutcome::Unstable { bound: 64 }
        );
    }
}

// ── ORDER 977-j6qu (rung 3): the ranking function ────────────────────────────

/// A score over a [`SpecState`]: what was EARNED, out of what was possible, and
/// what remains.
///
/// The three travel together because the methodology requires the denominator
/// and residual to be reported SEPARATELY (math-foundations.yaml:37-42) — a
/// single "score" hides whether 40 means "40 of 50" or "40 of 4000", and a
/// percentage hides both. `local-ci.sh` already had this shape and it was the
/// half it got right.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Score {
    pub earned: u64,
    pub denominator: u64,
    pub residual: u64,
    /// Whether this score may be compared with another (see [`Regime`]).
    pub regime: Regime,
}

/// Whether a score is inside the band where the methodology says the ranking
/// function is monotone.
///
/// math-foundations.yaml:37-42 qualifies `centicolon_function` explicitly: it
/// "is monotone only for evidence transitions that preserve obligation IDs and
/// do not introduce penalties, ambiguity, or denominator scope changes". A
/// scorer that reports a number without saying which side of that line it is on
/// invites exactly the comparison the qualifier forbids — and a reader has no
/// way to know, because both sides look like a number.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Regime {
    /// Obligation IDs preserved and the denominator unchanged: this score is
    /// comparable with the previous one.
    Monotone,
    /// Outside the band, with the reason NAMED rather than implied. A consumer
    /// must not read a rise or fall across this boundary as progress or
    /// regress.
    Broken(&'static str),
}

/// The weight of each obligation, and the state at which it counts as earned.
///
/// `earned_at` exists because a binary check cannot witness the whole chain: a
/// CI check that passes establishes `PositivelyTested` and says nothing about
/// `RuntimeObserved` or `EvidenceBundled`. Making the bar explicit per
/// obligation keeps that honest instead of quietly treating "the check passed"
/// as "every kind of evidence exists".
#[derive(Debug, Clone)]
pub struct Weights {
    weights: BTreeMap<String, (u64, ObligationState)>,
}

impl Default for Weights {
    fn default() -> Self {
        Self::new()
    }
}

impl Weights {
    pub fn new() -> Self {
        Weights {
            weights: BTreeMap::new(),
        }
    }

    pub fn with(mut self, id: &str, weight: u64, earned_at: ObligationState) -> Self {
        self.weights.insert(id.to_string(), (weight, earned_at));
        self
    }

    pub fn ids(&self) -> impl Iterator<Item = &str> {
        self.weights.keys().map(|s| s.as_str())
    }
}

/// The ranking function: sum the weights of obligations that reached their bar.
///
/// TOMBSTONED OBLIGATIONS ARE EXCLUDED FROM BOTH HALVES — they leave the
/// numerator AND the denominator. Dropping them from the numerator alone would
/// make a legitimate identity change look like lost ground, which is the
/// 977-56fd defect one layer up; leaving them in the denominator would make the
/// project permanently unable to reach its own total. Excluding them from both
/// is a DENOMINATOR SCOPE CHANGE, which the methodology names as leaving the
/// monotone band — so the returned [`Regime`] says so rather than letting a
/// consumer compare across it silently.
pub fn centicolon_function(state: &SpecState, weights: &Weights) -> Score {
    let mut earned = 0u64;
    let mut denominator = 0u64;
    let mut tombstoned_any = false;

    for (id, (weight, earned_at)) in &weights.weights {
        if state.is_tombstoned(id) {
            tombstoned_any = true;
            continue; // out of the numerator AND the denominator
        }
        denominator += weight;
        if state.get(id) >= *earned_at {
            earned += weight;
        }
    }

    let regime = if tombstoned_any {
        Regime::Broken("denominator scope changed: an obligation was tombstoned")
    } else {
        Regime::Monotone
    };

    Score {
        earned,
        denominator,
        residual: denominator.saturating_sub(earned),
        regime,
    }
}

#[cfg(test)]
mod score_tests {
    use super::*;

    fn weights() -> Weights {
        Weights::new()
            .with("a", 100, ObligationState::PositivelyTested)
            .with("b", 60, ObligationState::PositivelyTested)
    }

    #[test]
    fn earned_denominator_and_residual_are_separate_and_consistent() {
        let s = SpecState::new()
            .with("a", ObligationState::PositivelyTested)
            .with("b", ObligationState::Declared);
        let score = centicolon_function(&s, &weights());
        assert_eq!(score.earned, 100);
        assert_eq!(score.denominator, 160);
        assert_eq!(score.residual, 60);
        assert_eq!(score.regime, Regime::Monotone);
    }

    /// A state ABOVE the bar still earns — the bar is a threshold, not an
    /// equality. An equality here is the exact defect rung 2's wrong-model
    /// fixture encodes.
    #[test]
    fn exceeding_the_bar_still_earns() {
        let s = SpecState::new()
            .with("a", ObligationState::EvidenceBundled)
            .with("b", ObligationState::RuntimeObserved);
        let score = centicolon_function(&s, &weights());
        assert_eq!(score.earned, 160);
        assert_eq!(score.residual, 0);
    }

    /// THE REGIME IS NAMED, NOT IMPLIED. A tombstone changes the denominator,
    /// which the methodology says leaves the monotone band, so the score must
    /// say so rather than presenting a comparable-looking number.
    #[test]
    fn a_tombstone_leaves_the_monotone_regime_and_says_so() {
        let mut s = SpecState::new().with("a", ObligationState::PositivelyTested);
        s.tombstone("b");
        let score = centicolon_function(&s, &weights());
        assert_eq!(score.earned, 100);
        assert_eq!(
            score.denominator, 100,
            "tombstoned weight leaves the denominator too"
        );
        assert!(matches!(score.regime, Regime::Broken(_)));
    }

    /// The score rises with evidence, within the regime — the property the
    /// methodology's qualifier actually promises.
    #[test]
    fn score_is_monotone_within_the_regime() {
        let lo = SpecState::new()
            .with("a", ObligationState::Declared)
            .with("b", ObligationState::Declared);
        let hi = SpecState::new()
            .with("a", ObligationState::PositivelyTested)
            .with("b", ObligationState::Declared);
        assert!(lo <= hi);
        let (a, b) = (
            centicolon_function(&lo, &weights()),
            centicolon_function(&hi, &weights()),
        );
        assert!(a.earned <= b.earned);
        assert_eq!(a.denominator, b.denominator);
    }

    /// An obligation with no recorded state is Absent and earns nothing, but
    /// still counts toward the denominator — otherwise a project could raise
    /// its percentage by forgetting to record obligations.
    #[test]
    fn unrecorded_obligations_still_count_against_the_total() {
        let score = centicolon_function(&SpecState::new(), &weights());
        assert_eq!(score.earned, 0);
        assert_eq!(score.denominator, 160);
    }
}
