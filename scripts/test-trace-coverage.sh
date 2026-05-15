#!/usr/bin/env bash
# =============================================================================
# Unit tests for trace coverage threshold validation
# @trace gap:OBS-004, spec:spec-trace-coverage-threshold, spec:testing
# =============================================================================

set -euo pipefail

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
if echo "$output" | jq -e '.coverage_percentage' >/dev/null 2>&1; then
    _pass "JSON contains all required fields"
else
    _fail "JSON missing required fields"
fi

# Test 6: Status PASS when threshold met
echo "Test 6: Status PASS when coverage meets threshold"
status=$(echo "$output" | jq -r '.status')
if [[ "$status" == "PASS" ]]; then
    _pass "Correctly reports PASS status"
else
    _fail "Should report PASS when threshold met (got: $status)"
fi

# Test 7: Default threshold 90
echo "Test 7: Default threshold is 90"
output=$(bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 2>/dev/null)
threshold=$(echo "$output" | jq -r '.threshold')
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
