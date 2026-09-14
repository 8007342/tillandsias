#!/usr/bin/env bash
# @trace order:1130-qk7d
#
# test-plan-binary-probe-usage-determinism-corpus.sh — the BREADTH arm.
#
# --ci-full ONLY, declared in scripts/gate-divergence-declared.txt. Its cheap
# sibling, test-plan-binary-probe-usage-determinism.sh, runs on every --check.
#
# WHAT THIS ADDS THAT THE CHEAP ARM CANNOT. The cheap arm runs the guard against
# a two-file tree holding the one file known to flake, and pins THAT mechanism —
# SIGPIPE from `grep -q` killing its upstream writer under pipefail. It is a
# real detector (measured: pre-fix 13/7 two verdicts, post-fix 20/20 one) and it
# is NARROW by construction. It cannot see a non-determinism that only appears
# at corpus scale, or one carried by a file nobody has identified yet.
#
# This arm runs the guard over the WHOLE repository, which is the only way to
# ask that broader question. It costs about 6.6 s per run on a floor host
# (pirria, cachyos), which is why it runs once a day on one host rather than on
# every land: 20 runs was measured at 132.6 s there, the single most expensive
# step in a 635 s gate and 21% of its wall clock. A gate that slow gets routed
# around with --no-verify, which is the 748-tkjx argument with a different
# number.
#
# RUN COUNT BY BINOMIAL, not by a round number. The check misses a flake only if
# all N runs happen to agree: P(miss) = p^N + (1-p)^N. Using the observed
# pre-fix splits on the real corpus (6/4 and 7/3) and the worst lopsidedness
# p=0.70 as the conservative case: N=10 -> 97.2%, N=12 -> 98.6%, N=15 -> 99.5%,
# N=20 -> 99.9%. 15 is the smallest count clearing 99.5%.
#
# AND WHAT THAT NUMBER DOES NOT MEAN: p is estimated from twenty runs across two
# guard versions, so its interval is wide, and p is a property of THIS host's
# timing rather than a constant of the defect. On a host where the race never
# fires p is 1 and no run count detects anything. 15 is right for the evidence
# in hand; elsewhere this arm is a regression pin against reintroducing the
# pipeline, not a detector.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-plan-binary-probe-usage.sh"

# PORTABLE MILLISECONDS. `date +%s%N` is a GNU-ism: BSD date SUCCEEDS with
# garbage output rather than failing, so an exit-code guard cannot catch it
# (761-g36m) — the same "a failure that reads as success" shape this fixture's
# own subject is about. scripts/timing-log.sh already solves it: %3N with digit
# validation, degrading to seconds*1000. Use the shared one rather than a fourth
# private copy (704-zcgi).
. "$ROOT/scripts/timing-log.sh" 2>/dev/null || true
command -v timing_now_ms >/dev/null 2>&1 || timing_now_ms() { date +%s 2>/dev/null | awk '{printf "%d000", $1}' 2>/dev/null || echo 0; }
RUNS="${TILLANDSIAS_DETERMINISM_CORPUS_RUNS:-15}"

_t0="$(timing_now_ms)"
verdicts="$(for _ in $(seq "$RUNS"); do PLAN_PROBE_ROOT="$ROOT" bash "$GUARD" 2>/dev/null; done | sort -u)"
_ms=$(( $(timing_now_ms) - _t0 ))
count="$(printf '%s\n' "$verdicts" | grep -c .)"

if [ "$count" = 1 ]; then
    echo "ok:plan-binary-probe-usage-determinism-corpus:1 — ${RUNS} runs agree in ${_ms}ms"
    exit 0
fi
echo "FAIL: ${RUNS} full-corpus runs produced $count distinct verdicts in ${_ms}ms:"
printf '%s\n' "$verdicts" | sed 's/^/    /'
echo "  This is corpus-scale non-determinism. The cheap --check arm pins only the"
echo "  1130-qk7d SIGPIPE mechanism on one known file; a split HERE that the cheap"
echo "  arm did not catch means a different file or a different cause. Identify"
echo "  which file's eligibility flipped before assuming it is the same defect."
exit 1
