#!/usr/bin/env bash
# test-forge-liveness-probe.sh — Fixture tests for forge-liveness-probe.sh
# Order 265: forge-agent-liveness-signals
#
# Validates the five liveness states using controlled test scenarios.
# Runs entirely in /tmp — no live podman or git repo needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROBE="${SCRIPT_DIR}/forge-liveness-probe.sh"
TMPDIR=$(mktemp -d /tmp/test-forge-liveness-XXXXXX)
PASS=0
FAIL=0
TOTAL=0

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

run_test() {
    local name="$1" expected_state="$2" expected_exit="$3"
    shift 3
    local actual_state actual_exit

    TOTAL=$((TOTAL + 1))
    actual_state=$("$@" 2>/dev/null) && actual_exit=0 || actual_exit=$?

    if [[ "$actual_state" == "$expected_state" && "$actual_exit" == "$expected_exit" ]]; then
        echo "  PASS: $name (state=$actual_state exit=$actual_exit)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name — expected state=$expected_state exit=$expected_exit, got state=$actual_state exit=$actual_exit"
        FAIL=$((FAIL + 1))
    fi
}

NC="--no-container"

echo "=== Test 1: alive_progressing (fresh heartbeat + git changed) ==="
DIR1="$TMPDIR/test1"
mkdir -p "$DIR1"
touch "$DIR1/.forge-heartbeat"
(cd "$DIR1" && git init -q && git commit -q --allow-empty -m "init")
HEAD1=$(git -C "$DIR1" rev-parse HEAD)
# Simulate: before_head was different → git changed
run_test \
    "alive_progressing" "alive_progressing" 0 \
    "$PROBE" status --project-dir "$DIR1" --heartbeat-file ".forge-heartbeat" $NC --before-head "deadbeef00000000000000000000000000000000" --start-time "$(date +%s)"

echo ""
echo "=== Test 2: alive_quiet (fresh heartbeat + no git change) ==="
DIR2="$TMPDIR/test2"
mkdir -p "$DIR2"
touch "$DIR2/.forge-heartbeat"
(cd "$DIR2" && git init -q && git commit -q --allow-empty -m "init")
HEAD2=$(git -C "$DIR2" rev-parse HEAD)
# before_head matches current HEAD → no change
run_test \
    "alive_quiet" "alive_quiet" 0 \
    "$PROBE" status --project-dir "$DIR2" --heartbeat-file ".forge-heartbeat" $NC --before-head "$HEAD2" --start-time "$(date +%s)"

echo ""
echo "=== Test 3: dead_air (stale heartbeat > 120s) ==="
DIR3="$TMPDIR/test3"
mkdir -p "$DIR3"
touch -d "200 seconds ago" "$DIR3/.forge-heartbeat"
run_test \
    "dead_air" "dead_air" 1 \
    "$PROBE" status --project-dir "$DIR3" --heartbeat-file ".forge-heartbeat" $NC --start-time "$(date +%s)"

echo ""
echo "=== Test 4: dead_air (no heartbeat file) ==="
DIR4="$TMPDIR/test4"
mkdir -p "$DIR4"
run_test \
    "dead_air_no_file" "dead_air" 1 \
    "$PROBE" status --project-dir "$DIR4" --heartbeat-file ".forge-heartbeat" $NC --start-time "$(date +%s)"

echo ""
echo "=== Test 5: deadline calculation ==="
START=$(date +%s)
DEADLINE=$($PROBE deadline --budget 5400 --start-time "$START" 2>/dev/null)
EXPECTED_EPOCH=$((START + 5400))
ACTUAL_EPOCH=$(date -d "$DEADLINE" +%s 2>/dev/null || echo "0")
TOTAL=$((TOTAL + 1))
if [[ "$ACTUAL_EPOCH" == "$EXPECTED_EPOCH" ]]; then
    echo "  PASS: deadline = $DEADLINE (epoch $ACTUAL_EPOCH)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: deadline = $DEADLINE — expected epoch $EXPECTED_EPOCH, got $ACTUAL_EPOCH"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Test 6: alive_progressing with custom heartbeat deadline ==="
DIR6="$TMPDIR/test6"
mkdir -p "$DIR6"
touch -d "60 seconds ago" "$DIR6/.forge-heartbeat"
(cd "$DIR6" && git init -q && git commit -q --allow-empty -m "init")
run_test \
    "alive_progressing_custom_deadline" "alive_progressing" 0 \
    "$PROBE" status --project-dir "$DIR6" --heartbeat-file ".forge-heartbeat" --heartbeat-deadline 300 $NC --before-head "deadbeef" --start-time "$(date +%s)"

echo ""
echo "=== Test 7: status exits 0 for alive states ==="
DIR7="$TMPDIR/test7"
mkdir -p "$DIR7"
touch "$DIR7/.forge-heartbeat"
(cd "$DIR7" && git init -q && git commit -q --allow-empty -m "init")
HEAD7=$(git -C "$DIR7" rev-parse HEAD)
"$PROBE" status --project-dir "$DIR7" --heartbeat-file ".forge-heartbeat" $NC --before-head "$HEAD7" --start-time "$(date +%s)" >/dev/null 2>&1
EXIT7=$?
TOTAL=$((TOTAL + 1))
if [[ "$EXIT7" == "0" ]]; then
    echo "  PASS: alive status exits 0"
    PASS=$((PASS + 1))
else
    echo "  FAIL: alive status exits $EXIT7 (expected 0)"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Test 8: status exits 1 for dead states ==="
DIR8="$TMPDIR/test8"
mkdir -p "$DIR8"
# Expected-nonzero call must be guarded or `set -e` kills the suite here
# (the dead in-forge agent's last unfixed line, completed by adoption).
EXIT8=0
"$PROBE" status --project-dir "$DIR8" --heartbeat-file ".forge-heartbeat" $NC --start-time "$(date +%s)" >/dev/null 2>&1 || EXIT8=$?
TOTAL=$((TOTAL + 1))
if [[ "$EXIT8" == "1" ]]; then
    echo "  PASS: dead status exits 1"
    PASS=$((PASS + 1))
else
    echo "  FAIL: dead status exits $EXIT8 (expected 1)"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
