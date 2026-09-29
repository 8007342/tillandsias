#!/usr/bin/env bash
# @trace order:767-qrbv, spec:meta-orchestration
#
# smoke-consecutive-lanes.sh — OPT-IN smoke variant: two consecutive forge
# lanes against the SAME stack, asserting the SECOND lane's health.
#
# WHY: both opencode segfaults on record hit a lane that was not the first of
# its session (604-vmcg: incident 1, 2026-08-04, the second consecutive lane
# ~20 min after a clean first; incident 2, 2026-08-10, a long-running lane).
# Every smoke and litmus path runs ONE lane, so the crash-prone shape was
# exercised only by accident. This runs it on purpose.
#
# COST: a lane is a real opencode prompt. Both lanes are FORCED to the cheap
# verify-only smoke prompt (TILLANDSIAS_E2E_FORCE_MODE=smoke, de-escalation
# only, see lib-e2e-mode.sh), so this never spends the 4h full-meta budget.
# It is opt-in: nothing in the gate calls it.
#
# Usage (from the project checkout):
#   scripts/smoke-consecutive-lanes.sh [--gap SECONDS]      # default gap 60
#
# Verdict (last line; exit 0 only on ok:):
#   ok:consecutive-lanes:lane1=0:lane2=0:gap=<s>:stack=kept
#   fail:consecutive-lanes:<reason>:lane1=<rc>:lane2=<rc>:gap=<s>
# reasons: lane1-failed (lane 2 is not run: its health would mean nothing),
#          lane2-failed, lane2-harness-crashed (the harness supervisor's
#          fail:harness-crashed verdict in lane 2's log), stack-replaced
#          (a shared stack container changed identity between the lanes, so
#          lane 2 did not run against the same stack), no-stack (no shared
#          stack container found after lane 1, so "same stack" is unprovable).
# Logs: target/smoke-consecutive-lanes/lane{1,2}.log.
#
# Test seams (fixture only): TILLANDSIAS_CONSECUTIVE_LAUNCHER replaces the lane
# launcher; TILLANDSIAS_CONSECUTIVE_LANE_LOG is the log that launcher writes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAP=60
while [ $# -gt 0 ]; do
    case "$1" in
        --gap) GAP="${2:-}"; shift 2 ;;
        *) echo "usage: $0 [--gap SECONDS]" >&2; exit 2 ;;
    esac
done
case "$GAP" in ''|*[!0-9]*) echo "refused:consecutive-lanes:gap-not-a-number:$GAP" >&2; exit 2 ;; esac

LAUNCHER="${TILLANDSIAS_CONSECUTIVE_LAUNCHER:-$ROOT/scripts/litmus-opencode-e2e-launch.sh}"
LANE_LOG="${TILLANDSIAS_CONSECUTIVE_LANE_LOG:-/tmp/opencode-e2e-forge.log}"
OUT="$ROOT/target/smoke-consecutive-lanes"
mkdir -p "$OUT"

# The shared stack: every running tillandsias-* container except per-lane
# forges, as name=id. The same set with the same ids before and after lane 2
# is what "the same stack" means.
stack_ids() {
    podman ps --format '{{.Names}}={{.ID}}' 2>/dev/null \
        | grep -E '^tillandsias-' | grep -vE -- '-forge|^tillandsias-builder=' | sort
}

run_lane() { # run_lane <n>: runs one smoke lane, copies its log, prints rc
    local n="$1" rc
    TILLANDSIAS_E2E_FORCE_MODE=smoke bash "$LAUNCHER" > "$OUT/lane$n.launcher.out" 2>&1
    rc=$?
    cp "$LANE_LOG" "$OUT/lane$n.log" 2>/dev/null || : > "$OUT/lane$n.log"
    echo "$rc"
}

verdict() { echo "$1"; case "$1" in ok:*) exit 0 ;; *) exit 1 ;; esac; }

rc1="$(run_lane 1)"
if [ "$rc1" != 0 ]; then
    verdict "fail:consecutive-lanes:lane1-failed:lane1=$rc1:lane2=not-run:gap=$GAP"
fi
before="$(stack_ids)"
if [ -z "$before" ]; then
    verdict "fail:consecutive-lanes:no-stack:lane1=$rc1:lane2=not-run:gap=$GAP"
fi
sleep "$GAP"
rc2="$(run_lane 2)"
after="$(stack_ids)"

if grep -q 'fail:harness-crashed' "$OUT/lane2.log" "$OUT/lane2.launcher.out" 2>/dev/null; then
    verdict "fail:consecutive-lanes:lane2-harness-crashed:lane1=$rc1:lane2=$rc2:gap=$GAP"
fi
if [ "$rc2" != 0 ]; then
    verdict "fail:consecutive-lanes:lane2-failed:lane1=$rc1:lane2=$rc2:gap=$GAP"
fi
if [ "$before" != "$after" ]; then
    verdict "fail:consecutive-lanes:stack-replaced:lane1=$rc1:lane2=$rc2:gap=$GAP"
fi
verdict "ok:consecutive-lanes:lane1=0:lane2=0:gap=$GAP:stack=kept"
