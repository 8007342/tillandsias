#!/usr/bin/env bash
# local-ci.sh — Full CI/CD validation suite for local development
# @trace spec:ci-release, spec:spec-traceability, spec:versioning
#
# Purpose: Run ALL convergence checks locally before pushing.
# This avoids wasting cloud minutes on failures.
#
# All checks that run in cloud workflows ALSO run here:
#   - Spec-cheatsheet binding validation (threshold 90%)
#   - Spec-code drift detection (ghost traces, zero-trace specs)
#   - Version monotonicity enforcement
#   - Litmus test execution (if container runtime available)
#
# Exit codes:
#   0 = all checks pass, safe to push
#   1 = at least one check failed
#   2 = precondition not met (e.g., missing script)
#
# Usage:
#   scripts/local-ci.sh              # Run full suite
#   scripts/local-ci.sh --fast       # Run quick checks only (skip litmus tests)
#   scripts/local-ci.sh --verbose    # Show detailed output

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Parse flags
FAST_MODE=0
VERBOSE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fast) FAST_MODE=1; shift ;;
        --verbose) VERBOSE=1; shift ;;
        *) echo "Unknown flag: $1"; exit 2 ;;
    esac
done

# Formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

if [[ "${NO_COLOR:-0}" == "1" ]]; then
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# Tracking
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0
FAILED_CHECKS=()
FAILED_REASONS=()

# Logging
log_section() {
    echo ""
    printf '%b%s%b\n' "${BOLD}${BLUE}" "▶ $*" "${NC}"
}

log_pass() {
    printf '%b✓%b %s\n' "${GREEN}" "${NC}" "$*"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

log_fail() {
    printf '%b✗%b %s\n' "${RED}" "${NC}" "$*"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
}

log_fail_tracked() {
    local check_name="$1"
    local reason="$2"
    log_fail "$reason"
    FAILED_CHECKS+=("$check_name")
    FAILED_REASONS+=("$reason")
}

log_skip() {
    printf '%b⊘%b %s\n' "${YELLOW}" "${NC}" "$*"
    CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
}

log_info() {
    printf '%b%s%b %s\n' "${BLUE}" "ℹ" "${NC}" "$*"
}

# ============================================================================
# CHECK 1: Spec-cheatsheet binding validation
# ============================================================================

log_section "Spec-Cheatsheet Binding (90% threshold)"
if [[ -f "scripts/validate-spec-cheatsheet-binding.sh" ]]; then
    if bash scripts/validate-spec-cheatsheet-binding.sh --threshold 90 2>&1 | tee /tmp/binding-check.log; then
        log_pass "Spec-cheatsheet binding coverage ≥ 90%"
    else
        log_fail_tracked "spec-cheatsheet-binding" "Spec-cheatsheet binding below 90% (see /tmp/binding-check.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/binding-check.log >&2
    fi
else
    log_skip "Spec-cheatsheet binding validator not found"
fi

# ============================================================================
# CHECK 2: Spec-code drift detection (CI mode)
# ============================================================================

log_section "Spec-Code Drift Detection (CI Mode)"
if [[ -f "scripts/hooks/pre-commit-openspec.sh" ]]; then
    if bash scripts/hooks/pre-commit-openspec.sh --ci-mode 2>&1 | tee /tmp/drift-check.log; then
        log_pass "No ghost traces or zero-trace specs"
    else
        log_fail_tracked "spec-code-drift" "Spec-code drift detected: ghost traces or zero-trace specs found (see /tmp/drift-check.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/drift-check.log >&2
    fi
else
    log_skip "Spec-code drift checker not found"
fi

# ============================================================================
# CHECK 3: Version monotonicity enforcement
# ============================================================================

log_section "Version Monotonicity Check"
if [[ -f "scripts/verify-version-monotonic.sh" ]]; then
    if bash scripts/verify-version-monotonic.sh 2>&1 | tee /tmp/version-check.log; then
        log_pass "Version is monotonically valid"
    else
        log_fail_tracked "version-monotonicity" "Version is not monotonically greater than last release (see /tmp/version-check.log)"
        cat /tmp/version-check.log >&2
    fi
else
    log_skip "Version monotonicity checker not found"
fi

# ============================================================================
# CHECK 4: Cargo checks (formatting, clippy, tests)
# ============================================================================

log_section "Rust Code Quality (fmt, clippy, tests)"

# Formatting check
if cargo fmt --check --all 2>&1 | tee /tmp/fmt-check.log; then
    log_pass "Rust formatting valid"
else
    log_fail_tracked "rust-formatting" "Rust code not formatted: run 'cargo fmt --all' (see /tmp/fmt-check.log)"
    [[ "$VERBOSE" == "1" ]] && cat /tmp/fmt-check.log >&2
fi

# Clippy check
if cargo clippy --workspace -- -D warnings 2>&1 | tee /tmp/clippy-check.log; then
    log_pass "Clippy checks pass (no warnings)"
else
    log_fail_tracked "rust-clippy" "Clippy warnings found: run 'cargo clippy --workspace' to see details (see /tmp/clippy-check.log)"
    [[ "$VERBOSE" == "1" ]] && cat /tmp/clippy-check.log >&2
fi

# Tests
if cargo test --workspace 2>&1 | tee /tmp/test-check.log; then
    log_pass "All tests pass"
else
    log_fail_tracked "rust-tests" "Test failures detected: run 'cargo test --workspace' to see details (see /tmp/test-check.log)"
    [[ "$VERBOSE" == "1" ]] && cat /tmp/test-check.log >&2
fi

# ============================================================================
# CHECK 5: Cheatsheet tier validation
# ============================================================================

log_section "Cheatsheet Tier Discipline"
if [[ -f "scripts/check-cheatsheet-tiers.sh" ]]; then
    if bash scripts/check-cheatsheet-tiers.sh 2>&1 | tee /tmp/cheatsheet-tiers.log; then
        log_pass "Cheatsheet tier validation passed"
    else
        log_fail_tracked "cheatsheet-tiers" "Cheatsheet tier errors found (see /tmp/cheatsheet-tiers.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/cheatsheet-tiers.log >&2
    fi
else
    log_skip "Cheatsheet tier validator not found"
fi

# ============================================================================
# CHECK 6: Litmus tests (skipped in --fast mode)
# ============================================================================

if [[ "$FAST_MODE" == "0" ]]; then
    log_section "Litmus Test Execution (Optional — requires podman)"
    if [[ -f "scripts/run-litmus-test.sh" ]]; then
        # Check if podman is available
        if command -v podman &> /dev/null; then
            if bash scripts/run-litmus-test.sh --all 2>&1 | tee /tmp/litmus-check.log; then
                log_pass "All litmus tests passed"
            else
                log_fail_tracked "litmus-tests" "Litmus test failures detected (see /tmp/litmus-check.log)"
                [[ "$VERBOSE" == "1" ]] && cat /tmp/litmus-check.log >&2
            fi
        else
            log_skip "Podman not available (litmus tests require container runtime)"
        fi
    else
        log_skip "Litmus test runner not found"
    fi
else
    log_section "Litmus Tests — Skipped (--fast mode)"
    log_info "Run without --fast to execute litmus tests locally"
fi

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
printf '%b%s%b\n' "${BOLD}" "═════════════════════════════════════════" "${NC}"

TOTAL=$((CHECKS_PASSED + CHECKS_FAILED))

# Calculate and display metrics
if [[ $TOTAL -gt 0 ]]; then
    PASS_RATE=$((CHECKS_PASSED * 100 / TOTAL))
else
    PASS_RATE=0
fi

# Display success metrics
echo ""
printf '%b📊 Success Metrics%b\n' "${BOLD}${GREEN}" "${NC}"
printf '   Passed:  %d\n' "$CHECKS_PASSED"
printf '   Failed:  %d\n' "$CHECKS_FAILED"
printf '   Skipped: %d\n' "$CHECKS_SKIPPED"
printf '   Pass Rate: %d%% (%d/%d)\n' "$PASS_RATE" "$CHECKS_PASSED" "$TOTAL"
echo ""

# Visual progress bar
if [[ $TOTAL -gt 0 ]]; then
    BAR_WIDTH=30
    FILLED=$((PASS_RATE * BAR_WIDTH / 100))
    EMPTY=$((BAR_WIDTH - FILLED))
    BAR=$(printf '%.*s' "$FILLED" "████████████████████████████████")
    EMPTY_BAR=$(printf '%.*s' "$EMPTY" "                              ")
    printf '   Progress: %b%s%b%s %d%%\n' "${GREEN}" "$BAR" "${NC}" "$EMPTY_BAR" "$PASS_RATE"
fi
echo ""

printf '%b Results:%b %d passed, %d failed, %d skipped\n' "${BOLD}" "${NC}" \
    "$CHECKS_PASSED" "$CHECKS_FAILED" "$CHECKS_SKIPPED" >&2

if [[ $CHECKS_FAILED -eq 0 ]]; then
    printf '%b%s%b\n' "${GREEN}${BOLD}" "✓ ALL CHECKS PASSED — Safe to push!" "${NC}"
    printf '%b%s%b\n' "" "Cloud workflows will re-verify these guarantees as a safety net." "${NC}"
    echo ""
    exit 0
else
    printf '%b%s%b\n' "${RED}${BOLD}" "✗ CHECKS FAILED — Fix issues before pushing" "${NC}"
    echo ""
    echo "Failed checks:"
    for i in "${!FAILED_CHECKS[@]}"; do
        check="${FAILED_CHECKS[$i]}"
        reason="${FAILED_REASONS[$i]}"
        printf '  %b[%d]%b %-30s %s\n' "${RED}" "$((i+1))" "${NC}" "$check" "$reason"
    done
    echo ""
    echo "Next steps:"
    echo "  1. Review the failures above — each lists the root cause and log file"
    echo "  2. Fix the issues (see actionable steps in each failure reason)"
    echo "  3. Re-run: scripts/local-ci.sh"
    echo "  4. Once all checks pass, git push is safe"
    echo ""
    exit 1
fi
