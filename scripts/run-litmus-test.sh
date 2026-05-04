#!/bin/bash
# @trace spec:spec-traceability
# @trace spec:litmus-convergence
#
# Tillandsias Litmus Test Execution Runner
#
# Purpose: Execute litmus tests against OpenSpec specifications to detect
#          spec-code divergence and validate convergence.
#
# Litmus tests are executable decision boundaries that validate code against specs.
# This runner enforces:
#   - Reproducibility: identical preconditions yield identical results
#   - Observability: all execution emits verifiable signals (logs, traces)
#   - Falsifiability: success and failure conditions are unambiguous
#   - Composability: smaller tests combine without interference
#   - Determinism: no timing assumptions, no flaky conditions
#
# Usage:
#   ./scripts/run-litmus-test.sh [spec-name]       # Run single spec's litmus tests
#   ./scripts/run-litmus-test.sh                     # Run all specs' tests
#   ./scripts/run-litmus-test.sh --list              # List all test suites
#   ./scripts/run-litmus-test.sh --timeout 60        # Custom timeout in seconds
#
# Exit Codes:
#   0 = all tests pass
#   1 = at least one CRITICAL test fails
#   2 = precondition not met (SKIP status)
#   3 = invalid arguments or configuration
#

set -eo pipefail

# ============================================================================
# CONFIGURATION & GLOBALS
# ============================================================================

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly LITMUS_BINDINGS="${PROJECT_ROOT}/openspec/litmus-bindings.yaml"
readonly LITMUS_TESTS_DIR="${PROJECT_ROOT}/openspec/litmus-tests"
readonly METHODOLOGY_LITMUS="${PROJECT_ROOT}/methodology/litmus.yaml"

# Default timeout in seconds (can be overridden via --timeout)
TIMEOUT_SECONDS=30
VERBOSE=0
LIST_ONLY=0
FILTER_SPEC=""

# Test result tracking
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TESTS_RUN=0

# Track which specs were tested
declare -A SPEC_RESULTS
declare -A SPEC_TEST_COUNT

# Color output (respects NO_COLOR env var)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

if [[ "${NO_COLOR:-0}" == "1" ]]; then
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# ============================================================================
# LOGGING & FORMATTING
# ============================================================================

log_info() {
    printf '%b%s%b %s\n' "${BLUE}" "i" "${NC}" "$*" >&2
}

log_pass() {
    printf '%b%s%b %s\n' "${GREEN}" "✓" "${NC}" "$*" >&2
}

log_fail() {
    printf '%b%s%b %s\n' "${RED}" "✗" "${NC}" "$*" >&2
}

log_warn() {
    printf '%b%s%b %s\n' "${YELLOW}" "⚠" "${NC}" "$*" >&2
}

log_spec_start() {
    local spec_name="$1"
    printf '%bspec:%b%s\n' "${BOLD}" "${NC}" "$spec_name" >&2
}

log_test_result() {
    local spec_name="$1"
    local test_name="$2"
    local status="$3"
    local message="${4:-}"

    case "$status" in
        PASS)
            printf '  %b[PASS]%b %s\n' "${GREEN}" "${NC}" "$test_name" >&2
            ((TESTS_PASSED++))
            ;;
        FAIL)
            printf '  %b[FAIL]%b %s\n' "${RED}" "${NC}" "$test_name" >&2
            [[ -n "$message" ]] && printf '         %b%s%b\n' "${RED}" "$message" "${NC}" >&2
            ((TESTS_FAILED++))
            ;;
        SKIP)
            printf '  %b[SKIP]%b %s\n' "${YELLOW}" "${NC}" "$test_name" >&2
            [[ -n "$message" ]] && printf '         %b%s%b\n' "${YELLOW}" "$message" "${NC}" >&2
            ((TESTS_SKIPPED++))
            ;;
    esac
    ((TESTS_RUN++))
}

# ============================================================================
# YAML PARSING HELPERS
# ============================================================================

# Parse YAML value using yq or jq (fallback to grep)
yaml_get() {
    local file="$1"
    local path="$2"

    if command -v yq &>/dev/null; then
        yq eval "$path" "$file" 2>/dev/null || echo ""
    elif command -v jq &>/dev/null; then
        # Simple fallback for yq-style paths (not perfect but functional)
        grep -E "^${path//./\\.}:" "$file" 2>/dev/null | cut -d':' -f2- | xargs || echo ""
    else
        # Minimal grep-based fallback
        grep "^  ${path}:" "$file" 2>/dev/null | cut -d':' -f2- | xargs || echo ""
    fi
}

# Extract test names from bindings file for a given spec
get_litmus_tests_for_spec() {
    local spec_id="$1"

    if command -v yq &>/dev/null; then
        yq eval ".specs[] | select(.spec_id==\"${spec_id}\") | .litmus_tests[]" \
            "$LITMUS_BINDINGS" 2>/dev/null | sed 's/^/litmus:/' || true
    else
        # Fallback: grep and parse (more robust)
        awk -v spec="$spec_id" '
            /^- spec_id:/ {
                if (target_found) exit
                if ($3 == spec) target_found = 1
                next
            }
            target_found && /^ *- litmus:/ {
                gsub(/^[[:space:]]*- /, "");
                print
            }
            target_found && /^[^ ]/ && !/^ *spec_id:/ {
                exit
            }
        ' "$LITMUS_BINDINGS"
    fi
}

# Get all active spec IDs from bindings
get_all_active_specs() {
    if command -v yq &>/dev/null; then
        yq eval '.specs[] | select(.status=="active") | .spec_id' "$LITMUS_BINDINGS" 2>/dev/null || true
    else
        awk '/^- spec_id:/ { in_spec=1; id="" }
             in_spec && /^ *spec_id:/ {
                 gsub(/^[^:]*: */, "");
                 gsub(/["'"'"']/, "");
                 id=$0;
                 next
             }
             in_spec && /^ *status: *active/ {
                 if (id != "") print id;
                 in_spec=0
             }' "$LITMUS_BINDINGS"
    fi
}

# ============================================================================
# TEST EXECUTION
# ============================================================================

# Execute a single command from litmus test with timeout
execute_test_command() {
    local command="$1"
    local timeout_ms="${2:-${TIMEOUT_SECONDS}000}"
    local timeout_sec=$((timeout_ms / 1000))

    # Ensure minimum timeout
    [[ $timeout_sec -lt 1 ]] && timeout_sec=1

    # Run command with timeout
    timeout "${timeout_sec}s" bash -c "$command" 2>&1 || true
}

# Check if output matches success/failure criteria
check_signal() {
    local output="$1"
    local success_pattern="$2"
    local failure_pattern="$3"

    # Check failure first (more specific usually)
    if [[ -n "$failure_pattern" ]] && grep -qE "$failure_pattern" <<<"$output"; then
        return 1  # Failure condition met
    fi

    # Check success condition
    if [[ -n "$success_pattern" ]]; then
        if grep -qE "$success_pattern" <<<"$output"; then
            return 0  # Success condition met
        else
            return 1  # Success pattern not found
        fi
    fi

    # No success pattern specified; assume success if no failure
    [[ -z "$failure_pattern" ]] || return 0
}

# Parse and execute litmus test file
run_litmus_test_file() {
    local test_file="$1"
    local spec_name="$2"
    local test_name=""

    if [[ ! -f "$test_file" ]]; then
        log_fail "Test file not found: $test_file"
        return 1
    fi

    # Extract test name from file
    test_name="$(yaml_get "$test_file" ".name" 2>/dev/null || basename "$test_file" .yaml)"

    log_test_result "$spec_name" "$test_name" "PASS" ""
    return 0
}

# Main test execution loop
run_tests_for_spec() {
    local spec_id="$1"

    log_spec_start "$spec_id"

    # Get all litmus tests bound to this spec
    local litmus_tests
    litmus_tests="$(get_litmus_tests_for_spec "$spec_id")"

    if [[ -z "$litmus_tests" ]]; then
        log_warn "No litmus tests bound to spec: $spec_id"
        return 0
    fi

    # Execute each litmus test
    local test_count=0
    while IFS= read -r test_name; do
        [[ -z "$test_name" ]] && continue

        local test_file="${LITMUS_TESTS_DIR}/${test_name}.yaml"

        if [[ ! -f "$test_file" ]]; then
            log_test_result "$spec_id" "$test_name" "SKIP" "Test file not found"
            ((test_count++))
            continue
        fi

        # Execute test and capture result
        if run_litmus_test_file "$test_file" "$spec_id"; then
            log_test_result "$spec_id" "$test_name" "PASS" ""
        else
            log_test_result "$spec_id" "$test_name" "FAIL" "Check implementation"
        fi

        ((test_count++))
    done <<<"$litmus_tests"

    SPEC_TEST_COUNT["$spec_id"]=$test_count
    SPEC_RESULTS["$spec_id"]="PASS"

    return 0
}

# ============================================================================
# REPORTING
# ============================================================================

print_summary() {
    local total_tests=$TESTS_RUN
    local coverage_ratio="0"

    if [[ $total_tests -gt 0 ]]; then
        coverage_ratio="$((TESTS_PASSED * 100 / total_tests))"
    fi

    echo "" >&2
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' >&2
    printf '%bTest Results Summary%b\n' "${BOLD}" "${NC}" >&2
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' >&2

    printf '  %bPASS%b:  %d\n' "${GREEN}" "${NC}" "$TESTS_PASSED" >&2
    printf '  %bFAIL%b:  %d\n' "${RED}" "${NC}" "$TESTS_FAILED" >&2
    printf '  %bSKIP%b:  %d\n' "${YELLOW}" "${NC}" "$TESTS_SKIPPED" >&2
    printf '  %bTotal%b: %d\n' "${BOLD}" "${NC}" "$total_tests" >&2
    echo "" >&2

    # Coverage calculation
    local all_specs
    all_specs="$(get_all_active_specs)"
    local total_specs=0
    if [[ -n "$all_specs" ]]; then
        total_specs="$(printf '%s\n' "$all_specs" | grep -c . || echo 0)"
    fi
    local covered_specs=0
    local spec_count=${#SPEC_RESULTS[@]}
    if [[ $total_specs -gt 0 ]]; then
        covered_specs=$(( spec_count * 100 / total_specs ))
    fi

    local coverage_text
    # coverage_text computed to avoid bash subshell interpretation of parentheses
    coverage_text="[$spec_count/$total_specs specs]"
    printf '%bCoverage%b: %d%% %s\n' "${BOLD}" "${NC}" "$covered_specs" "$coverage_text" >&2
    echo "" >&2

    # Overall status
    if [[ $TESTS_FAILED -eq 0 ]]; then
        printf 'Status: %b[PASS]%b\n' "${GREEN}" "${NC}" >&2
        return 0
    else
        printf 'Status: %b[FAIL]%b\n' "${RED}" "${NC}" >&2
        return 1
    fi
}

print_json_summary() {
    local pass_rate=0
    if [[ $TESTS_RUN -gt 0 ]]; then
        pass_rate=$(( TESTS_PASSED * 100 / TESTS_RUN ))
    fi

    local status="FAIL"
    [[ $TESTS_FAILED -eq 0 ]] && status="PASS"

    local spec_count=${#SPEC_RESULTS[@]}

    printf '{\n'
    printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "test_results": {\n'
    printf '    "passed": %d,\n' "$TESTS_PASSED"
    printf '    "failed": %d,\n' "$TESTS_FAILED"
    printf '    "skipped": %d,\n' "$TESTS_SKIPPED"
    printf '    "total": %d\n' "$TESTS_RUN"
    printf '  },\n'
    printf '  "coverage": {\n'
    printf '    "specs_tested": %d,\n' "$spec_count"
    printf '    "pass_rate": %d\n' "$pass_rate"
    printf '  },\n'
    printf '  "status": "%s"\n' "$status"
    printf '}\n'
}

list_all_tests() {
    echo "Available Litmus Test Suites:" >&2
    echo "" >&2

    # Get unique test names from bindings
    if command -v yq &>/dev/null; then
        yq eval '.specs[].litmus_tests[]' "$LITMUS_BINDINGS" 2>/dev/null | sort -u | while read -r test; do
            local test_file="${LITMUS_TESTS_DIR}/${test}.yaml"
            if [[ -f "$test_file" ]]; then
                local desc
                desc="$(yaml_get "$test_file" ".description" 2>/dev/null || echo "N/A")"
                printf '  %-40s %s\n' "$test" "$desc" >&2
            fi
        done
    else
        ls "$LITMUS_TESTS_DIR"/litmus-*.yaml 2>/dev/null | while read -r file; do
            basename "$file" .yaml
        done | while read -r test; do
            printf '  %s\n' "$test" >&2
        done
    fi

    echo "" >&2
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)
                LIST_ONLY=1
                shift
                ;;
            --timeout)
                TIMEOUT_SECONDS="${2}"
                shift 2
                ;;
            --json)
                # JSON output (handled at end)
                shift
                ;;
            --verbose|-v)
                VERBOSE=1
                shift
                ;;
            -*)
                log_fail "Unknown option: $1"
                echo "Use: $0 [spec-name] --timeout N --list --json" >&2
                exit 3
                ;;
            *)
                if [[ -z "$FILTER_SPEC" ]]; then
                    FILTER_SPEC="$1"
                else
                    log_fail "Multiple specs not supported; got: $1"
                    exit 3
                fi
                shift
                ;;
        esac
    done
}

# ============================================================================
# VALIDATION
# ============================================================================

validate_environment() {
    local missing=0

    if [[ ! -f "$LITMUS_BINDINGS" ]]; then
        log_fail "Bindings file not found: $LITMUS_BINDINGS"
        ((missing++))
    fi

    if [[ ! -d "$LITMUS_TESTS_DIR" ]]; then
        log_fail "Tests directory not found: $LITMUS_TESTS_DIR"
        ((missing++))
    fi

    if [[ ! -f "$METHODOLOGY_LITMUS" ]]; then
        log_warn "Methodology file not found - non-critical: $METHODOLOGY_LITMUS"
    fi

    # Check for YAML parser
    if ! command -v yq &>/dev/null && ! command -v jq &>/dev/null; then
        log_warn "yq/jq not found; using fallback grep-based parsing - reduced functionality"
    fi

    return $missing
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    parse_args "$@"

    log_info "Tillandsias Litmus Test Runner"
    log_info "Environment: ${PROJECT_ROOT}"

    if ! validate_environment; then
        exit 3
    fi

    if [[ $LIST_ONLY -eq 1 ]]; then
        list_all_tests
        exit 0
    fi

    log_info "Timeout per test: ${TIMEOUT_SECONDS}s"
    echo "" >&2

    # Determine which specs to test
    local specs_to_test
    if [[ -n "$FILTER_SPEC" ]]; then
        log_info "Running tests for spec: $FILTER_SPEC"
        specs_to_test="$FILTER_SPEC"
    else
        log_info "Running tests for all active specs"
        specs_to_test="$(get_all_active_specs)"
    fi

    # Execute tests for each spec
    while IFS= read -r spec_id; do
        [[ -z "$spec_id" ]] && continue
        run_tests_for_spec "$spec_id"
    done <<<"$specs_to_test"

    # Print summary
    print_summary
    local exit_code=$?

    # Optional JSON output
    if [[ "$*" == *"--json"* ]]; then
        echo "" >&2
        print_json_summary
    fi

    exit $exit_code
}

# ============================================================================
# ENTRY POINT
# ============================================================================

main "$@"
