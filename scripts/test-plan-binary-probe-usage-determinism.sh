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

# ARM 1 — THE DETECTOR. N runs against a MINIMAL tree holding the REAL file
# that flaked, and nothing else. It must give exactly one verdict.
#
# WHY A MINIMAL TREE AND NOT THE REAL CORPUS. The race is a property of the
# FILE, not of the corpus: grep -q has to match while the writer is still
# writing, which depends on that file's size and match position, not on how many
# other files were walked. Measured on yoga 2026-09-12, copying
# scripts/test-fragment-status-loss.sh verbatim into a two-file tree:
#
#     PRE-FIX  20 runs -> 13x scripts=0/2, 7x scripts=1/2   TWO verdicts
#     POST-FIX 20 runs -> 20x scripts=1/2                   ONE verdict
#     cost: 194 ms for 20 runs (7 ms/run)
#
# The full-corpus equivalent costs 132.6 s for 20 runs (pirria, cachyos, land
# gate) — the single most expensive step in a 635 s gate, 21% of wall clock —
# and gives a WEAKER pre-fix split (6/4 against 13/7). So the corpus bought wall
# clock and no signal. 680x cheaper, better discrimination.
#
# THE STAND-IN, NOT THE TREE, WAS THE DIFFERENCE. An earlier attempt at this
# used a SYNTHETIC file — a hardcoded path plus 400 padding lines, sized to
# resemble the real one — and did not reproduce the flake at all, which nearly
# established "the race needs the corpus" as fact and would have made the 132 s
# step permanent. Use the real file. A failed reproduction is a result about the
# SETUP until it is a result about the subject.
_mk_minimal() {
    _d="$(mktemp -d)"
    mkdir -p "$_d/scripts" "$_d/openspec/litmus-tests"
    printf 'resolve_plan_binary() { echo /bin/true; }\n' > "$_d/scripts/plan-binary-probe.sh"
    cp "$ROOT/scripts/test-fragment-status-loss.sh" "$_d/scripts/" 2>/dev/null
    printf '%s\n' "$_d"
}
md="$(_mk_minimal)"
if [ ! -f "$md/scripts/test-fragment-status-loss.sh" ]; then
    # The subject file is gone. Say so as its own state rather than passing: a
    # detector that silently tests an empty tree is the defect this pins.
    echo "FAIL: scripts/test-fragment-status-loss.sh is absent — this arm has no subject and cannot detect anything"
    fail=1
else
    _t0="$(date +%s%N)"
    verdicts="$(for _ in $(seq "$RUNS"); do PLAN_PROBE_ROOT="$md" bash "$GUARD" 2>/dev/null; done | sort -u)"
    _ms=$(( ($(date +%s%N) - _t0) / 1000000 ))
    count="$(printf '%s\n' "$verdicts" | grep -c .)"
    if [ "$count" = 1 ]; then
        echo "ok: ${RUNS} runs agree in ${_ms}ms ($(printf '%s' "$verdicts" | head -1))"
    else
        echo "FAIL: ${RUNS} runs produced $count distinct verdicts in ${_ms}ms:"
        printf '%s\n' "$verdicts" | sed 's/^/    /'
        fail=1
    fi
fi
rm -rf "$md"

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
