//! ORDER 718-jqt5 — the deterministic `forgotten` projection, SHARED.
//!
//! Criterion 1 delivered this computation, but it lived inside `main.rs`'s CLI
//! arm where the library could not reach it. Criterion 2 asks that
//! story-shaped questions "route through it", and a question answered by
//! `answer_question` is answered in the LIBRARY — so the projection had to
//! become reachable before the routing could be honest.
//!
//! IT IS EXTRACTED, NOT REIMPLEMENTED, and that distinction is criterion 4.
//! The negative control asks that the same seed yield the same set; a second
//! copy of this logic living next to the first would satisfy that control on
//! the day it was written and drift silently afterwards, which is the failure
//! this fleet keeps paying for. One definition, two callers.
//!
//! The status filter is the only part of `query_packets` this needs
//! (`Some("ready")`, every other parameter `None`/empty/unlimited), and it is
//! character-identical to that function's own status arm:
//! `str_field(p, "status") == Some(s)`. Moving the whole 107-line helper —
//! whose role and claimability semantics carry three orders' worth of rulings
//! this projection never consults — would have been a larger change with more
//! to get wrong.

use crate::{Ledger, str_field};

/// ORDER 718-jqt5. One `forgotten` row: (age_days, order_num, blocking,
/// order, packet_id, leased).
pub type ForgottenRow = (Option<i64>, i64, usize, String, String, bool);

/// The TOTAL ORDER for `forgotten`, split out so it can be tested without a
/// ledger — the same reason `child_env_with_home` and `expire_claim_candidates`
/// are split out.
///
/// Determinism is the point, and it is stronger than the packet's criterion
/// asked for. 718-jqt5's negative control says "the same seed yields the same
/// set". This projection takes NO seed: the order is total, so the same ledger
/// yields the same list on every host and every run, and reproducibility does
/// not depend on remembering to record a seed. A seed belongs to the SAMPLING
/// layer above this (which epics to spread across), not to the projection.
///
/// The rules, in order:
///   1. eventless packets first — nothing has ever happened to them;
///   2. within those, LOWEST ORDER first: `next-order` mints monotonically
///      (581-k3f9), so a lower number was filed longer ago;
///   3. within evented packets, GREATEST age first;
///   4. then fewest dependents, because a leaf is what a residual-maximising
///      selector never reaches;
///   5. then packet_id — never insertion order, which is fragment order and
///      therefore differs between hosts.
pub fn forgotten_sort(rows: &mut [ForgottenRow]) {
    rows.sort_by(|a, b| {
        let bucket = |r: &ForgottenRow| if r.0.is_none() { 0u8 } else { 1u8 };
        bucket(a)
            .cmp(&bucket(b))
            .then_with(|| match (a.0, b.0) {
                (None, None) => a.1.cmp(&b.1),
                (Some(x), Some(y)) => y.cmp(&x),
                _ => std::cmp::Ordering::Equal,
            })
            .then(a.2.cmp(&b.2))
            .then(a.4.cmp(&b.4))
    });
}

/// Every ready packet's dependents, counted over the same edge set
/// `blocking-counts` uses.
fn dependents_of(ledger: &Ledger) -> std::collections::BTreeMap<String, usize> {
    let mut dependents: std::collections::BTreeMap<String, usize> =
        std::collections::BTreeMap::new();
    for p in ledger
        .packets
        .iter()
        .filter(|p| str_field(p, "status") == Some("ready"))
    {
        if let Some(deps) = p.get("depends_on").and_then(serde_yaml::Value::as_sequence) {
            for d in deps {
                let key = match d {
                    serde_yaml::Value::String(s) => s.clone(),
                    serde_yaml::Value::Number(n) => n.to_string(),
                    _ => continue,
                };
                *dependents.entry(key).or_insert(0) += 1;
            }
        }
    }
    dependents
}

/// The projection itself: sorted, unlimited. Callers apply their own limit,
/// because the CLI truncates for display while the envelope surface needs the
/// full set to say how many it did not show.
pub fn forgotten_rows(ledger: &Ledger, now: i64, min_age_days: i64) -> Vec<ForgottenRow> {
    let dependents = dependents_of(ledger);
    let mut rows: Vec<ForgottenRow> = Vec::new();

    for p in ledger
        .packets
        .iter()
        .filter(|p| str_field(p, "status") == Some("ready"))
    {
        let id = ledger.id_of(p);
        let order = p
            .get("order")
            .map(|o| match o {
                serde_yaml::Value::Number(n) => n.to_string(),
                serde_yaml::Value::String(s) => s.clone(),
                _ => "?".to_string(),
            })
            .unwrap_or_else(|| "?".to_string());

        // MILESTONES ARE CONTAINERS, NOT FORGOTTEN WORK. A milestone holds
        // criteria and is never claimed for implementation
        // (ambitious_milestone_reduction.milestone_packet_semantics); its
        // children are. MEASURED: 15 ready milestones would otherwise sit in
        // this list, and every one is a row a reader must learn to skip.
        if p.get("kind").and_then(serde_yaml::Value::as_str) == Some("milestone") {
            continue;
        }

        let mut newest: Option<i64> = None;
        let mut leased = false;
        if let Some(evs) = p.get("events").and_then(serde_yaml::Value::as_sequence) {
            for ev in evs {
                if let Some(ts) = ev.get("ts").and_then(serde_yaml::Value::as_str)
                    && let Some(e) = crate::answer::iso8601_to_epoch(ts)
                    && newest.is_none_or(|cur| e > cur)
                {
                    newest = Some(e);
                }
                if ev.get("type").and_then(serde_yaml::Value::as_str) == Some("claim") {
                    leased = true;
                }
                // The claim CONVENTION is a note whose summary says so
                // (943-unii): a `claim` type is the audit record, and plenty of
                // real claims are notes. Both count as "someone has had hands
                // on this".
                if let Some(sum) = ev.get("summary").and_then(serde_yaml::Value::as_str)
                    && sum.contains("claimed for cycle")
                {
                    leased = true;
                }
            }
        }

        // RE-MEASURED 2026-09-17, and the earlier figure has INVERTED. This
        // comment read "461 of 461 ready packets carry NO events at all, so
        // age is undefined for essentially the whole ledger" (measured
        // 2026-09-06). Eleven days later: 505 rows, 139 eventless, 366
        // EVENTED. Age is now the majority signal, not the absent one. I
        // moved this comment into the library verbatim on 2026-09-16 without
        // re-running it, which is how a measured claim becomes a stale one.
        //
        // The ORDER TOKEN still carries the signal for the eventless 139:
        // next-order mints monotonically (581-k3f9), so a lower order number
        // is a packet filed longer ago, and those are ranked oldest-first by
        // order.
        //
        // WHAT THE INVERSION COSTS, and it is criterion 4's whole subject:
        // 366 of 505 rows are now ranked by a value derived from `now`, so
        // the ordering is CLOCK-DEPENDENT for the majority of the list. Two
        // hosts asking the same question at different times can legitimately
        // differ. That is why callers must be able to pin `now` and why the
        // answer surface states the epoch it used — reproducible is not the
        // same as auditable, and the criterion asks for both.
        let age_days = newest.map(|e| (now - e) / 86_400);
        let order_num: i64 = order
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>()
            .parse()
            .unwrap_or(i64::MAX);
        let blocking = dependents.get(&id).copied().unwrap_or(0);

        // --min-age-days filters on a MEASURED age; an eventless packet has no
        // age to compare, and dropping it would hide the most-forgotten rows
        // behind a flag meant to narrow the list.
        if let Some(a) = age_days
            && a < min_age_days
        {
            continue;
        }
        rows.push((age_days, order_num, blocking, order, id, leased));
    }

    forgotten_sort(&mut rows);
    rows
}

#[cfg(test)]
mod tests {
    use super::{ForgottenRow, forgotten_sort};

    fn row(age: Option<i64>, order: i64, blocking: usize, id: &str) -> ForgottenRow {
        (
            age,
            order,
            blocking,
            order.to_string(),
            id.to_string(),
            false,
        )
    }

    /// ORDER 718-jqt5 criterion 1. Eventless packets come FIRST — nothing has
    /// ever happened to them — and within that bucket the LOWEST order wins,
    /// because next-order mints monotonically so a lower number was filed
    /// longer ago (581-k3f9).
    #[test]
    fn forgotten_puts_eventless_packets_first_oldest_order_first() {
        let mut rows = vec![
            row(Some(3), 900, 0, "recent-event"),
            row(None, 1085, 0, "new-and-untouched"),
            row(None, 151, 0, "ancient-and-untouched"),
        ];
        forgotten_sort(&mut rows);
        let ids: Vec<&str> = rows.iter().map(|r| r.4.as_str()).collect();
        assert_eq!(
            ids,
            vec!["ancient-and-untouched", "new-and-untouched", "recent-event"]
        );
    }

    /// Among packets that DO have events, the stalest ranks first. Without this
    /// the bucket rule above could be satisfied by ignoring age entirely.
    #[test]
    fn forgotten_ranks_evented_packets_by_descending_age() {
        let mut rows = vec![
            row(Some(2), 100, 0, "fresh"),
            row(Some(90), 900, 0, "stale"),
            row(Some(30), 500, 0, "middling"),
        ];
        forgotten_sort(&mut rows);
        let ids: Vec<&str> = rows.iter().map(|r| r.4.as_str()).collect();
        assert_eq!(ids, vec!["stale", "middling", "fresh"]);
    }

    /// A LEAF is what a residual-maximising selector never reaches: the epic
    /// score weights `blocking` at 1.5, so a packet nothing depends on barely
    /// moves its epic and is never the reason one wins. Fewest dependents
    /// first, at equal age.
    #[test]
    fn forgotten_prefers_the_leaf_at_equal_age() {
        let mut rows = vec![
            row(None, 200, 7, "blocks-many"),
            row(None, 200, 0, "blocks-nothing"),
        ];
        forgotten_sort(&mut rows);
        assert_eq!(rows[0].4, "blocks-nothing");
    }

    /// THE NEGATIVE CONTROL 718-jqt5 ASKS FOR, and it is stronger than the
    /// criterion. The criterion says "the same seed yields the same set"; this
    /// projection takes no seed, so the order is total and the same input
    /// yields the same output regardless of how it arrived. Shuffling the input
    /// must change nothing — which is what rules out insertion order (fragment
    /// order, and therefore host-dependent) leaking into the ranking.
    #[test]
    fn forgotten_is_reproducible_without_a_seed() {
        let build = || {
            vec![
                row(None, 500, 1, "e"),
                row(Some(10), 100, 0, "a"),
                row(None, 200, 0, "c"),
                row(Some(10), 900, 0, "b"),
                row(None, 200, 3, "d"),
            ]
        };
        let mut first = build();
        forgotten_sort(&mut first);

        let mut shuffled = build();
        shuffled.reverse();
        forgotten_sort(&mut shuffled);
        assert_eq!(first, shuffled, "input order must not reach the ranking");

        let mut rotated = build();
        rotated.rotate_left(3);
        forgotten_sort(&mut rotated);
        assert_eq!(first, rotated);
    }
    /// Equal age AND equal blocking must still be a total order, or two hosts
    /// can print the same set in different sequences and a batch stops being
    /// replayable.
    #[test]
    fn forgotten_breaks_full_ties_on_packet_id() {
        let mut rows = vec![row(None, 300, 0, "zeta"), row(None, 300, 0, "alpha")];
        forgotten_sort(&mut rows);
        assert_eq!(rows[0].4, "alpha");
    }

    /// ORDER 718-jqt5 CRITERION 4, the negative control, pinned against the
    /// LIVE ledger rather than synthetic rows — because the property that
    /// matters is about real data and the synthetic test one screen up cannot
    /// see it.
    ///
    /// THE CRITERION ASKS FOR REPRODUCIBLE AND AUDITABLE. Reproducibility
    /// within one process is trivial and proves nothing; the question is
    /// whether ANOTHER host, with a different clock, gets the same set.
    ///
    /// MEASURED 2026-09-17, and it inverted the assumption this module was
    /// written under: 505 rows, 139 eventless and 366 EVENTED, so `now` feeds
    /// the ranking of 72% of the list — where criterion 1's comment had said
    /// "461 of 461 carry no events" and concluded the clock barely mattered.
    ///
    /// The ordering survives anyway, and the reason is worth stating because
    /// it is not obvious: `age_days` is `(now - event) / 86_400` for every
    /// row, so a UNIFORM shift in `now` moves every age by the same amount and
    /// preserves their relative order. The clock changes what is DISPLAYED,
    /// not what is RANKED. It can only reorder at a day boundary, where
    /// integer division makes two ages equal or unequal — and those fall
    /// through to the blocking/packet_id tiebreak, which is total.
    ///
    /// So this asserts the invariance directly, across a 40-day shift.
    #[test]
    fn the_ranking_is_invariant_under_a_uniform_clock_shift() {
        let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
        let Ok(ledger) = crate::Ledger::load(&root.join("plan/index.yaml")) else {
            return; // no live ledger in this checkout; nothing to assert
        };
        let base = 1_789_660_377i64;
        let ids = |now: i64| -> Vec<String> {
            crate::forgotten::forgotten_rows(&ledger, now, 0)
                .into_iter()
                .map(|(_, _, _, _, id, _)| id)
                .collect()
        };

        let at_base = ids(base);
        assert!(
            at_base.len() > 100,
            "the live ledger should yield a substantial list; got {}",
            at_base.len()
        );

        // Same clock, twice: the function must be pure.
        assert_eq!(at_base, ids(base), "same inputs must give the same set");

        // Different clock, 40 days on: the ORDER must not move.
        assert_eq!(
            at_base,
            ids(base + 86_400 * 40),
            "a uniform clock shift changed the ranking — two hosts would \
             disagree about what is forgotten, and the answer surface's \
             stated now-epoch would stop being a reproducible handle"
        );
    }
}
