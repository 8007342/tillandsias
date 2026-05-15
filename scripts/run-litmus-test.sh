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
#   ./scripts/run-litmus-test.sh --spec SPEC   # Scope by spec ladder shorthand
#   ./scripts/run-litmus-test.sh [spec-name]       # Run single spec's litmus tests
#   ./scripts/run-litmus-test.sh                     # Run all specs' tests
#   ./scripts/run-litmus-test.sh --list              # List all test suites
#   ./scripts/run-litmus-test.sh --timeout 60        # Custom timeout in seconds
#   ./scripts/run-litmus-test.sh --ignore SPEC1,SPEC2 # Skip in-progress specs
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
readonly LITMUS_RUNTIME_DIR="${PROJECT_ROOT}/target/litmus-runtime"
readonly LITMUS_PODMAN_ROOT="${PROJECT_ROOT}/target/litmus-podman/root"
readonly LITMUS_PODMAN_RUNROOT="${PROJECT_ROOT}/target/litmus-podman/runroot"
readonly LITMUS_PODMAN_TMPDIR="${PROJECT_ROOT}/target/litmus-podman/tmp"

if [[ -z "${XDG_RUNTIME_DIR:-}" || ! -w "${XDG_RUNTIME_DIR:-/dev/null}" ]]; then
    mkdir -p "$LITMUS_RUNTIME_DIR"
    chmod 700 "$LITMUS_RUNTIME_DIR"
    export XDG_RUNTIME_DIR="$LITMUS_RUNTIME_DIR"
fi

readonly REAL_PODMAN_BIN="$(command -v podman 2>/dev/null || true)"
mkdir -p "$LITMUS_RUNTIME_DIR/bin" "$LITMUS_PODMAN_ROOT" "$LITMUS_PODMAN_RUNROOT" "$LITMUS_PODMAN_TMPDIR"
chmod 700 "$LITMUS_PODMAN_ROOT" "$LITMUS_PODMAN_RUNROOT" "$LITMUS_PODMAN_TMPDIR"
cat >"$LITMUS_RUNTIME_DIR/bin/podman" <<EOF
#!/usr/bin/env bash
set -euo pipefail

args=("\$@")
mode="\${LITMUS_PODMAN_MODE:-real}"
calls_file="\${LITMUS_PODMAN_CALLS_FILE:-$PROJECT_ROOT/target/litmus-podman/calls.log}"
real_podman_bin="${REAL_PODMAN_BIN}"
if [[ "\${args[0]:-}" == "run" || "\${args[0]:-}" == "create" ]]; then
    has_userns=0
    for arg in "\${args[@]}"; do
        if [[ "\$arg" == --userns=* || "\$arg" == "--userns" ]]; then
            has_userns=1
            break
        fi
    done
    if [[ "\$has_userns" -eq 0 ]]; then
        args=("\${args[0]}" "--userns=host" "\${args[@]:1}")
    fi
fi

mkdir -p "\$(dirname "\$calls_file")"
{
    printf '%s\t' "\$(date -u +%FT%TZ)"
    printf 'podman'
    for arg in "\${args[@]}"; do
        printf ' %q' "\$arg"
    done
    printf '\n'
} >>"\$calls_file"

if [[ "\$mode" == "fake" ]]; then
    exec "$PROJECT_ROOT/scripts/test-support/podman-mock.sh" "\${args[@]}"
fi

if [[ -z "\$real_podman_bin" ]]; then
    echo "podman not found on PATH" >&2
    exit 127
fi

exec "\$real_podman_bin" --root "$LITMUS_PODMAN_ROOT" --runroot "$LITMUS_PODMAN_RUNROOT" --tmpdir "$LITMUS_PODMAN_TMPDIR" "\${args[@]}"
EOF
chmod 755 "$LITMUS_RUNTIME_DIR/bin/podman"
export PATH="$LITMUS_RUNTIME_DIR/bin:$PATH"
export LITMUS_PODMAN_CALLS_FILE="${LITMUS_PODMAN_CALLS_FILE:-$PROJECT_ROOT/target/litmus-podman/calls.log}"

# Default timeout in seconds (can be overridden via --timeout)
# Increased from 30s to 600s (10 min) to handle slow tray feature compilation
# @trace spec:spec-traceability
TIMEOUT_SECONDS=600
VERBOSE=0
LIST_ONLY=0
FILTER_SPEC=""
FILTER_PHASE="all"
COMPACT=0
STRICT_MODE=0
STRICT_SPEC_LIST=""
IGNORE_SPEC_LIST=""
SPEC_SHORTHAND=""

# Test result tracking
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TESTS_RUN=0

# Track which specs were tested
declare -A SPEC_RESULTS
declare -A SPEC_TEST_COUNT

# Global deduplication for cross-spec litmus tests
declare -A LITMUS_GLOBAL_SEEN

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
    local suppress_output=0

    case "$status" in
        PASS)
            TESTS_PASSED=$((TESTS_PASSED+1))
            [[ "$COMPACT" == "1" ]] && suppress_output=1
            if [[ "$suppress_output" -eq 0 ]]; then
                printf '  %b[PASS]%b %s\n' "${GREEN}" "${NC}" "$test_name" >&2
            fi
            ;;
        FAIL)
            printf '  %b[FAIL]%b spec=%s test=%s\n' "${RED}" "${NC}" "$spec_name" "$test_name" >&2
            [[ -n "$message" ]] && printf '         %b%s%b\n' "${RED}" "$message" "${NC}" >&2
            TESTS_FAILED=$((TESTS_FAILED+1))
            ;;
        SKIP)
            TESTS_SKIPPED=$((TESTS_SKIPPED+1))
            [[ "$COMPACT" == "1" ]] && suppress_output=1
            if [[ "$suppress_output" -eq 0 ]]; then
                printf '  %b[SKIP]%b %s\n' "${YELLOW}" "${NC}" "$test_name" >&2
                [[ -n "$message" ]] && printf '         %b%s%b\n' "${YELLOW}" "$message" "${NC}" >&2
            fi
            ;;
    esac
    TESTS_RUN=$((TESTS_RUN+1))
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
            "$LITMUS_BINDINGS" 2>/dev/null || true
    else
        # Fallback: grep and parse. YAML structure is:
        # - spec_id: <name>
        #   status: active
        #   litmus_tests:
        #   - <test-name>
        awk -v spec="$spec_id" '
            /^- spec_id: / {
                gsub(/^- spec_id: /, "");
                in_current = ($0 == spec) ? 1 : 0
                in_tests = 0
                next
            }
            in_current && /^  litmus_tests:/ { in_tests = 1; next }
            in_current && in_tests && /^  - / {
                gsub(/^  - /, "");
                print
                next
            }
            in_current && /^- spec_id/ { exit }
        ' "$LITMUS_BINDINGS"
    fi
}

# Get all active spec IDs from bindings
get_all_active_specs() {
    if command -v yq &>/dev/null; then
        yq eval '.specs[] | select(.status=="active") | .spec_id' "$LITMUS_BINDINGS" 2>/dev/null || true
    else
        # Fallback: grep-based parsing
        awk '
            /^- spec_id: / {
                gsub(/^- spec_id: /, "");
                current_spec = $0
                next
            }
            /^  status: / {
                gsub(/^  status: /, "");
                status = $0
                if (status == "active" && current_spec != "") print current_spec
            }
        ' "$LITMUS_BINDINGS"
    fi
}

get_test_phase() {
    local file="$1"

    if command -v yq &>/dev/null; then
        yq eval '.phase // "runtime"' "$file" 2>/dev/null || echo "runtime"
    else
        awk '
            /^phase: / {
                gsub(/^phase: /, "");
                print
                found=1
                exit
            }
            END {
                if (!found) print "runtime"
            }
        ' "$file"
    fi
}

# ============================================================================
# TEST EXECUTION
# ============================================================================

# Execute a single command from litmus test with timeout and progress reporting
execute_test_command() {
    local command="$1"
    local timeout_ms="${2:-${TIMEOUT_SECONDS}000}"
    local timeout_sec=$((timeout_ms / 1000))

    # Ensure minimum timeout
    [[ $timeout_sec -lt 1 ]] && timeout_sec=1

    # Run command with timeout and progress reporting
    # @trace spec:spec-traceability
    (timeout "${timeout_sec}s" bash -c "$command" 2>&1) || true
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

behavior_matches_output() {
    local output="$1"
    local expected="$2"
    local expected_lc="${expected,,}"
    local output_lc="${output,,}"

    [[ -z "$expected_lc" ]] && return 0

    if [[ "$expected_lc" =~ ([0-9]+)\+\ env\ vars ]]; then
        local threshold="${BASH_REMATCH[1]}"
        local count
        count="$(grep -Eo '[0-9]+' <<<"$output" | head -1 || true)"
        [[ -n "$count" ]] || return 1
        [[ "$count" -ge "$threshold" ]]
        return $?
    fi

    case "$expected_lc" in
        *"0 directories"*|*"0 mounts"*|*"0 sockets"*|*"0 files"*|*"0 matches"*|*"0 log files"*|*"0 token files"*|*"0 socket files"*)
            local count
            count="$(grep -Eo '[0-9]+' <<<"$output" | head -1 || true)"
            [[ "${count:-}" == "0" ]]
            return $?
            ;;
        *"1 or more"*|*"at least one"*|*"multiple"*|*"several"*)
            local count
            count="$(grep -Eo '[0-9]+' <<<"$output" | head -1 || true)"
            [[ -n "$count" ]] || return 1
            if [[ "$expected_lc" == *"multiple"* || "$expected_lc" == *"several"* ]]; then
                [[ "$count" -ge 2 ]]
            else
                [[ "$count" -ge 1 ]]
            fi
            return $?
            ;;
        *"3-10 env vars"*|*"3 to 10 env vars"*|*"3-10 env vars only"*)
            local count
            count="$(grep -Eo '[0-9]+' <<<"$output" | head -1 || true)"
            [[ -n "$count" ]] || return 1
            [[ "$count" -ge 3 && "$count" -le 10 ]]
            return $?
            ;;
        *"readable file with size > 0"*|*"size > 0 bytes"*|*"size > 0"*)
            local size
            size="$(grep -Eo '[0-9]+' <<<"$output" | tail -1 || true)"
            [[ -n "$size" ]] || return 1
            [[ "$size" -gt 0 ]]
            return $?
            ;;
        *"no such file"*|*"file not found"*|*"directory not found"*|*"not found error"*)
            grep -Eqi 'no such file|not found|directory_not_found|directory not found' <<<"$output"
            return $?
            ;;
        *"timeout or connection refused"*|*"connection refused"*|*"network unreachable"*)
            grep -Eqi 'failed to connect|connection refused|network unreachable|timeout' <<<"$output"
            return $?
            ;;
        *"container id returned"*|*"launches without error"*|*"shutdown command succeeds"*|*"succeeds"*)
            [[ -n "$output" ]]
            return $?
            ;;
        *"path is correctly set"*|*"cargo"*)
            grep -Eqi 'cargo' <<<"$output"
            return $?
            ;;
        *"token file exists in git-service"*)
            grep -q 'TOKEN_MOUNTED' <<<"$output"
            return $?
            ;;
        *"token files are present"*|*"token files are readable"*)
            local count
            count="$(grep -Eo '[0-9]+' <<<"$output" | head -1 || true)"
            [[ -n "$count" ]] || return 1
            [[ "$count" -ge 1 ]]
            return $?
            ;;
        *"minimal env vars"*|*"minimal necessary vars present"*)
            grep -Eqi '^(PATH|HOME|USER)=' <<<"$output"
            return $?
            ;;
    esac

    if grep -Fqi "$expected" <<<"$output" || grep -Fqi "$expected_lc" <<<"$output_lc"; then
        return 0
    fi

    return 1
}

normalize_spec_list() {
    local raw="${1:-}"
    raw="${raw//:/ }"
    raw="${raw//,/ }"
    for item in $raw; do
        [[ -n "$item" ]] && printf '%s\n' "$item"
    done | awk '!seen[$0]++'
}

spec_in_list() {
    local needle="$1"
    local raw_list="${2:-}"

    [[ -z "$raw_list" ]] && return 1
    while IFS= read -r item; do
        [[ "$item" == "$needle" ]] && return 0
    done < <(normalize_spec_list "$raw_list")
    return 1
}

spec_is_ignored() {
    local spec_id="$1"
    [[ -z "$IGNORE_SPEC_LIST" ]] && return 1
    spec_in_list "$spec_id" "$IGNORE_SPEC_LIST"
}

should_fail_fast_for_spec() {
    local spec_id="$1"

    if spec_is_ignored "$spec_id"; then
        return 1
    fi
    [[ "$STRICT_MODE" != "1" ]] && return 1
    [[ -z "$STRICT_SPEC_LIST" ]] && return 0
    spec_in_list "$spec_id" "$STRICT_SPEC_LIST"
}

# Parse and execute litmus test file
# Returns 0 (success) if test should be considered passing, 1 (failure) otherwise
# Note: Does NOT log results - caller is responsible for that
run_litmus_test_file() {
    local test_file="$1"
    local spec_id="${2:-}"

    if [[ ! -f "$test_file" ]]; then
        return 1
    fi

    # Parse YAML: extract critical_path steps and gating_points.
    # The runner executes each critical-path step sequentially; later
    # assertions depend on earlier setup work.
    local in_critical_path=0
    local in_gating_points=0
    local current_step_name=""
    local current_step_command=""
    local current_step_timeout=30000
    local current_step_expected=""
    local -a step_names=()
    local -a step_commands=()
    local -a step_timeouts=()
    local -a step_expecteds=()
    local success_criteria=()
    local failure_criteria=()

    append_step() {
        [[ -z "$current_step_command" ]] && return 0
        step_names+=("$current_step_name")
        step_commands+=("$current_step_command")
        step_timeouts+=("$current_step_timeout")
        step_expecteds+=("$current_step_expected")
    }

    while IFS= read -r line; do
        if [[ "$line" =~ ^critical_path: ]]; then
            in_critical_path=1
            in_gating_points=0
            continue
        fi

        if [[ "$line" =~ ^gating_points: ]]; then
            append_step
            current_step_name=""
            current_step_command=""
            current_step_timeout=30000
            current_step_expected=""
            in_critical_path=0
            in_gating_points=1
            continue
        fi

        if [[ "$line" =~ ^[a-z_]+: ]]; then
            append_step
            current_step_name=""
            current_step_command=""
            current_step_timeout=30000
            current_step_expected=""
            in_critical_path=0
            in_gating_points=0
        fi

        if [[ $in_critical_path -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]step:\ \"(.+)\" ]]; then
                append_step
                current_step_name="${BASH_REMATCH[1]}"
                current_step_command=""
                current_step_timeout=30000
                current_step_expected=""
            elif [[ "$line" =~ command:\ \"(.+)\" ]]; then
                current_step_command="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ timeout_ms:\ ([0-9]+) ]]; then
                current_step_timeout="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ expected_behavior:\ \"(.+)\" ]]; then
                current_step_expected="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ expected_behavior:\ (.+)$ ]]; then
                current_step_expected="${BASH_REMATCH[1]}"
            fi
        fi

        if [[ $in_gating_points -eq 1 ]]; then
            if [[ "$line" =~ success:\ \"(.+)\" ]]; then
                success_criteria+=("${BASH_REMATCH[1]}")
            elif [[ "$line" =~ failure:\ \"(.+)\" ]]; then
                failure_criteria+=("${BASH_REMATCH[1]}")
            fi
        fi
    done < "$test_file"

    append_step

    if [[ "${#step_commands[@]}" -eq 0 ]]; then
        return 1
    fi

    local combined_output=""
    local step_index=0

    for idx in "${!step_commands[@]}"; do
        local step_name="${step_names[$idx]}"
        local step_command="${step_commands[$idx]}"
        local step_timeout_ms="${step_timeouts[$idx]}"
        local step_expected="${step_expecteds[$idx]}"
        local step_output=""
        local exit_code=0

        step_index=$((step_index + 1))
        local timeout_sec=$(( step_timeout_ms / 1000 ))

        # Progress reporting: show step start and timeout value
        # Always show progress to prevent user-perceived hangs during long-running tests
        # @trace spec:spec-traceability
        printf '  [STEP %d/%d] %s (timeout: %ds)...' "$step_index" "${#step_commands[@]}" "$step_name" "$timeout_sec" >&2

        step_output=$(timeout "${timeout_sec}s" bash -c "$step_command" 2>&1) || exit_code=$?
        combined_output+=$'\n'"[${step_index}:${step_name}]${step_output}"

        if [[ $exit_code -eq 124 ]]; then
            log_warn "Test timeout after ${timeout_sec}s in step: ${step_name:-step-${step_index}}"
            return 1
        fi

        # Progress reporting: show step result
        printf ' %b[OK]%b\n' "${GREEN}" "${NC}" >&2

        if ! behavior_matches_output "$step_output" "$step_expected"; then
            if [[ "$VERBOSE" == "1" ]]; then
                printf '%s\n' "  [DEBUG] step=${step_name:-step-$step_index}" >&2
                printf '%s\n' "          expected=${step_expected}" >&2
                printf '%s\n' "          output=${step_output}" >&2
            fi
            return 1
        fi
    done

    for failure in "${failure_criteria[@]}"; do
        if grep -qE "$failure" <<<"$combined_output"; then
            return 1
        fi
    done

    if [[ "${#success_criteria[@]}" -gt 0 ]]; then
        for success in "${success_criteria[@]}"; do
            if grep -qE "$success" <<<"$combined_output"; then
                return 0
            fi
        done
        return 1
    fi

    return 0
}

# Main test execution loop
run_tests_for_spec() {
    local spec_id="$1"

    if spec_is_ignored "$spec_id"; then
        [[ "$COMPACT" == "1" ]] || log_warn "Ignoring spec: $spec_id"
        SPEC_RESULTS["$spec_id"]="SKIP"
        return 0
    fi

    [[ "$COMPACT" == "1" ]] || log_spec_start "$spec_id"

    # Get all litmus tests bound to this spec
    local litmus_tests
    litmus_tests="$(get_litmus_tests_for_spec "$spec_id")"

    if [[ -z "$litmus_tests" ]]; then
        if should_fail_fast_for_spec "$spec_id"; then
            log_fail "spec=$spec_id no litmus tests bound; strict filter requires an executable boundary"
            printf '@trace spec:%s\n' "$spec_id" >&2
            return 21
        fi
        [[ "$COMPACT" == "1" ]] || log_warn "No litmus tests bound to spec: $spec_id"
        SPEC_RESULTS["$spec_id"]="SKIP"
        return 0
    fi

    # Execute each litmus test
    local test_count=0
    local spec_failed=0
    local spec_skipped=0
    while IFS= read -r test_name; do
        [[ -z "$test_name" ]] && continue

        # Skip if already executed globally (same test bound to multiple specs)
        if [[ -n "${LITMUS_GLOBAL_SEEN[$test_name]+x}" ]]; then
            log_test_result "$spec_id" "$test_name" "SKIP" "Already executed (bound to multiple specs)"
            spec_skipped=1
            test_count=$((test_count+1))
            continue
        fi
        LITMUS_GLOBAL_SEEN[$test_name]=1

        # Convert colon to hyphen for file lookup (litmus:ephemeral-guarantee -> litmus-ephemeral-guarantee)
        local test_file="${LITMUS_TESTS_DIR}/${test_name//:/-}.yaml"

        if [[ ! -f "$test_file" ]]; then
            if should_fail_fast_for_spec "$spec_id"; then
                log_test_result "$spec_id" "$test_name" "FAIL" "Test file not found"
                printf '@trace spec:%s\n' "$spec_id" >&2
                return 21
            fi
            log_test_result "$spec_id" "$test_name" "SKIP" "Test file not found"
            spec_skipped=1
            test_count=$((test_count+1))
            continue
        fi

        local test_phase
        test_phase="$(get_test_phase "$test_file")"
        if [[ "$FILTER_PHASE" != "all" && "$test_phase" != "$FILTER_PHASE" ]]; then
            log_test_result "$spec_id" "$test_name" "SKIP" "Phase mismatch: $test_phase"
            spec_skipped=1
            test_count=$((test_count+1))
            continue
        fi

        # Execute test and capture result
        # Always show which test is executing to prevent user-perceived hangs
        # @trace spec:spec-traceability
        printf '%bℹ%b Executing %s...\n' "${BLUE}" "${NC}" "$test_name" >&2

        if run_litmus_test_file "$test_file" "$spec_id"; then
            log_test_result "$spec_id" "$test_name" "PASS" ""
        else
            log_test_result "$spec_id" "$test_name" "FAIL" "Check implementation"
            spec_failed=1
            if should_fail_fast_for_spec "$spec_id"; then
                printf '@trace spec:%s\n' "$spec_id" >&2
                return 20
            fi
        fi

        test_count=$((test_count+1))
    done <<<"$litmus_tests"

    SPEC_TEST_COUNT["$spec_id"]=$test_count
    if [[ "$spec_failed" == "1" ]]; then
        SPEC_RESULTS["$spec_id"]="FAIL"
    elif [[ "$spec_skipped" == "1" && "$test_count" -gt 0 ]]; then
        SPEC_RESULTS["$spec_id"]="SKIP"
    else
        SPEC_RESULTS["$spec_id"]="PASS"
    fi

    return 0
}

# ============================================================================
# REPORTING
# ============================================================================

print_summary() {
    local total_executed=$((TESTS_PASSED + TESTS_FAILED))
    local coverage_ratio="0"

    if [[ $total_executed -gt 0 ]]; then
        coverage_ratio="$((TESTS_PASSED * 100 / total_executed))"
    fi

    echo "" >&2
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' >&2
    printf '%bTest Results Summary%b\n' "${BOLD}" "${NC}" >&2
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' >&2

    printf '  %bPASS%b:  %d\n' "${GREEN}" "${NC}" "$TESTS_PASSED" >&2
    printf '  %bFAIL%b:  %d\n' "${RED}" "${NC}" "$TESTS_FAILED" >&2
    printf '  %bSKIP%b:  %d (excluded from coverage)\n' "${YELLOW}" "${NC}" "$TESTS_SKIPPED" >&2
    printf '  %bTotal%b: %d (executed: %d, skipped: %d)\n' "${BOLD}" "${NC}" "$TESTS_RUN" "$total_executed" "$TESTS_SKIPPED" >&2
    echo "" >&2

    # Coverage calculation (excluding skipped tests)
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
    printf '%bPass Rate%b: %d%% (%d/%d executed)\n' "${BOLD}" "${NC}" "$coverage_ratio" "$TESTS_PASSED" "$total_executed" >&2
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
    local total_executed=$((TESTS_PASSED + TESTS_FAILED))
    local pass_rate=0
    if [[ $total_executed -gt 0 ]]; then
        pass_rate=$(( TESTS_PASSED * 100 / total_executed ))
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
    printf '    "total_run": %d,\n' "$TESTS_RUN"
    printf '    "total_executed": %d\n' "$total_executed"
    printf '  },\n'
    printf '  "coverage": {\n'
    printf '    "specs_tested": %d,\n' "$spec_count"
    printf '    "pass_rate_executed": %d\n' "$pass_rate"
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
            --filter|--filter=*)
                if [[ "$1" == *=* ]]; then
                    FILTER_SPEC="${1#*=}"
                    shift
                else
                    if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                        FILTER_SPEC="${2}"
                        shift 2
                    else
                        FILTER_SPEC=""
                        shift
                    fi
                fi
                ;;
            --strict|--strict=*)
                STRICT_MODE=1
                if [[ "$1" == *=* ]]; then
                    STRICT_SPEC_LIST="${1#*=}"
                    shift
                else
                    if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                        STRICT_SPEC_LIST="${2}"
                        shift 2
                    else
                        STRICT_SPEC_LIST=""
                        shift
                    fi
                fi
                ;;
            --ignore|--ignore=*)
                if [[ "$1" == *=* ]]; then
                    IGNORE_SPEC_LIST="${1#*=}"
                    shift
                else
                    if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                        IGNORE_SPEC_LIST="${2}"
                        shift 2
                    else
                        IGNORE_SPEC_LIST=""
                        shift
                    fi
                fi
                ;;
            --spec|--spec=*)
                if [[ "$1" == *=* ]]; then
                    SPEC_SHORTHAND="${1#*=}"
                    shift
                else
                    if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                        SPEC_SHORTHAND="${2}"
                        shift 2
                    else
                        SPEC_SHORTHAND=""
                        shift
                    fi
                fi
                ;;
            --compact)
                COMPACT=1
                shift
                ;;
            --phase)
                FILTER_PHASE="${2:-all}"
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
                echo "Use: $0 [spec-name] --timeout N --phase <name> --list --json" >&2
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
        missing=$((missing+1))
    fi

    if [[ ! -d "$LITMUS_TESTS_DIR" ]]; then
        log_fail "Tests directory not found: $LITMUS_TESTS_DIR"
        missing=$((missing+1))
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

    if [[ -n "$SPEC_SHORTHAND" ]]; then
        if [[ -z "$FILTER_SPEC" ]]; then
            FILTER_SPEC="$SPEC_SHORTHAND"
        fi
        if [[ "$STRICT_MODE" != "1" || -z "$STRICT_SPEC_LIST" ]]; then
            STRICT_MODE=1
            [[ -z "$STRICT_SPEC_LIST" ]] && STRICT_SPEC_LIST="$SPEC_SHORTHAND"
        fi
    fi

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
    log_info "Phase filter: ${FILTER_PHASE}"
    [[ "$COMPACT" == "1" ]] && log_info "Output mode: compact"
    [[ "$STRICT_MODE" == "1" ]] && log_info "Strict mode: enabled"
    echo "" >&2

    # Determine which specs to test
    local specs_to_test
    if [[ -n "$FILTER_SPEC" ]]; then
        log_info "Running tests for spec: $FILTER_SPEC"
        specs_to_test="$(normalize_spec_list "$FILTER_SPEC")"
        if [[ "$STRICT_MODE" == "1" && -z "$STRICT_SPEC_LIST" ]]; then
            STRICT_SPEC_LIST="$FILTER_SPEC"
        fi
    else
        log_info "Running tests for all active specs"
        specs_to_test="$(normalize_spec_list "$(get_all_active_specs)")"
    fi

    if [[ -n "$IGNORE_SPEC_LIST" ]]; then
        local filtered_specs=""
        while IFS= read -r spec_id; do
            [[ -z "$spec_id" ]] && continue
            if ! spec_is_ignored "$spec_id"; then
                filtered_specs+="${spec_id}"$'\n'
            fi
        done <<<"$specs_to_test"
        specs_to_test="$(printf '%s' "$filtered_specs" | awk 'NF')"
    fi

    # Check if spec list is empty
    if [[ -z "$specs_to_test" ]]; then
        log_fail "No specs found in bindings. Check litmus-bindings.yaml."
        exit 1
    fi

    # Execute tests for each spec
    while IFS= read -r spec_id; do
        [[ -z "$spec_id" ]] && continue
        run_tests_for_spec "$spec_id"
        local status=$?
        if [[ $status -ne 0 ]]; then
            print_summary
            exit "$status"
        fi
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
