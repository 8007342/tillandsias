//! Order 977-dpbj (rung 2 of 976-kk6x) — properties over the obligation
//! lattice, written so they CAN fail.
//!
//! # Why this rung is the risky one
//!
//! **The methodology's own validation is strictly weaker than its citation.**
//! `math.fixpoint.convergence-target@v1` (methodology/math-foundations.yaml:61)
//! cites `tarski_1955` and `kleene_1952` and validates with
//! `refine(refine(state)) == refine(state)`. Knaster-Tarski needs MONOTONE; the
//! constructive finite-stabilisation argument needs MONOTONE AND INFLATIONARY.
//! Idempotence implies neither.
//!
//! And it is not an arbitrary choice, which is what makes it survive review:
//! idempotence DOES deliver stabilisation, trivially in one step, because if
//! `refine∘refine = refine` then every point of the image is a fixed point. What
//! it does not deliver is anything order-theoretic — not that the fixed point is
//! LEAST, not that it is reached from below, not that `refine` respects the
//! product order. The check tests the CONCLUSION's shape while the citations are
//! load-bearing for the hypothesis.
//!
//! # The vacuity trap, which is the reason the generators are hand-built
//!
//! Monotonicity is `x <= y => refine(x) <= refine(y)`. On a PRODUCT order most
//! independently drawn pairs are INCOMPARABLE, so a naive generator has its
//! precondition fail, the case is discarded, and the property passes having
//! tested almost nothing — while proptest cheerfully reports thousands of
//! successes. [`comparable_pair`] therefore builds `y` UPWARD FROM `x`, and
//! [`monotonicity_sample_is_not_empty`] asserts on the count so a generator that
//! stops producing comparable pairs fails loudly instead of passing silently.
//!
//! # A wrong model is committed so the suite proves it can fail
//!
//! Properties over a model their own author just wrote are the easiest
//! tautology to produce. [`NON_MONOTONE_RULES`] is a deliberately wrong rule set
//! and [`the_suite_rejects_a_deliberately_wrong_model`] asserts the monotonicity
//! check REJECTS it. If that test ever passes vacuously, the whole rung is
//! decoration.

use crate::obligation::{ObligationState, Refiner, Rule, SpecState};

/// Obligation ids the generators draw from. Small and fixed: a product order
/// over three components already exhibits incomparability, and a small domain
/// makes shrunk counterexamples readable.
pub const IDS: [&str; 3] = ["req-a", "req-b", "req-c"];

/// A rule set that IS monotone and inflationary: every predicate is upward
/// closed (`>=` on a chain), so raising an input can only keep a predicate true.
pub fn monotone_rules() -> Refiner {
    Refiner::new(vec![
        Rule::always("req-a", ObligationState::Declared),
        Rule::new("req-b", ObligationState::Traced, |s| {
            s.get("req-a") >= ObligationState::Declared
        }),
        Rule::new("req-c", ObligationState::PositivelyTested, |s| {
            s.get("req-b") >= ObligationState::Traced
        }),
    ])
}

/// THE DELIBERATELY WRONG MODEL, committed as a fixture.
///
/// The predicate is an EQUALITY, not a threshold — `== Declared` is not upward
/// closed, so raising `req-a` from `Declared` to `Traced` makes the rule stop
/// firing and `req-b` comes out LOWER for a HIGHER input. That is a genuine
/// monotonicity violation and it is exactly the shape a real validator acquires
/// by accident ("only run this check when the requirement is newly declared").
///
/// Its purpose is to fail. [`the_suite_rejects_a_deliberately_wrong_model`]
/// asserts a counterexample is found; if that test starts passing without one,
/// the properties have gone vacuous and every green in this file is worthless.
pub fn non_monotone_rules() -> Refiner {
    Refiner::new(vec![Rule::new(
        "req-b",
        ObligationState::RuntimeObserved,
        |s| s.get("req-a") == ObligationState::Declared,
    )])
}

/// Search for a monotonicity counterexample by exhaustive enumeration over a
/// bounded domain.
///
/// Exhaustive rather than random for the WRONG-MODEL check specifically: a
/// fixture whose whole job is to fail must fail deterministically, not with
/// probability depending on a seed. proptest covers the real model below.
pub fn find_monotonicity_counterexample(r: &Refiner) -> Option<(SpecState, SpecState)> {
    let states = enumerate_states();
    for x in &states {
        for y in &states {
            if x.partial_cmp(y) != Some(std::cmp::Ordering::Less) {
                continue;
            }
            let (rx, _) = r.refine(x);
            let (ry, _) = r.refine(y);
            if !matches!(
                rx.partial_cmp(&ry),
                Some(std::cmp::Ordering::Less) | Some(std::cmp::Ordering::Equal)
            ) {
                return Some((x.clone(), y.clone()));
            }
        }
    }
    None
}

/// Every state over [`IDS`] restricted to the first three chain values — 27
/// states. Small enough to enumerate, large enough to contain incomparable
/// pairs and to witness the non-monotone rule set's failure.
fn enumerate_states() -> Vec<SpecState> {
    let vals = [
        ObligationState::Absent,
        ObligationState::Declared,
        ObligationState::Traced,
    ];
    let mut out = Vec::new();
    for a in vals {
        for b in vals {
            for c in vals {
                out.push(
                    SpecState::new()
                        .with(IDS[0], a)
                        .with(IDS[1], b)
                        .with(IDS[2], c),
                );
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::cmp::Ordering;
    use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrd};

    fn arb_state_value() -> impl Strategy<Value = ObligationState> {
        prop::sample::select(ObligationState::ALL.to_vec())
    }

    fn arb_spec_state() -> impl Strategy<Value = SpecState> {
        proptest::collection::vec(arb_state_value(), IDS.len()).prop_map(|vals| {
            let mut s = SpecState::new();
            for (id, v) in IDS.iter().zip(vals) {
                s.set(id, v);
            }
            s
        })
    }

    /// COMPARABLE PAIRS BY CONSTRUCTION. Draw `x`, then draw a per-component
    /// non-negative increment along the chain and apply it to build `y >= x`.
    ///
    /// Drawing two independent states and filtering would discard nearly every
    /// case on a product order — the vacuity this rung exists to avoid.
    fn comparable_pair() -> impl Strategy<Value = (SpecState, SpecState)> {
        (
            arb_spec_state(),
            proptest::collection::vec(0usize..ObligationState::ALL.len(), IDS.len()),
        )
            .prop_map(|(x, bumps)| {
                let mut y = x.clone();
                for (id, bump) in IDS.iter().zip(bumps) {
                    let cur = x.get(id) as usize;
                    let raised = (cur + bump).min(ObligationState::ALL.len() - 1);
                    y.set(id, ObligationState::ALL[raised]);
                }
                (x, y)
            })
    }

    proptest! {
        /// The generator's own precondition must hold. If this fails, every
        /// property below is running on garbage.
        #[test]
        fn comparable_pair_really_is_comparable((x, y) in comparable_pair()) {
            prop_assert!(matches!(
                x.partial_cmp(&y),
                Some(Ordering::Less) | Some(Ordering::Equal)
            ));
        }

        /// MONOTONICITY over the real rule set — what Knaster-Tarski actually
        /// needs and what the methodology's idempotence check never examined.
        #[test]
        fn refine_is_monotone_on_the_real_rules((x, y) in comparable_pair()) {
            let r = monotone_rules();
            let (rx, _) = r.refine(&x);
            let (ry, _) = r.refine(&y);
            prop_assert!(
                matches!(rx.partial_cmp(&ry), Some(Ordering::Less) | Some(Ordering::Equal)),
                "refine broke the order: {:?} -> {:?} vs {:?} -> {:?}", x, rx, y, ry
            );
        }

        /// INFLATIONARY — the other hypothesis the constructive argument needs.
        /// Unary, so no comparable-pair machinery and no discard risk.
        #[test]
        fn refine_is_inflationary(x in arb_spec_state()) {
            let r = monotone_rules();
            let (rx, _) = r.refine(&x);
            prop_assert!(matches!(
                x.partial_cmp(&rx),
                Some(Ordering::Less) | Some(Ordering::Equal)
            ));
        }

        /// IDEMPOTENCE — the property the methodology DOES check. Asserted
        /// separately from the other two so a model satisfying one and failing
        /// another is distinguishable, which the single original check could
        /// not do.
        #[test]
        fn refine_is_idempotent(x in arb_spec_state()) {
            let r = monotone_rules();
            let (once, _) = r.refine(&x);
            let (twice, _) = r.refine(&once);
            prop_assert_eq!(once, twice);
        }
    }

    /// THE ANTI-VACUITY ARM. Counts how many generated pairs are STRICTLY
    /// ordered — not merely comparable, since `x == y` satisfies the
    /// precondition while testing nothing about the order.
    ///
    /// A generator that regressed to independent draws, or to always returning
    /// `y == x`, would leave every property above passing over a sample that
    /// witnesses nothing. This is the check that makes those greens mean
    /// something.
    #[test]
    fn monotonicity_sample_is_not_empty() {
        let strict = AtomicUsize::new(0);
        let total = AtomicUsize::new(0);
        let mut runner = proptest::test_runner::TestRunner::default();
        runner
            .run(&comparable_pair(), |(x, y)| {
                total.fetch_add(1, AtomicOrd::Relaxed);
                if x.partial_cmp(&y) == Some(Ordering::Less) {
                    strict.fetch_add(1, AtomicOrd::Relaxed);
                }
                Ok(())
            })
            .expect("generator run");
        let s = strict.load(AtomicOrd::Relaxed);
        let t = total.load(AtomicOrd::Relaxed);
        assert!(t > 0, "generator produced no cases at all");
        assert!(
            s * 10 >= t,
            "only {s}/{t} generated pairs were STRICTLY ordered — the monotonicity \
             property is passing over a sample that mostly witnesses nothing"
        );
    }

    /// THE SUITE PROVES IT CAN FAIL. The committed wrong model must be
    /// REJECTED. If this ever stops finding a counterexample, the properties
    /// have gone vacuous and every green above is decoration.
    #[test]
    fn the_suite_rejects_a_deliberately_wrong_model() {
        let found = find_monotonicity_counterexample(&non_monotone_rules());
        assert!(
            found.is_some(),
            "the deliberately non-monotone rule set was NOT rejected — the \
             monotonicity check cannot fail, so its passes prove nothing"
        );
    }

    /// The positive control for the arm above: the real rule set must NOT be
    /// rejected by the same search. Without this, a search that returned
    /// `Some` unconditionally would satisfy the wrong-model test.
    #[test]
    fn the_same_search_accepts_the_real_model() {
        assert!(
            find_monotonicity_counterexample(&monotone_rules()).is_none(),
            "the real rule set was rejected — either it is genuinely \
             non-monotone (a finding about the methodology's claim, report it \
             before touching refine) or the search is over-eager"
        );
    }

    /// A TOMBSTONED id must not read as a regression. Rung 1 fixed this in the
    /// model; pinned here because a generator that produced tombstones and
    /// treated them as `Absent` would report monotonicity violations that are
    /// artifacts of key handling rather than facts about the methodology.
    #[test]
    fn tombstones_do_not_manufacture_violations() {
        let before = SpecState::new().with("req-old", ObligationState::RuntimeObserved);
        let mut after = SpecState::new().with("req-new", ObligationState::Absent);
        after.tombstone("req-old");
        assert_eq!(before.partial_cmp(&after), Some(Ordering::Equal));
    }
}
