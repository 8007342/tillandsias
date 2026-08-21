#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-arrival-routing.sh — name the rows this change FILED that were not
# independently schedulable.
#
# Order 831-ezea, the ARRIVAL half. Its sibling check-carry-forward.sh asks
# whether a cycle left the rows it TOUCHED resumable; this one asks whether the
# rows it FILED should have been rows at all.
#
# THE RULE (methodology/distributed-work.yaml ->
# new_row_only_if_independently_schedulable):
#
#   A finding becomes a new ROW only if INDEPENDENTLY SCHEDULABLE: it names
#   owned_files no open row already owns, OR a different pickup_role can claim
#   it than every open row covering that scope. Otherwise it is a next_action
#   clause on that row, or an event on it.
#
# WHY IT MATTERS, with the arithmetic. Arrivals were measured at
# lambda = 2.2 + 1.80*mu (r = 0.868), so dL/dt = a + (b-1)*mu and the sign
# flips at b = 1. At b = 1.80 every extra cycle — every host added, every cycle
# shortened — fills the ready queue faster than it drains, and no non-negative
# service rate empties it. Every budget in the methodology caps SERVICE. This
# rule is the only one that touches ARRIVAL, and until this file it was PROSE:
# no checker, and the host that wrote it was measured as the largest single
# filer. Prose that only its author reads does not move b.
#
# ── WHAT THIS CAN AND CANNOT CHECK ──────────────────────────────────────────
#
# CHECKED, and it is only the FIRST disjunct of the rule:
#   owned_files  — file-scope overlap with an OPEN row. Computed by
#                  answer.rs `owned_file_owners` at `OpenRows` scope: the SAME
#                  fold `answer_next` uses to exclude claimed scopes from the
#                  selector, called at a wider scope rather than copied. The
#                  ownership computation has exactly one implementation in the
#                  crate and this gate does not add a second.
#
# CHECKED, but a strictly weaker heuristic, and labelled as its own predicate
# in every line so it can never be read as the rule itself:
#   deliverable  — normalized string EQUALITY (lowercased, punctuation
#   title          dropped, whitespace collapsed) against an OPEN row. This
#                  catches the re-filing class — the same finding written twice
#                  in the same words — and NOTHING ELSE.
#
# NOT CHECKED, and no amount of care here would change it:
#   * THE pickup_role DISJUNCT. A row that overlaps a scope is still
#     independently schedulable when a different role can claim it. Deciding
#     that needs the role compatibility lattice AND a judgement about whether
#     the roles are genuinely disjoint for this work. This gate prints BOTH
#     rows' pickup_role on every line and decides nothing. A flagged row may be
#     entirely correct on exactly this ground.
#   * WHETHER TWO ROWS ARE "REALLY" THE SAME WORK. Two packets can honestly
#     deliver into one directory. Nothing machine-checkable separates "should
#     have been a next_action on that row" from "two genuinely independent
#     slices of one subsystem". That call is the filer's, and the advisory
#     exists to make them make it, not to make it for them.
#   * ROWS FILED SOMEWHERE OTHER THAN A NEW FRAGMENT. Diff-scoped, below.
#
# ── ADVISORY, NOT A GATE — WITH THE NUMBER THAT MAKES IT ONE ────────────────
#
#   MEASURED 2026-08-21 over plan/index.yaml (1133 packets, 490 open — i.e.
#   status not in completed/verified/done/obsoleted):
#       packets carrying owned_files at all:      23/1133 = 2.0%
#       OPEN rows carrying owned_files:            3/490  = 0.6%
#       distinct owned_file paths on open rows:   13, of which CONTENDED: 0
#       OPEN rows carrying a deliverable:        429/490  = 87.6%
#       open rows in a duplicate-deliverable group: 43 in 12 groups
#       open rows in a duplicate-title group:      0
#
#   Reproduce (ruby, not python — order 63 forbids python in committed
#   automation, and the sibling advisory's header carries the known violation):
#     ruby -ryaml -e 's=YAML.safe_load(File.read("plan/index.yaml"),
#       permitted_classes:[Date,Time],aliases:true)["plan_index"]["steps"];
#       o=s.reject{|p| %w[completed verified done obsoleted].include?(p["status"].to_s)};
#       puts "#{o.count{|p| p["owned_files"]}} / #{o.size}"'
#
#   READ THE 0.6% BEFORE PROMOTING ANYTHING. The rule as written arbitrates
#   `owned_files`, and open rows almost never carry the field. A blocking gate
#   on that predicate today would be GREEN BECAUSE ITS INPUT IS EMPTY — the
#   precise "health over nothing" failure 831-ezea's own design names — and a
#   gate that is green over an empty set reads as coverage while providing
#   none. That is why the bar below is stated on FIELD COVERAGE and not on a
#   violation rate: a violation rate over 3 rows measures nothing.
#
#   The 87.6%/0.6% split is itself the finding: filers ARE declaring scope,
#   they declare it in `deliverable`, and 43 open rows already collide there
#   (mostly on directory-shaped values like "crates/tillandsias-headless/src").
#
#   PROMOTION BAR — two clauses, and only the first is promotable:
#     1. owned_files: promote to blocking — change the `exit 0` under
#        `advisory:` below to `exit 1`, update the grammar, and add an `_error`
#        branch in build.sh — when OPEN rows carrying owned_files reach >= 40%
#        by the command above (today 0.6%). Below that the predicate cannot see
#        the scope it is meant to arbitrate.
#     2. deliverable / title: NEVER PROMOTE. Normalized string equality is a
#        heuristic over free text; 43 of 490 open rows already collide under it
#        and most of those collisions are legitimate concurrent work in one
#        subsystem. Blocking on it would refuse correct filings, and 699-dycj
#        forbids making one host's habit every host's red build.
#
# ── DIFF-SCOPED BY CONSTRUCTION ─────────────────────────────────────────────
#
# Only rows NEWLY DEFINED by fragments this change ADDS versus the base ref
# (origin/linux-next, or TILLANDSIAS_ROUTING_BASE). A whole-ledger pass would
# report against 490 open rows on day one, refuse or shout at every commit, and
# be switched off within a day — and it would be shouting about append-only
# history nobody may rewrite. You file it, you hear about it. You inherit it,
# you do not.
#
# "Newly defined" is decided by the fold's `origin_source_of`, not by fragment
# text: a `packets:` entry that RE-DECLARES an existing packet is a G-Set no-op
# and is correctly NOT counted as an arrival. A sibling row born in the SAME
# change IS compared — two rows filed together over one scope is the same
# arrival defect as one filed over an inherited scope.
#
# ── GRAMMAR — exactly one line on stdout ────────────────────────────────────
#   ^(ok:arrival-routing:[0-9]+ of [0-9]+ new rows|advisory:arrival-routing:[0-9]+ of [0-9]+ new rows|skipped:arrival-routing:(no-plan-binary|stale-plan-binary|no-diff-base|unreadable-fragment)|fail:arrival-routing:checker-exit-[0-9]+)$
#
# Exit 0 on ok/advisory/skipped. NON-ZERO only when the pass CANNOT RUN — a
# broken checkout must be loud, never quietly green. `skipped:` is its own word
# on purpose: a pass that never ran must never report `ok` (785-sqe6, 787-f7dh).
# Every verdict names its own denominator, so none of them can be misread as
# health over an empty set.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

FRAG_DIR="plan/index.d"
[ -d "$FRAG_DIR" ] || { echo "ok:arrival-routing:0 of 0 new rows"; exit 0; }

# One probe, shared with every script that needs the binary (704-zcgi), and it
# resolves by EXECUTION (721-nyev): an executable BIT is a claim, RUNNING the
# binary is evidence.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
PLAN="$(resolve_plan_binary)" || PLAN=""
if [ -z "$PLAN" ]; then
    echo "skipped:arrival-routing:no-plan-binary"
    echo "  tillandsias-plan not built; the arrival-routing pass did not run" >&2
    exit 0
fi

# ORDER 702-68zj: a binary that predates the rule is STALE HOST STATE, not a
# ledger defect. Skip LOUDLY rather than approximating in shell — the ownership
# fold lives in the binary precisely so there is one of it.
if ! plan_binary_has "$PLAN" arrival-routing-check; then
    echo "skipped:arrival-routing:stale-plan-binary"
    echo "  note: $PLAN predates arrival-routing-check — pass SKIPPED (rebuild with 'cargo build --release -p tillandsias-plan')" >&2
    exit 0
fi

base_ref="${TILLANDSIAS_ROUTING_BASE:-origin/linux-next}"
if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    # No base means no diff scope, and a whole-ledger fallback is exactly the
    # gate this file refuses to be. Not `ok`: nothing was examined.
    echo "skipped:arrival-routing:no-diff-base"
    echo "  note: base ref '$base_ref' unavailable — set TILLANDSIAS_ROUTING_BASE to scope the pass" >&2
    exit 0
fi

# Fragments this change ADDS. Same three sources as
# check-added-fragments-parse.sh: added vs base, staged-added, and wholly
# untracked (a brand-new fragment is untracked at the moment it is written).
# --diff-filter=A only, not AM: a fragment is append-only and immutable once
# written, and treating a MODIFIED one as new would report every packet it ever
# held as an arrival.
candidates="$(
    {
        git diff --name-only --diff-filter=A "$base_ref" -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
        git diff --name-only --cached --diff-filter=A -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
        git ls-files --others --exclude-standard -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
    } | sort -u
)"

set --
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue   # deleted (e.g. folded by compaction) — nothing to route
    set -- "$@" "$f"
done <<EOF
$candidates
EOF

if [ "$#" -eq 0 ]; then
    echo "ok:arrival-routing:0 of 0 new rows"
    exit 0
fi

# ONE invocation for the whole candidate set, not one per file: this arm loads
# the folded ledger (a 60k-line index plus ~90 fragments) and paying that per
# fragment would make the gate cost scale with how much a cycle filed — the
# wrong incentive for a check about filing less.
#
# Command substitution, NOT a pipeline: $? here is the subcommand's own status.
# Reading a pipeline's status as the producer's is how 787-f7dh's unparseable
# fragments passed a gate green.
out="$("$PLAN" arrival-routing-check "$@" 2>/dev/null)"
rc=$?
if [ "$rc" -eq 3 ]; then
    # A named fragment the fold could not read contributes NO packets, so
    # "no arrivals" and "unreadable" would otherwise be the same answer. Not a
    # second refusal: check-added-fragments-parse.sh already hard-refuses this
    # exact class, and a second red for one typo tells the author nothing new.
    echo "skipped:arrival-routing:unreadable-fragment"
    echo "  note: a fragment this change adds does not parse — its rows are UNEXAMINED by the arrival rule, not cleared by it (see check-added-fragments-parse.sh)" >&2
    exit 0
fi
if [ "$rc" -ne 0 ]; then
    # Cannot RUN. Loud, per the header: a broken checkout must never be green.
    echo "fail:arrival-routing:checker-exit-${rc}"
    echo "  the arrival-routing pass could not run (tillandsias-plan arrival-routing-check exited ${rc}) — that is a broken checkout, not a clean ledger" >&2
    exit 1
fi

# `population|<n>` is always the first line the arm prints; `overlap|...` lines
# follow. Here-strings and `cut`, never `grep -q` in a pipeline: on a match
# `grep -q` SIGPIPEs the writer and `pipefail` promotes that to a failure.
population="$(printf '%s\n' "$out" | sed -n 's/^population|//p' | head -1)"
case "$population" in
    ''|*[!0-9]*)
        echo "fail:arrival-routing:checker-exit-0"
        echo "  the checker exited 0 without declaring its population — refusing to report a count over an unknown denominator" >&2
        exit 1
        ;;
esac

overlaps="$(printf '%s\n' "$out" | grep '^overlap|' || true)"
flagged=0
if [ -n "$overlaps" ]; then
    flagged="$(printf '%s\n' "$overlaps" | cut -d'|' -f2 | sort -u | grep -c .)"
fi

if [ "$flagged" -eq 0 ]; then
    echo "ok:arrival-routing:0 of ${population} new rows"
    exit 0
fi

echo "advisory:arrival-routing:${flagged} of ${population} new rows"
printf '%s\n' "$overlaps" | while IFS='|' read -r _tag _id predicate sentence; do
    [ -n "${sentence:-}" ] || continue
    echo "  advisory[${predicate}]: ${sentence}" >&2
done
echo "  RULE: methodology/distributed-work.yaml -> new_row_only_if_independently_schedulable. A finding is a NEW ROW only if it names owned_files no open row already owns, OR a different pickup_role can claim it than every open row covering that scope." >&2
echo "  REMEDY if it is NOT independently schedulable: put it on the row it overlaps instead of beside it —" >&2
echo "          tillandsias-plan set-field <id|order> next_action \"<first concrete command or edit>\" --reason \"arrival routing\"" >&2
echo "          or append an event to that row. accumulate_then_promote: observations that are not schedulable accumulate as events; promotion to a row is TLATOANI-GATED." >&2
echo "  REMEDY if it IS independently schedulable: say so on the new row — give it owned_files that do not overlap, or a pickup_role that differs from the row named above." >&2
echo "  NOT DECIDED HERE: the pickup_role disjunct, and whether two rows are really the same work. Both roles are printed above; the call is yours." >&2
echo "  ADVISORY ONLY: open rows carrying owned_files are 0.6% (3/490, measured 2026-08-21), so the rule's own predicate is nearly blind today. Promotion bar and its two clauses are in the header of this file." >&2
exit 0
