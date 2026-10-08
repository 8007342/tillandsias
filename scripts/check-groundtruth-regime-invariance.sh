#!/usr/bin/env bash
# preflight: gate-only-decider — its live regime synthesises one answer per run (plan-current-direction-bootstrap-question, ~4 s on lenovinha 2026-09-30, 0.1 s with inference down); capping synthesis would blind it to rendering flips (1518-8p5k)
# freshness: added 2026-08-29 linux-yoga (order 928-qm8k)
# @trace order:928-qm8k, order:920-pxg6, order:764-p9w7
#
# check-groundtruth-regime-invariance.sh — would this case grade differently on
# a host whose inference is up?
#
# ── THE DEFECT (order 928-qm8k) ──────────────────────────────────────────────
#
# A groundtruth case that asserts on ANSWER PROSE has a verdict that depends on
# the host's ambient synthesis regime. MEASURED on yoga 2026-08-29, the same
# query under the two regimes:
#
#   inference LIVE  -> "The current Direction is: **forge agents local EXPERTS.**"
#   inference DEAD  -> "## Direction — what are we all doing today\n\n<!-- …"
#                      (the raw section, pasted)
#
# So `answer_contains: "## Direction"` PASSED on retrieval-only hosts and FAILED
# on synthesising ones. That is the whole three-round story: lenovinha red, yoga
# bisected the same red independently, yolanda red AGAIN at clean HEAD after a
# hotfix that decoupled the heading but still pinned CAPITALISATION. One
# substance, three renderings, three hosts, 24 hours.
#
# The failure mode is not a wrong string. It is a RIGHT string that is only
# right on some hosts — and the tell, per lenovinha, is an assertion that would
# break if the answer got BETTER.
#
# ── WHAT THIS CHECKS, AND WHY IT IS NOT A PROSE BAN ─────────────────────────
#
# MEASURED, not assumed: of the 18 prose-asserting cases in the corpus, exactly
# ONE varies with the regime — the Direction case, whose `answer_contains` is
# already gone (d03a58850). The other seventeen produce BYTE-IDENTICAL answers
# with inference alive and dead, because they assert deterministic renderer
# output: `plan next`'s tabular projection, typed `unsupported:` refusals,
# fragment-provenance ids, methodology path echoes.
#
# So a blanket "remove every answer_contains" would delete seventeen real,
# falsifiable assertions to fix one that was already fixed. The property worth
# enforcing is not "no prose" but INVARIANCE: grade the corpus under both
# regimes and refuse when a verdict moves.
#
# It runs the whole corpus twice in seconds because the deterministic engines
# never touch the network — the cost is real only for the cases that can vary,
# which is exactly the population being watched.
#
# ── GRAMMAR (exactly one line) ───────────────────────────────────────────────
#   ok:groundtruth-regime-invariant:<n>-cases
#   violation:groundtruth-regime-dependent:<csv-of-case-ids>
#   unavailable:<reason>
#
# Exit 0 invariant, 1 divergence, 2 could not determine. ADVISORY by default;
# --strict exits 1 so a gate can refuse new divergence.
#
# Seams: TILLANDSIAS_GROUNDTRUTH_DIR, TILLANDSIAS_PLAN_BIN.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="${TILLANDSIAS_GROUNDTRUTH_DIR:-$ROOT/openspec/litmus-tests/groundtruth}"
STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(resolve_plan_binary)" || { echo "unavailable:no-runnable-plan-binary"; exit 2; }
[ -d "$G" ] || { echo "unavailable:groundtruth-dir-unreadable"; exit 2; }

# The DEAD regime: every inference/embedding endpoint pointed at a closed port.
# Not "unset" — unset can fall back to a default that is reachable, and a
# fallback would make the two runs the same regime and the check vacuous.
dead_env=(
    TILLANDSIAS_INFERENCE_ENDPOINT=http://127.0.0.1:1
    TILLANDSIAS_EMBED_ENDPOINT=http://127.0.0.1:1/v1
    TILLANDSIAS_SPEC_EXPERT_ENDPOINT=http://127.0.0.1:1/v1
)

# raw_grade <live|dead> <set>: grade's FULL stdout. Its last line,
# `groundtruth-result: ...`, is printed only when a grade RAN TO COMPLETION,
# and is how a killed, crashed or harness-failed run is told apart from one
# whose cases merely failed (grade's exit status is its FAIL count, so it
# cannot make that distinction; 2 is both "two cases failed" and a harness error).
raw_grade() {
    if [ "$1" = "dead" ]; then
        env "${dead_env[@]}" "$PLAN" grade "$2" 2>/dev/null
    else
        "$PLAN" grade "$2" 2>/dev/null
    fi
}
# verdicts <raw file>: the PASS/FAIL lines, reduced to "<VERDICT> <case>".
verdicts() {
    grep -E '^(PASS|FAIL)' "$1" | awk '{print $1" "$2}' | LC_ALL=C sort
}

total=0
diverged=""
# ORDER 1500-gu5r: GRADE CONCURRENTLY, COMPARE IN ORDER. The eight grade calls
# (every set, live and dead) are independent, and ran one after another: 6.4 s
# on yoga, over the preflight door's 5 s deadline, with one set
# (expert-groundtruth-rung1) at 4.2 s by itself. Each call now writes its
# verdicts to its own file in the background, and the comparison below reads
# them in the ORIGINAL set order, so the verdict and its wording are unchanged.
_gt_tmp="$(mktemp -d "${TMPDIR:-/tmp}/groundtruth-regime.XXXXXX")" || { echo "unavailable:no-tmp"; exit 2; }
trap 'rm -rf "$_gt_tmp"' EXIT
_gt_i=0
for set_file in "$G"/*.yaml; do
    [ -e "$set_file" ] || continue
    _gt_i=$((_gt_i + 1))
    raw_grade live "$set_file" > "$_gt_tmp/$_gt_i.live" &
    raw_grade dead "$set_file" > "$_gt_tmp/$_gt_i.dead" &
done
wait
# FAIL CLOSED ON AN INCOMPLETE GRADE (coordinator, 2026-09-29). With eight
# grades in flight, one can be killed or crash on a loaded host; comparing the
# other seven and printing ok would certify a population this check did not
# see. Every one of the eight must have printed its summary line. (The serial
# version failed open in the same way: a dead grade became an empty verdict
# list and the set simply counted zero cases.)
_gt_i=0
for set_file in "$G"/*.yaml; do
    [ -e "$set_file" ] || continue
    _gt_i=$((_gt_i + 1))
    for _gt_regime in live dead; do
        if ! grep -q '^groundtruth-result: ' "$_gt_tmp/$_gt_i.$_gt_regime"; then
            echo "[check-groundtruth-regime-invariance] the ${_gt_regime} grade of $(basename "$set_file") did not run to completion (no groundtruth-result line): it was killed, crashed or refused its input, so this check cannot vouch for that set in that regime. Nothing was compared." >&2
            echo "unavailable:grade-incomplete:$(basename "$set_file"):${_gt_regime}"
            exit 2
        fi
    done
done
_gt_i=0
for set_file in "$G"/*.yaml; do
    [ -e "$set_file" ] || continue
    _gt_i=$((_gt_i + 1))
    live="$(verdicts "$_gt_tmp/$_gt_i.live")"
    dead="$(verdicts "$_gt_tmp/$_gt_i.dead")"
    n=$(printf '%s\n' "$live" | grep -c . || true)
    total=$((total + n))
    # A case whose VERDICT moves between regimes is the finding. Comparing
    # verdicts rather than answer text on purpose: an answer is allowed to be
    # worded differently, what must not change is whether the case passes.
    d="$(comm -3 <(printf '%s\n' "$live") <(printf '%s\n' "$dead") 2>/dev/null | awk '{print $NF}' | grep . | LC_ALL=C sort -u || true)"
    while IFS= read -r case_id; do
        [ -n "$case_id" ] || continue
        diverged="${diverged}${diverged:+,}$case_id"
    done <<< "$d"
done

if [ "$total" -eq 0 ]; then
    echo "unavailable:no-cases-graded"
    exit 2
fi
if [ -n "$diverged" ]; then
    echo "[check-groundtruth-regime-invariance] These cases grade DIFFERENTLY with inference up vs down, so their verdict is a property of the HOST rather than of the answer. The tell is an assertion that would break if the answer got BETTER — replace prose assertions with substance ones (confidence, citation kind/count, grading-time span_contains), which read the same on every host." >&2
    echo "violation:groundtruth-regime-dependent:$diverged"
    [ "$STRICT" = 1 ] && exit 1
    exit 0
fi
echo "ok:groundtruth-regime-invariant:${total}-cases"
exit 0
