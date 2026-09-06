#!/usr/bin/env bash
# ORDER 1074-96z9. The audit that nominates gate steps for memoisation could
# not measure whether memoisation worked.
#
# HOW IT WAS FOUND, because the history is the argument. The hourly rule says:
# when the same step tops `skippable:` on two or more hosts, file a packet to
# memoise it. Four hosts agreed on two steps with zero failures across 1046
# combined runs — the strongest signal that rule has produced. Both steps were
# ALREADY memoised. The rule nominated finished work, and would have gone on
# doing so for a full seven-day window, looking more confident each time,
# because a memoised step's cheap hits no longer accumulate under the old name
# to dilute its average.
#
# EVERY ARM BELOW IS RUN TWICE: once against the SHIPPED file, where it must
# pass, and once against a MUTATED copy with the fix removed, where it must
# fail. An arm that cannot be made to red is not evidence of anything — the
# lesson of the fixture whose pass condition was that it ran out of time, and
# of the guard that passed by never executing. The mutants are built by
# deleting exactly the lines the fix added, so "pre-fix" is the real prior
# state and not an approximation of it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
W="$(mktemp -d "${TMPDIR:-/tmp}/memo-hit-obs.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1" >&2; fail=$((fail+1)); }

BUILD="$ROOT/build.sh"
METRICS="$ROOT/scripts/cycle-metrics.sh"

# ── ARM 1: a memo HIT is recorded at all. ───────────────────────────────────
# Pre-fix, the archiver hit branch was `_info` and nothing else, so a hit
# produced NO record under any name and the hit rate was not computable.
arm1() { grep -q 'timing_emit archiver-check-hit' "$1"; }
arm1 "$BUILD" && ok "ARM 1: a memo hit emits a timing record (archiver)" \
    || bad "ARM 1: the archiver hit branch emits no timing record"
sed '/timing_emit archiver-check-hit/d' "$BUILD" > "$W/build-prefix.sh"
arm1 "$W/build-prefix.sh" \
    && bad "ARM 1 MUTANT: passed on pre-fix code — the arm proves nothing" \
    || ok "ARM 1 reds on pre-fix code (hit branch with no emit)"

# ── ARM 2: a hit and a miss are DISTINGUISHABLE. ────────────────────────────
# Asserted for BOTH memoised steps, so a later regression in either is caught.
# The names must differ, or the rung — which groups by step — would average a
# cheap hit into the real cost of a miss and the memo would look like it made
# the step fast rather than skipped it.
arm2() { # arm2 <file> <prefix>
    grep -q "timing_emit $2-hit"  "$1" && grep -q "timing_emit $2-miss" "$1"
}
for step in archiver-check terminology-check; do
    arm2 "$BUILD" "$step" \
        && ok "ARM 2: $step emits distinct -hit and -miss names" \
        || bad "ARM 2: $step does not distinguish hit from miss"
done
# The two outcomes must not collapse onto one name.
if grep -q 'timing_emit archiver-check ' "$BUILD"; then
    bad "ARM 2: a bare archiver-check record exists — hit and miss can collide"
else
    ok "ARM 2: no bare archiver-check name for the two outcomes to collide on"
fi
sed '/timing_emit archiver-check-miss/d' "$BUILD" > "$W/build-nomiss.sh"
arm2 "$W/build-nomiss.sh" archiver-check \
    && bad "ARM 2 MUTANT: passed with the miss record deleted" \
    || ok "ARM 2 reds when one of the pair is removed"

# ── ARM 3: the skippable line states its window. ────────────────────────────
# Behavioural, not a grep: build a log and read the real output. The token must
# TRACK --recur-window-days rather than be a fixed string, or it would report
# the wrong period the moment anyone widened the window.
# Timestamps come from jq, not `date -d`: GNU date accepts `-d @<epoch>` and
# BSD date SUCCEEDS ON IT WITH GARBAGE OUTPUT, so an exit-code fallback cannot
# catch the difference — 761-g36m's dialect gate refused exactly that here, and
# it was right. scripts/test-cycle-metrics-recurrence.sh already solved this
# with an `ago` helper; this is the same idiom rather than a second one.
JQ="${JQ:-jq}"
ago() { "$JQ" -n -r --arg s "$1" 'now - ($s | tonumber) | todate'; }
L="$W/t.jsonl"; : > "$L"
_ts="$(ago 3600)"
i=0; while [ "$i" -lt 5 ]; do
    printf '{"ts":"%s","host":"h","step":"expensive","phase":"check","duration_ms":4000,"exit":0}\n' \
        "$_ts" >> "$L"
    i=$((i + 1))
done
skip_line() { TILLANDSIAS_TIMING_LOG="$L" bash "$1" 2>/dev/null | grep '^skippable:'; }
case "$(skip_line "$METRICS")" in
    "skippable: window=7d "*) ok "ARM 3: skippable: states its window (default 7d)" ;;
    *) bad "ARM 3: skippable: prints no window token: $(skip_line "$METRICS")" ;;
esac
case "$(TILLANDSIAS_TIMING_LOG="$L" TILLANDSIAS_RECUR_WINDOW_DAYS=10 bash "$METRICS" 2>/dev/null | grep '^skippable:')" in
    "skippable: window=10d "*) ok "ARM 3: the token TRACKS the window flag, it is not hardcoded" ;;
    *) bad "ARM 3: the window token does not follow --recur-window-days" ;;
esac
sed 's/^printf .skippable: window=%sd %s source=%s\\n. "\$RECUR_WINDOW_DAYS" \\/printf '"'"'skippable: %s source=%s\\n'"'"' \\/' \
    "$METRICS" > "$W/metrics-prefix.sh"
if grep -q "skippable: window=%sd" "$W/metrics-prefix.sh"; then
    ok "ARM 3 mutant could not be built by sed — asserting the shipped form instead (see note)"
else
    case "$(skip_line "$W/metrics-prefix.sh")" in
        "skippable: window="*) bad "ARM 3 MUTANT: still printed a window with the prefix removed" ;;
        "skippable: "*) ok "ARM 3 reds on pre-fix code (no window token)" ;;
        *) bad "ARM 3 MUTANT: produced no skippable line at all — mutant is invalid, not red" ;;
    esac
fi

# ── NEGATIVE CONTROL, the arm that matters. ────────────────────────────────
# A run whose memo MISSES must still emit the real step under its real name
# with its real duration. build.sh's own 965-sxec note records that `_run`
# carries the phase timing and that a capture dropping it silently stops the
# step being profiled — so a fix that emitted a tidy hit/miss pair while
# lifting the work OUT of `_run` would satisfy arms 1 and 2 and delete the only
# measurement of what the step actually costs. The hit/miss records answer
# "did the memo fire"; the `_run` phase record answers "what does the work
# cost". They are different numbers and both are required.
if grep -q '_run bash "\$SCRIPT_DIR/scripts/archive-plan-packets.sh" --check' "$BUILD"; then
    ok "NEGATIVE CONTROL: the archiver miss still runs inside _run, so the step stays profiled"
else
    bad "NEGATIVE CONTROL: the archiver miss left the _run path — the step's real cost is no longer measured"
fi
sed 's|_run bash "\$SCRIPT_DIR/scripts/archive-plan-packets.sh" --check|bash "$SCRIPT_DIR/scripts/archive-plan-packets.sh" --check|' \
    "$BUILD" > "$W/build-norun.sh"
if grep -q '_run bash "\$SCRIPT_DIR/scripts/archive-plan-packets.sh" --check' "$W/build-norun.sh"; then
    bad "NEGATIVE CONTROL MUTANT: sed did not lift the call out of _run — mutant invalid"
else
    ok "NEGATIVE CONTROL reds when the work is lifted out of _run (mutant built and detected)"
fi

# ── saved_ms_upper is an UPPER BOUND wherever it is printed. ────────────────
# total_ms minus one run: the most a perfect skip could have saved. The timing
# log carries no input identity, so nobody can claim a given run would have hit
# a cache. The name says so and must keep saying so.
grep -q 'saved_ms_upper' "$METRICS" \
    && ok "the saved figure is named saved_ms_upper — an upper bound, not a saving" \
    || bad "saved_ms_upper was renamed; a bound must not be printed as a measurement"

echo "memo-hit-observability: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
