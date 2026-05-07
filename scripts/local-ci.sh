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

SIGNATURE_DIR="$REPO_ROOT/target/convergence"
SIGNATURE_JSONL="$SIGNATURE_DIR/centicolon-signature.jsonl"
EVIDENCE_BUNDLE="$SIGNATURE_DIR/evidence-bundle.json"
DELTA_JSON="$SIGNATURE_DIR/centicolon-delta.json"
VERSION_VALUE="$(cat VERSION 2>/dev/null || echo "0.0.0.0")"
SOURCE_COMMIT="$(git rev-parse --short=12 HEAD 2>/dev/null || echo "unknown")"
CI_RUN_ID="local-ci-$(date -u +%Y%m%dT%H%M%SZ)"
CI_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

CHECK_IDS=(
    spec-cheatsheet-binding
    spec-code-drift
    version-monotonicity
    rust-formatting
    rust-clippy
    rust-tests
    container-base-policy
    cheatsheet-tiers
    litmus-tests
)

check_weight() {
    case "$1" in
        spec-cheatsheet-binding) echo 100 ;;
        spec-code-drift) echo 120 ;;
        version-monotonicity) echo 40 ;;
        rust-formatting) echo 40 ;;
        rust-clippy) echo 60 ;;
        rust-tests) echo 80 ;;
        container-base-policy) echo 40 ;;
        cheatsheet-tiers) echo 80 ;;
        litmus-tests) echo 140 ;;
        *) echo 0 ;;
    esac
}

check_spec_ref() {
    case "$1" in
        spec-cheatsheet-binding) echo "spec:spec-traceability" ;;
        spec-code-drift) echo "spec:spec-traceability" ;;
        version-monotonicity) echo "spec:versioning" ;;
        rust-formatting) echo "spec:dev-build" ;;
        rust-clippy) echo "spec:dev-build" ;;
        rust-tests) echo "spec:testing" ;;
        container-base-policy) echo "spec:default-image" ;;
        cheatsheet-tiers) echo "spec:cheatsheet-source-layer" ;;
        litmus-tests) echo "spec:litmus-convergence" ;;
        *) echo "spec:unknown" ;;
    esac
}

failed_reason_for_check() {
    local check_name="$1"
    case "$check_name" in
        spec-cheatsheet-binding) echo "Spec-cheatsheet binding below 90% (see /tmp/binding-check.log)" ;;
        spec-code-drift) echo "Spec-code drift detected: ghost traces or zero-trace specs found (see /tmp/drift-check.log)" ;;
        version-monotonicity) echo "Version is not monotonically greater than last release (see /tmp/version-check.log)" ;;
        rust-formatting) echo "Rust code not formatted: run 'cargo fmt --all' (see /tmp/fmt-check.log)" ;;
        rust-clippy) echo "Clippy warnings found: run 'cargo clippy --workspace' to see details (see /tmp/clippy-check.log)" ;;
        rust-tests) echo "Test failures detected: run 'cargo test --workspace --lib' to see details (see /tmp/test-check.log)" ;;
        container-base-policy) echo "Container base-image policy drift found (see /tmp/container-bases.log)" ;;
        cheatsheet-tiers) echo "Cheatsheet tier errors or strict warnings found (see /tmp/cheatsheet-tiers.log)" ;;
        litmus-tests) echo "Litmus test failures detected (see /tmp/litmus-check.log)" ;;
        *) echo "Check failed: $check_name" ;;
    esac
}

write_convergence_artifacts() {
    mkdir -p "$SIGNATURE_DIR"

    local total_cc=0
    local residual_cc=0
    local passed_cc=0
    local total_checks=$((CHECKS_PASSED + CHECKS_FAILED))
    local pass_rate=0
    if [[ $total_checks -gt 0 ]]; then
        pass_rate=$((CHECKS_PASSED * 100 / total_checks))
    fi
    local failed_specs=()
    local failed_weights=()
    local failed_reasons_file
    local failed_checks_file
    local failed_reasons_list_file
    failed_reasons_file="$(mktemp)"
    failed_checks_file="$(mktemp)"
    failed_reasons_list_file="$(mktemp)"
    trap 'rm -f "$failed_reasons_file" "$failed_checks_file" "$failed_reasons_list_file"' RETURN

    for check_id in "${CHECK_IDS[@]}"; do
        local weight
        weight="$(check_weight "$check_id")"
        total_cc=$((total_cc + weight))
        if [[ " ${FAILED_CHECKS[*]} " == *" ${check_id} "* ]]; then
            residual_cc=$((residual_cc + weight))
            failed_specs+=("$(check_spec_ref "$check_id")")
            failed_weights+=("$weight")
            jq -nc \
                --arg reason "$(failed_reason_for_check "$check_id")" \
                --arg spec "$(check_spec_ref "$check_id")" \
                --argjson cc "$weight" \
                '{spec_or_obligation_id:$spec, reason:$reason, cc:$cc}' \
                >>"$failed_reasons_file"
        else
            passed_cc=$((passed_cc + weight))
        fi
    done

    local failed_reasons_json
    if [[ -s "$failed_reasons_file" ]]; then
        failed_reasons_json="$(jq -sc '.' "$failed_reasons_file")"
    else
        failed_reasons_json='[]'
    fi

    local max_residual_spec="n/a"
    local max_residual_reason="n/a"
    local max_residual_cc=0
    if [[ ${#failed_specs[@]} -gt 0 ]]; then
        max_residual_spec="${failed_specs[0]}"
        max_residual_reason="$(failed_reason_for_check "${FAILED_CHECKS[0]}")"
        max_residual_cc="${failed_weights[0]}"
        local i
        for i in "${!failed_specs[@]}"; do
            if (( failed_weights[i] > max_residual_cc )); then
                max_residual_spec="${failed_specs[i]}"
                max_residual_reason="$(failed_reason_for_check "${FAILED_CHECKS[i]}")"
                max_residual_cc="${failed_weights[i]}"
            fi
        done
    fi

    if [[ ${#FAILED_CHECKS[@]} -gt 0 ]]; then
        printf '%s\n' "${FAILED_CHECKS[@]}" >"$failed_checks_file"
    else
        : >"$failed_checks_file"
    fi

    if [[ ${#FAILED_REASONS[@]} -gt 0 ]]; then
        printf '%s\n' "${FAILED_REASONS[@]}" >"$failed_reasons_list_file"
    else
        : >"$failed_reasons_list_file"
    fi

    local ci_result="FAIL"
    if [[ $CHECKS_FAILED -eq 0 ]]; then
        ci_result="PASS"
    fi

    local signature_hash="n/a"
    local delta_hash="n/a"

    local signature_tmp
    signature_tmp="$(mktemp)"
    jq -nc \
        --arg timestamp "$CI_TIMESTAMP" \
        --arg version "$VERSION_VALUE" \
        --arg source_commit "$SOURCE_COMMIT" \
        --arg source_namespace "local_development" \
        --arg ci_run_id "$CI_RUN_ID" \
        --argjson litmus_tests_run "${TESTS_RUN:-0}" \
        --argjson litmus_passed "${TESTS_PASSED:-0}" \
        --argjson litmus_failed "${TESTS_FAILED:-0}" \
        --argjson litmus_skipped "${TESTS_SKIPPED:-0}" \
        --argjson project_cc_earned "$passed_cc" \
        --argjson project_cc_total "$total_cc" \
        --argjson residual_cc "$residual_cc" \
        --argjson pass_rate "$pass_rate" \
        --arg ci_result "$ci_result" \
        --arg evidence_bundle_ref "target/convergence/evidence-bundle.json" \
        --arg projection_ref "docs/convergence/centicolon-dashboard.md" \
        --argjson top_residual_reasons "$failed_reasons_json" \
        --arg max_residual_spec "$max_residual_spec" \
        --arg max_residual_reason "$max_residual_reason" \
        --argjson max_residual_cc "$max_residual_cc" \
        --rawfile failed_checks "$failed_checks_file" \
        --rawfile failed_reasons "$failed_reasons_list_file" \
        '{
          timestamp:$timestamp,
          version:$version,
          source_commit:$source_commit,
          source_namespace:$source_namespace,
          ci_run_id:$ci_run_id,
          release_date:$timestamp,
          expected_total_cc:$project_cc_total,
          actual_earned_cc:$project_cc_earned,
          residual_cc:$residual_cc,
          percent_closed:(if $project_cc_total > 0 then (($project_cc_earned / $project_cc_total) * 100) else 0 end),
          litmus_tests_run:$litmus_tests_run,
          litmus_passed:$litmus_passed,
          litmus_failed:$litmus_failed,
          litmus_skipped:$litmus_skipped,
          project_cc_earned:$project_cc_earned,
          project_cc_total:$project_cc_total,
          ci_result:$ci_result,
          max_residual_spec:$max_residual_spec,
          max_residual_reason:$max_residual_reason,
          max_residual_cc:$max_residual_cc,
          evidence_bundle_ref:$evidence_bundle_ref,
          centicolon_projection_ref:$projection_ref,
          top_residual_reasons:$top_residual_reasons,
          failed_checks:($failed_checks|split("\n")[:-1]),
          failed_reasons:($failed_reasons|split("\n")[:-1])
        }' >"$signature_tmp"

    if [[ -f "$SIGNATURE_JSONL" ]]; then
        cat "$SIGNATURE_JSONL" "$signature_tmp" >"$SIGNATURE_JSONL.new"
    else
        cat "$signature_tmp" >"$SIGNATURE_JSONL.new"
    fi
    mv "$SIGNATURE_JSONL.new" "$SIGNATURE_JSONL"
    rm -f "$signature_tmp"

    if command -v sha256sum >/dev/null 2>&1; then
        signature_hash="$(sha256sum "$SIGNATURE_JSONL" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        signature_hash="$(shasum -a 256 "$SIGNATURE_JSONL" | awk '{print $1}')"
    fi

    local signature_history_file
    local signature_latest_file
    signature_history_file="$(mktemp)"
    signature_latest_file="$(mktemp)"
    trap 'rm -f "$failed_reasons_file" "$failed_checks_file" "$failed_reasons_list_file" "$signature_history_file" "$signature_latest_file"' RETURN
    jq -s '.' "$SIGNATURE_JSONL" >"$signature_history_file"
    jq '.[-1]' "$signature_history_file" >"$signature_latest_file"

    jq -nc \
        --arg generated_at "$CI_TIMESTAMP" \
        --arg source_file "target/convergence/centicolon-signature.jsonl" \
        --argjson record_count "$(wc -l < "$SIGNATURE_JSONL")" \
        --slurpfile latest "$signature_latest_file" \
        --slurpfile history "$signature_history_file" \
        --arg signature_hash "$signature_hash" \
        '{
          generated_at:$generated_at,
          source_file:$source_file,
          record_count:$record_count,
          signature_hash:$signature_hash,
          latest:$latest[0],
          history:$history[0]
        }' >"$DELTA_JSON"

    if command -v sha256sum >/dev/null 2>&1; then
        delta_hash="$(sha256sum "$DELTA_JSON" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        delta_hash="$(shasum -a 256 "$DELTA_JSON" | awk '{print $1}')"
    fi

    jq -nc \
        --arg timestamp "$CI_TIMESTAMP" \
        --arg version "$VERSION_VALUE" \
        --arg source_commit "$SOURCE_COMMIT" \
        --arg source_namespace "local_development" \
        --arg signature_hash "$signature_hash" \
        --arg delta_hash "$delta_hash" \
        --arg dashboard_hash "n/a" \
        --arg ci_run_id "$CI_RUN_ID" \
        --argjson signature_records "$(wc -l < "$SIGNATURE_JSONL")" \
        --argjson delta_records 1 \
        --argjson project_cc_total "$total_cc" \
        --argjson project_cc_earned "$passed_cc" \
        --argjson residual_cc "$residual_cc" \
        --argjson check_count "${#CHECK_IDS[@]}" \
        '{
          generated_at:$timestamp,
          version:$version,
          source_commit:$source_commit,
          source_namespace:$source_namespace,
          ci_run_id:$ci_run_id,
          signature_hash:$signature_hash,
          delta_hash:$delta_hash,
          centicolon_dashboard_hash:$dashboard_hash,
          signature_records:$signature_records,
          delta_records:$delta_records,
          project_cc_total:$project_cc_total,
          project_cc_earned:$project_cc_earned,
          residual_cc:$residual_cc,
          check_count:$check_count
        }' >"$EVIDENCE_BUNDLE"

    return 0
}

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
if [[ -f "scripts/validate-spec-cheatsheet-binding-fast.sh" ]]; then
    if bash scripts/validate-spec-cheatsheet-binding-fast.sh 2>&1 | tee /tmp/binding-check.log; then
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

# @trace spec:dev-build, spec:ci-release
# Run cargo commands in toolbox where all system deps are available
TOOLBOX_NAME="tillandsias"

# Formatting check
if toolbox run -c "$TOOLBOX_NAME" cargo fmt --check --all 2>&1 | tee /tmp/fmt-check.log; then
    log_pass "Rust formatting valid"
else
    log_fail_tracked "rust-formatting" "Rust code not formatted: run 'cargo fmt --all' (see /tmp/fmt-check.log)"
    [[ "$VERBOSE" == "1" ]] && cat /tmp/fmt-check.log >&2
fi

# Clippy check
if toolbox run -c "$TOOLBOX_NAME" cargo clippy --workspace -- -D warnings 2>&1 | tee /tmp/clippy-check.log; then
    log_pass "Clippy checks pass (no warnings)"
else
    log_fail_tracked "rust-clippy" "Clippy warnings found: run 'cargo clippy --workspace' to see details (see /tmp/clippy-check.log)"
    [[ "$VERBOSE" == "1" ]] && cat /tmp/clippy-check.log >&2
fi

# Tests - run lib tests only (integration tests require GTK headers in toolbox)
# @trace spec:testing
if toolbox run -c "$TOOLBOX_NAME" cargo test --workspace --lib 2>&1 | tee /tmp/test-check.log; then
    log_pass "All unit tests pass (integration tests require toolbox)"
else
    log_fail_tracked "rust-tests" "Test failures detected: run 'cargo test --workspace --lib' to see details (see /tmp/test-check.log)"
    [[ "$VERBOSE" == "1" ]] && cat /tmp/test-check.log >&2
fi

# Tray feature contract
# @trace spec:tray-app, spec:tray-ux, spec:tray-progress-and-icon-states
if toolbox run -c "$TOOLBOX_NAME" cargo test -p tillandsias-headless --features tray 2>&1 | tee /tmp/tray-check.log; then
    log_pass "Tray feature tests pass"
else
    log_fail_tracked "tray-contract" "Tray feature tests failed (see /tmp/tray-check.log)"
    [[ "$VERBOSE" == "1" ]] && cat /tmp/tray-check.log >&2
fi

# Headless signal shutdown contract
# @trace spec:linux-native-portable-executable, spec:headless-mode, spec:graceful-shutdown
if toolbox run -c "$TOOLBOX_NAME" cargo test -p tillandsias-headless --test signal_handling 2>&1 | tee /tmp/signal-handling-check.log; then
    log_pass "Headless shutdown signal tests pass"
else
    log_fail_tracked "signal-handling" "Headless shutdown signal tests failed (see /tmp/signal-handling-check.log)"
    [[ "$VERBOSE" == "1" ]] && cat /tmp/signal-handling-check.log >&2
fi

# ============================================================================
# CHECK 5: Container base-image policy
# ============================================================================

log_section "Container Base Image Policy"
if [[ -f "scripts/check-container-bases.sh" ]]; then
    if bash scripts/check-container-bases.sh 2>&1 | tee /tmp/container-bases.log; then
        log_pass "Container base images match role policy"
    else
        log_fail_tracked "container-base-policy" "Container base-image policy drift found (see /tmp/container-bases.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/container-bases.log >&2
    fi
else
    log_skip "Container base-image checker not found"
fi

# ============================================================================
# CHECK 6: Cheatsheet tier validation
# ============================================================================

log_section "Cheatsheet Tier Discipline"
if [[ -f "scripts/check-cheatsheet-tiers.sh" ]]; then
    if bash scripts/check-cheatsheet-tiers.sh --strict 2>&1 | tee /tmp/cheatsheet-tiers.log; then
        log_pass "Cheatsheet tier validation passed"
    else
        log_fail_tracked "cheatsheet-tiers" "Cheatsheet tier errors or strict warnings found (see /tmp/cheatsheet-tiers.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/cheatsheet-tiers.log >&2
    fi
else
    log_skip "Cheatsheet tier validator not found"
fi

# ============================================================================
# CHECK 7: Litmus tests (skipped in --fast mode)
# ============================================================================

if [[ "$FAST_MODE" == "0" ]]; then
    log_section "Litmus Test Execution (Optional — requires podman)"
    if [[ -f "scripts/run-litmus-test.sh" ]]; then
        # Check if podman is available
        if command -v podman &> /dev/null; then
            if bash scripts/run-litmus-test.sh 2>&1 | tee /tmp/litmus-check.log; then
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
# CHECK 8: CentiColon signature writer
# ============================================================================

log_section "CentiColon Signature Writing"
if write_convergence_artifacts 2>&1 | tee /tmp/convergence-writer.log; then
    log_pass "CentiColon signature and evidence bundle written"
else
    log_fail_tracked "convergence-writer" "CentiColon signature writer failed (see /tmp/convergence-writer.log)"
    [[ "$VERBOSE" == "1" ]] && cat /tmp/convergence-writer.log >&2
fi

# ============================================================================
# CHECK 9: CentiColon dashboard generation
# ============================================================================

log_section "CentiColon Dashboard Generation"
if [[ -f "scripts/update-convergence-dashboard.sh" ]]; then
    if bash scripts/update-convergence-dashboard.sh 2>&1 | tee /tmp/convergence-dashboard.log; then
        log_pass "CentiColon dashboard regenerated"
    else
        log_fail_tracked "convergence-dashboard" "CentiColon dashboard generation failed (see /tmp/convergence-dashboard.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/convergence-dashboard.log >&2
    fi
else
    log_skip "CentiColon dashboard generator not found"
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
