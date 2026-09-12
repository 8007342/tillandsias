#!/usr/bin/env bash
# @trace order:1130-qk7d
#
# test-plan-binary-probe-usage-determinism.sh — does the probe-usage guard give
# the SAME answer twice?
#
# WHY. On 2026-09-12 check-plan-binary-probe-usage.sh returned a different
# verdict on an unchanged tree between consecutive runs: measured 10 runs, the
# eligible count split 7/3. Exactly one file flipped — the largest one — and it
# was READ every run, so it was the eligibility DECISION that flipped, not the
# walk. A violation in that file would have been found by coin flip, and the
# guard printed `ok:` either way.
#
# THE CAUSE, kept here because a fixture that pins a symptom without naming its
# mechanism invites the next person to "simplify" the fix away: the eligibility
# test was `printf | grep -v | grep -q`. `grep -q` exits on its first match and
# SIGPIPEs the upstream writer; under `set -o pipefail` the pipeline reports
# 141, and `if !` reads that as "no match". Timing-dependent, so only the file
# large enough for the match to land before the writer finished was affected.
#
# This fixture exists because determinism is not observable from one run, which
# is precisely why the defect survived in a guard that ran on every land.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-plan-binary-probe-usage.sh"
RUNS="${TILLANDSIAS_DETERMINISM_RUNS:-20}"
fail=0

# ARM 1 — N consecutive runs on an UNCHANGED tree give exactly one verdict.
# THIS IS THE DISCRIMINATING ARM, verified in both directions on the real tree:
# against the pre-fix guard, 20 runs produced TWO distinct verdicts
# (scripts=7/569 and scripts=8/569); against the fixed guard, ONE. It needs the
# real corpus, because the race requires a file large enough that grep -q exits
# while the upstream is still writing.
verdicts="$(for _ in $(seq "$RUNS"); do bash "$GUARD" 2>/dev/null; done | sort -u)"
count="$(printf '%s\n' "$verdicts" | grep -c .)"
if [ "$count" = 1 ]; then
    echo "ok: ${RUNS} runs agree ($(printf '%s' "$verdicts" | head -1))"
else
    echo "FAIL: ${RUNS} runs produced $count distinct verdicts:"
    printf '%s\n' "$verdicts" | sed 's/^/    /'
    fail=1
fi

# ARM 2 — a POSITIVE CONTROL, and it is NOT a pin for this defect. Say so
# plainly: measured against the PRE-FIX guard on this scratch tree, the planted
# violation was refused 20/20 as well, so this arm passes on the unfixed code
# and cannot detect the regression. A two-file scratch tree does not reproduce
# the timing the race needs.
#
# It is kept because arm 1 alone is satisfied by a guard that is reliably WRONG
# — a guard that refuses everything, or walks nothing, is perfectly
# deterministic. Arm 2 establishes that the guard still has teeth at all. What
# it must not be mistaken for is evidence that the flake is gone; only arm 1
# shows that, and only on the real tree.
d="$(mktemp -d)"
mkdir -p "$d/scripts/gate-steps.d" "$d/openspec/litmus-tests"
printf 'resolve_plan_binary() { echo /bin/true; }\n' > "$d/scripts/plan-binary-probe.sh"
# Padding so the file is comfortably larger than the match position: the defect
# needed the writer to still be writing when grep -q exited.
{
    printf '#!/usr/bin/env bash\n'
    printf 'if [ -x "$R/target/release/tillandsias-plan" ]; then :; fi\n'
    for _ in $(seq 400); do printf '# padding to outlast the reader, see 1130-qk7d\n'; done
} > "$d/scripts/test-fragment-status-loss.sh"

misses=0
for _ in $(seq "$RUNS"); do
    PLAN_PROBE_ROOT="$d" bash "$GUARD" >/dev/null 2>&1 || continue
    misses=$((misses + 1))   # exit 0 means the planted violation was MISSED
done
if [ "$misses" = 0 ]; then
    echo "ok: planted violation refused ${RUNS}/${RUNS}"
else
    echo "FAIL: planted violation MISSED on $misses of $RUNS runs (the 1130-qk7d symptom)"
    fail=1
fi
rm -rf "$d"

[ "$fail" = 0 ] && echo "ok:plan-binary-probe-usage-determinism:2"
exit "$fail"
