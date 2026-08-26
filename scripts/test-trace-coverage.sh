#!/usr/bin/env bash
# =============================================================================
# Unit tests for trace coverage threshold validation
# @trace gap:OBS-004, spec:spec-trace-coverage-threshold, spec:testing
# =============================================================================

set -euo pipefail


# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
if command -v resolve_tool >/dev/null 2>&1; then
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

passed=0
failed=0

_pass() { echo "✓ $*"; ((passed++)); }
_fail() { echo "✗ $*"; ((failed++)); }

echo "=== Trace Coverage Threshold Tests ==="
echo ""

# Test 1: Invalid threshold (negative)
echo "Test 1: Reject negative threshold"
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold -1 >/dev/null 2>&1; then
    _fail "Should reject negative threshold"
else
    _pass "Rejects negative threshold"
fi

# Test 2: Invalid threshold (>100)
echo "Test 2: Reject threshold > 100"
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 101 >/dev/null 2>&1; then
    _fail "Should reject threshold > 100"
else
    _pass "Rejects threshold > 100"
fi

# Test 3: Invalid threshold (non-numeric)
echo "Test 3: Reject non-numeric threshold"
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold abc >/dev/null 2>&1; then
    _fail "Should reject non-numeric threshold"
else
    _pass "Rejects non-numeric threshold"
fi

# Test 4: Valid threshold 0
echo "Test 4: Accept threshold 0"
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 0 >/dev/null 2>&1; then
    _pass "Accepts threshold 0"
else
    _fail "Should accept threshold 0"
fi

# Test 5: JSON output format
echo "Test 5: JSON output format"
output=$(bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 80 2>/dev/null)
if echo "$output" | "$JQ" -e '.coverage_percentage' >/dev/null 2>&1; then
    _pass "JSON contains all required fields"
else
    _fail "JSON missing required fields"
fi

# Test 6: Status PASS when threshold met
echo "Test 6: Status PASS when coverage meets threshold"
status=$(echo "$output" | "$JQ" -r '.status')
if [[ "$status" == "PASS" ]]; then
    _pass "Correctly reports PASS status"
else
    _fail "Should report PASS when threshold met (got: $status)"
fi

# Test 7: Default threshold 90
echo "Test 7: Default threshold is 90"
output=$(bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 2>/dev/null)
threshold=$(echo "$output" | "$JQ" -r '.threshold')
if [[ "$threshold" == "90" ]]; then
    _pass "Default threshold is 90"
else
    _fail "Default threshold should be 90 (got: $threshold)"
fi

# Test 8: Exit code 0 when passing
echo "Test 8: Exit code 0 when passing"
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 0 >/dev/null 2>&1; then
    _pass "Exit code 0 when coverage meets threshold"
else
    _fail "Should exit 0 when coverage meets threshold"
fi

# Test 9: Exit code 1 when failing
echo "Test 9: Exit code 1 when failing"
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 100 >/dev/null 2>&1; then
    _fail "Should exit 1 when coverage below threshold"
else
    _pass "Exit code 1 when coverage below threshold"
fi

# Test 10: Uncovered specs list
echo "Test 10: Uncovered specs list on failure"
output=$(bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 100 2>&1 || true)
if echo "$output" | grep -q "Uncovered specs"; then
    _pass "Lists uncovered specs when coverage fails"
else
    _fail "Should list uncovered specs when coverage fails"
fi

echo ""
echo "=== Test Summary ==="
echo "Passed: $passed"
echo "Failed: $failed"
echo ""

[[ $failed -eq 0 ]] && exit 0 || exit 1
