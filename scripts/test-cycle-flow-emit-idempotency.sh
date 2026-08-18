#!/usr/bin/env bash
# @trace order:682-epud, spec:meta-orchestration
set -uo pipefail

# Fixture for --emit-flow's per-cycle idempotency (order 682-epud).
#
# THE DEFECT THIS PINS. The emit appended unconditionally, so a cycle whose
# finalization was RETRIED -- the gate went red, the emit had already run --
# wrote a second record. Measured on windows 2026-08-15: one cycle wrote three
# records and the reporter said `cycles=8` over six real cycles.
#
# WHY THAT IS WORSE THAN NOISE. Retries are not randomly distributed. They
# happen on the expensive cycles, the ones that went wrong. So duplicates add
# cycle-count from precisely the worst cases while diluting the per-cycle
# averages, and overhead_ratio -- the number the greedier-batching decision
# (682-yiz7) consumes -- moves in a direction the underlying work did not.
# A measurement corrupted by the act of measuring is the failure mode here.
#
# THE CONTRACT, one scenario each:
#   1. a second emit for the same host+cycle REPLACES the first (count is flat)
#   2. the SURVIVOR is the later record -- a retry runs after more work, so its
#      counts are the truthful ones, and keeping the first would freeze the
#      cycle at its pre-retry state
#   3. a different cycle on the same host still appends
#   4. the same cycle id on a DIFFERENT host still appends (the key is the pair;
#      hosts run their own cycle numbering and must not evict each other)
#   5. omitting cycle= MINTS `<host>-<utc>` (order 801-tpxd), announces it, and
#      appends. Deriving beats demanding: the id was always derivable by the
#      callee, and requiring it from the caller shipped two `-` rows. This is
#      not the bucket-by-clock-hour heuristic that was rightly refused before --
#      that MERGES distinct cycles and drops genuine records, while a
#      second-resolution mint is injective, so an unlabelled retry still appends
#   6. the log is never left truncated: a replace writes via a temp file
#   8. `"cycle":"-"` is UNREACHABLE -- the negative control for 801-tpxd. A
#      sentinel that cannot be written cannot be mistaken for a cycle id, nor
#      invite the global sed that clobbered a historical row while "repairing"
#      one
#
# Nothing here touches the real flow log; TILLANDSIAS_CYCLE_FLOW_LOG is
# redirected into a throwaway dir.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METRICS="$ROOT/scripts/cycle-metrics.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/cycle-flow-emit-fixture.XXXXXX")"
trap 'rm -rf "$work"' EXIT
LOG="$work/flow.jsonl"

failures=()
check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS  $name"
    else
        echo "FAIL  $name: want [$want] got [$got]"
        failures+=("$name")
    fi
}

emit() { TILLANDSIAS_CYCLE_FLOW_LOG="$LOG" "$METRICS" --emit-flow "$@" 2>/dev/null; }
lines() { grep -c . "$LOG" 2>/dev/null || echo 0; }

# 1 + 2. Replace on retry, and the later record wins.
emit host=windows cycle=c1 batch_epic=e completed=0 commits=1
check "1 first emit appends" "1" "$(lines)"
emit host=windows cycle=c1 batch_epic=e completed=3 commits=2
check "1 retry does not append" "1" "$(lines)"
check "2 later record survives" "3" "$(sed -n 's/.*"completed":\([0-9]*\).*/\1/p' "$LOG")"

# 3. A genuinely new cycle is still recorded.
emit host=windows cycle=c2 batch_epic=e completed=1 commits=1
check "3 new cycle appends" "2" "$(lines)"

# 4. Same cycle id, different host: distinct records. Hosts number their own
#    cycles, so keying on cycle alone would have one host evict another's row.
emit host=linux cycle=c2 batch_epic=e completed=9 commits=1
check "4 other host appends" "3" "$(lines)"
check "4 windows row intact" "1" \
    "$(grep '"host":"windows","cycle":"c2"' "$LOG" | sed -n 's/.*"completed":\([0-9]*\).*/\1/p')"

# 5. No cycle= -> the id is MINTED from host+UTC and announced (order 801-tpxd),
#    and the record still appends. The pre-801-tpxd behaviour wrote the sentinel
#    `-` and warned; the warning did not prevent two windows cycles from shipping
#    a `-` row, so the sentinel is now unreachable instead of merely discouraged.
note="$(TILLANDSIAS_CYCLE_FLOW_LOG="$LOG" "$METRICS" --emit-flow host=windows batch_epic=e 2>&1 >/dev/null | head -1)"
case "$note" in
    note:*minted\ cycle=windows-*) echo "PASS  5 missing cycle mints an id" ;;
    *) echo "FAIL  5 missing cycle mints an id: got [$note]"; failures+=("5") ;;
esac
check "5 missing cycle still appends" "4" "$(lines)"
check "5 minted id has the host+UTC shape" "1" \
    "$(grep -cE '"host":"windows","cycle":"windows-[0-9]{8}T[0-9]{6}Z"' "$LOG")"

# 6. Every line is still parseable JSON with both key fields. A replace that
#    left a half-written log would show up here as a short or empty file.
bad=0
while IFS= read -r l; do
    case "$l" in *'"host":"'*'"cycle":"'*'}') ;; *) bad=$((bad + 1)) ;; esac
done < "$LOG"
check "6 no torn records" "0" "$bad"

# The emit must never fail the cycle it measures: exit 0 even on a hopeless log.
rc=0
TILLANDSIAS_CYCLE_FLOW_LOG="$work/nonexistent-dir/flow.jsonl" \
    "$METRICS" --emit-flow host=windows cycle=c9 >/dev/null 2>&1 || rc=$?
check "7 unwritable log still exits 0" "0" "$rc"

# 8. THE NEGATIVE CONTROL for order 801-tpxd: no path may write `"cycle":"-"`.
#    Every emit above ran without cycle= at least once, and an explicit `-` is
#    also rewritten, so a single sentinel anywhere in the log fails this. This
#    is the property, not the warning text: a broken record that the caller was
#    warned about is still a broken record, and the one in the real windows log
#    was "repaired" with a global sed that took a historical row with it.
check "8 no sentinel cycle row is reachable" "0" "$(grep -c '"cycle":"-"' "$LOG" 2>/dev/null | head -1)"
TILLANDSIAS_CYCLE_FLOW_LOG="$LOG" "$METRICS" --emit-flow host=windows cycle=- completed=1 >/dev/null 2>&1
check "8 explicit cycle=- is rewritten, not stored" "0" "$(grep -c '"cycle":"-"' "$LOG" 2>/dev/null | head -1)"

if [ "${#failures[@]}" -gt 0 ]; then
    echo "FAIL: ${#failures[@]} scenario(s): ${failures[*]}"
    exit 1
fi
echo "ok:cycle-flow-emit-idempotency:8"
exit 0
