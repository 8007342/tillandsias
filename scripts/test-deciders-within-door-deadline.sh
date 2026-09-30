#!/usr/bin/env bash
# @trace order:1500-gu5r, spec:ci-release
#
# test-deciders-within-door-deadline.sh — the six push deciders that used to
# outlive the preflight door's 5 s deadline on the full population (so the door
# could only SKIP them, never refuse) each finish inside it, run exactly as the
# door runs a guard: its own session (setsid), stdin from /dev/null, a 5 s bound.
# Measured on yoga 2026-09-29 before -> after: check-bash-dialect 14.5 -> 3.7 s,
# check-terminology 19 -> 0.1 s, check-all-fragments-intact 14.3 -> 0.6 s,
# check-carry-forward 13 -> <1 s, check-groundtruth-regime-invariance 6.2 -> 2.6 s,
# check-plan-binary-probe-usage 6.0 -> 0.5 s; each verdict byte-identical to the
# pre-change script on the live tree and on seeded inputs.
# A decider that hits the bound fails BY NAME with its measured time, so a
# regression names the guard that grew instead of reddening the door's budget.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
DEADLINE="${TILLANDSIAS_PREFLIGHT_TIMEOUT:-5}"
DECIDERS="check-bash-dialect check-terminology check-all-fragments-intact check-carry-forward check-groundtruth-regime-invariance check-plan-binary-probe-usage"
command -v setsid >/dev/null 2>&1 && SETSID=setsid || SETSID=""
PLAN="$(. scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || PLAN=""
case "$PLAN" in ./*) PLAN="$ROOT/${PLAN#./}" ;; esac
fail=0
n=0
for d in $DECIDERS; do
    n=$((n + 1))
    t0=$SECONDS
    rc=0
    # shellcheck disable=SC2086
    # 1384-ddua: a ported decider is scripts/lua/<d>.lua on the one runner.
    if [ -f "scripts/lua/$d.lua" ]; then
        timeout -k 1 "$DEADLINE" $SETSID "$PLAN" script run "scripts/lua/$d.lua" >/dev/null 2>&1 </dev/null || rc=$?
    else
        timeout -k 1 "$DEADLINE" $SETSID bash "scripts/$d.sh" >/dev/null 2>&1 </dev/null || rc=$?
    fi
    took=$((SECONDS - t0))
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        echo "FAIL: $d outlived the ${DEADLINE}s door deadline (${took}s) — the door would skip it, not refuse" >&2
        fail=$((fail + 1))
    else
        echo "ok:   $d finished inside the door deadline (${took}s, rc=$rc)"
    fi
done
[ "$fail" -eq 0 ] || { echo "FAIL: deciders-within-door-deadline $((n - fail))/$n"; exit 1; }
echo "PASS: deciders-within-door-deadline $n/$n"
