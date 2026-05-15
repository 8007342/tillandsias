#!/usr/bin/env bash
# =============================================================================
# Unit tests for trace coverage threshold validation
# @trace gap:OBS-004, spec:spec-trace-coverage-threshold
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

passed=0
failed=0

_pass() { echo -e "${GREEN}✓${NC} $*"; ((passed++)); }
_fail() { echo -e "${RED}✗${NC} $*"; ((failed++)); }
_info() { echo -e "${YELLOW}→${NC} $*"; }

# =============================================================================
# Test 1: Threshold validation rejects invalid values
# =============================================================================
_info "Test 1: Invalid threshold values"

# Test negative threshold
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold -1 >/dev/null 2>&1; then
    _fail "Should reject negative threshold (-1)"
else
    _pass "Rejects negative threshold"
fi

# Test threshold > 100
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 101 >/dev/null 2>&1; then
    _fail "Should reject threshold > 100"
else
    _pass "Rejects threshold > 100"
fi

# Test non-numeric threshold
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold abc >/dev/null 2>&1; then
    _fail "Should reject non-numeric threshold"
else
    _pass "Rejects non-numeric threshold"
fi

# =============================================================================
# Test 2: Threshold bounds (0 and 100)
# =============================================================================
_info "Test 2: Boundary thresholds"

if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 0 >/dev/null 2>&1; then
    _pass "Accepts threshold 0"
else
    _fail "Should accept threshold 0"
fi

if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 100 >/dev/null 2>&1; then
    _pass "Accepts threshold 100 (may fail coverage, but threshold is valid)"
else
    _fail "Should accept threshold 100 as valid"
fi

# =============================================================================
# Test 3: JSON output format
# =============================================================================
_info "Test 3: JSON output format"

output=$(bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 80 2>/dev/null | grep -E "^\{" || true)

if [[ -z "$output" ]]; then
    _fail "Should output JSON (no JSON found)"
else
    # Check for required JSON fields
    if echo "$output" | jq -e '.coverage_percentage' >/dev/null 2>&1; then
        _pass "JSON contains coverage_percentage"
    else
        _fail "JSON missing coverage_percentage"
    fi

    if echo "$output" | jq -e '.specs_with_traces' >/dev/null 2>&1; then
        _pass "JSON contains specs_with_traces"
    else
        _fail "JSON missing specs_with_traces"
    fi

    if echo "$output" | jq -e '.total_active_specs' >/dev/null 2>&1; then
        _pass "JSON contains total_active_specs"
    else
        _fail "JSON missing total_active_specs"
    fi

    if echo "$output" | jq -e '.threshold' >/dev/null 2>&1; then
        _pass "JSON contains threshold"
    else
        _fail "JSON missing threshold"
    fi

    if echo "$output" | jq -e '.status' >/dev/null 2>&1; then
        _pass "JSON contains status"
    else
        _fail "JSON missing status"
    fi

    if echo "$output" | jq -e '.uncovered_count' >/dev/null 2>&1; then
        _pass "JSON contains uncovered_count"
    else
        _fail "JSON missing uncovered_count"
    fi
fi

# =============================================================================
# Test 4: Status field correctness
# =============================================================================
_info "Test 4: Status field correctness"

# Get current coverage
current_coverage=$(bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 0 2>/dev/null | jq -r '.coverage_percentage')

# Test with threshold below current coverage (should PASS)
test_threshold=$((current_coverage - 10))
[[ $test_threshold -lt 0 ]] && test_threshold=0
status=$(bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold "$test_threshold" 2>/dev/null | jq -r '.status')
if [[ "$status" == "PASS" ]]; then
    _pass "Status PASS when coverage meets threshold"
else
    _fail "Status should be PASS when coverage meets threshold (got: $status)"
fi

# Test with threshold above current coverage (should FAIL)
test_threshold=$((current_coverage + 10))
[[ $test_threshold -gt 100 ]] && test_threshold=100
status=$(bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold "$test_threshold" 2>/dev/null | jq -r '.status')
if [[ "$status" == "FAIL" ]]; then
    _pass "Status FAIL when coverage below threshold"
else
    _fail "Status should be FAIL when coverage below threshold (got: $status)"
fi

# =============================================================================
# Test 5: Exit codes
# =============================================================================
_info "Test 5: Exit code behavior"

# Exit 0 when coverage meets threshold
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 0 >/dev/null 2>&1; then
    _pass "Exit code 0 when coverage meets threshold"
else
    _fail "Should exit 0 when coverage meets threshold"
fi

# Exit 1 when coverage below threshold
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 100 >/dev/null 2>&1; then
    _fail "Should exit 1 when coverage below threshold"
else
    _pass "Exit code 1 when coverage below threshold"
fi

# =============================================================================
# Test 6: Default threshold (90%)
# =============================================================================
_info "Test 6: Default threshold handling"

# Run with no explicit threshold (should use 90)
status=$(bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 2>/dev/null | jq -r '.threshold')
if [[ "$status" == "90" ]]; then
    _pass "Default threshold is 90"
else
    _fail "Default threshold should be 90 (got: $status)"
fi

# =============================================================================
# Test 7: Uncovered specs list (when coverage fails)
# =============================================================================
_info "Test 7: Uncovered specs reporting"

# Capture output when coverage fails
output=$(bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 100 2>&1 || true)

if echo "$output" | grep -q "Uncovered specs"; then
    _pass "Lists uncovered specs when coverage fails"
else
    _fail "Should list uncovered specs when coverage fails"
fi

if echo "$output" | grep -q "Action: Add @trace spec:"; then
    _pass "Shows action message for uncovered specs"
else
    _fail "Should show action message for uncovered specs"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "${GREEN}Passed: $passed${NC}"
echo -e "${RED}Failed: $failed${NC}"
echo "========================================"

[[ $failed -eq 0 ]] && exit 0 || exit 1
