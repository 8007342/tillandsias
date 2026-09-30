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
DECIDERS="check-bash-dialect check-terminology check-all-fragments-intact check-carry-forward check-plan-binary-probe-usage"
# ORDER 1518-8p5k (coordinator ruling 2026-09-30): the sixth is DECLARED, not
# timed. Its floor is one live synthesis (~4 s on lenovinha), a host property,
# and it carries `# preflight: gate-only-decider — <reason>` so the door names
# it instead of deadline-skipping it. It must not simply drop out of this list:
# a population that shrinks silently is the fail-open this fixture exists to
# stop, so its declaration is ASSERTED below and removing it turns this red.
DECLARED="check-groundtruth-regime-invariance"
command -v setsid >/dev/null 2>&1 && SETSID=setsid || SETSID=""
fail=0
n=0
for d in $DECIDERS; do
    n=$((n + 1))
    t0=$SECONDS
    rc=0
    # shellcheck disable=SC2086
    timeout -k 1 "$DEADLINE" $SETSID bash "scripts/$d.sh" >/dev/null 2>&1 </dev/null || rc=$?
    took=$((SECONDS - t0))
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        echo "FAIL: $d outlived the ${DEADLINE}s door deadline (${took}s) — the door would skip it, not refuse" >&2
        fail=$((fail + 1))
    else
        echo "ok:   $d finished inside the door deadline (${took}s, rc=$rc)"
    fi
done
for d in $DECLARED; do
    n=$((n + 1))
    f="${TILLANDSIAS_DOOR_DECIDER_DIR:-scripts}/$d.sh"
    decl="$(sed -n '1,40{s/^# preflight: gate-only-decider[[:space:]]*//p}' "$f" 2>/dev/null | head -n 1 | sed 's/^[—-][[:space:]]*//')"
    if [ -z "$decl" ]; then
        echo "FAIL: $d is neither timed nor declared — it lost its '# preflight: gate-only-decider — <reason>' line, so the door would deadline-skip it in silence (1518-8p5k)" >&2
        fail=$((fail + 1))
    elif grep -qF "$d.sh" scripts/hooks/* 2>/dev/null; then
        echo "FAIL: $d declares gate-only-decider but a pre-push hook runs it; the door ignores the declaration and deadline-skips it (1518-8p5k)" >&2
        fail=$((fail + 1))
    else
        echo "ok:   $d is declared gate-only-decider (the door names it; the gate runs it): $decl"
    fi
done
[ "$fail" -eq 0 ] || { echo "FAIL: deciders-within-door-deadline $((n - fail))/$n"; exit 1; }
echo "PASS: deciders-within-door-deadline $n/$n"
