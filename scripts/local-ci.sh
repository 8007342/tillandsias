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
#   scripts/local-ci.sh --spec SPEC   # Scope litmus phases to a spec ladder
#   scripts/local-ci.sh --strict-all --ignore SPEC1,SPEC2
#                                    # Frontier-scan while skipping in-progress specs

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/scripts/common.sh"

# Parse flags
FAST_MODE=0
VERBOSE=0
CI_PHASE="all"
CI_FILTER_SPEC_LIST=""
CI_STRICT_SPEC_LIST=""
CI_IGNORE_SPEC_LIST=""
CI_SPEC_LIST=""
STRICT_ALL=0
CI_STOP_ON_FAILURE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fast) FAST_MODE=1; shift ;;
        --verbose) VERBOSE=1; shift ;;
        --filter)
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                CI_FILTER_SPEC_LIST="${2}"
                shift 2
            else
                CI_FILTER_SPEC_LIST=""
                shift
            fi
            CI_STOP_ON_FAILURE=1
            ;;
        --filter=*)
            CI_FILTER_SPEC_LIST="${1#*=}"
            CI_STOP_ON_FAILURE=1
            shift
            ;;
        --strict)
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                CI_STRICT_SPEC_LIST="${2}"
                shift 2
            else
                CI_STRICT_SPEC_LIST=""
                shift
            fi
            CI_STOP_ON_FAILURE=1
            ;;
        --strict=*)
            CI_STRICT_SPEC_LIST="${1#*=}"
            CI_STOP_ON_FAILURE=1
            shift
            ;;
        --ignore)
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                CI_IGNORE_SPEC_LIST="${2}"
                shift 2
            else
                CI_IGNORE_SPEC_LIST=""
                shift
            fi
            CI_STOP_ON_FAILURE=1
            ;;
        --ignore=*)
            CI_IGNORE_SPEC_LIST="${1#*=}"
            CI_STOP_ON_FAILURE=1
            shift
            ;;
        --strict-all)
            STRICT_ALL=1
            CI_STOP_ON_FAILURE=1
            shift
            ;;
        --spec)
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                CI_SPEC_LIST="${2}"
                shift 2
            else
                CI_SPEC_LIST=""
                shift
            fi
            CI_STOP_ON_FAILURE=1
            ;;
        --spec=*)
            CI_SPEC_LIST="${1#*=}"
            CI_STOP_ON_FAILURE=1
            shift
            ;;
        --phase)
            CI_PHASE="${2:-all}"
            shift 2
            ;;
        *) echo "Unknown flag: $1"; exit 2 ;;
    esac
done

if [[ -n "$CI_STRICT_SPEC_LIST" && -z "$CI_FILTER_SPEC_LIST" ]]; then
    CI_FILTER_SPEC_LIST="$CI_STRICT_SPEC_LIST"
fi
if [[ -n "$CI_SPEC_LIST" ]]; then
    if [[ -z "$CI_FILTER_SPEC_LIST" ]]; then
        CI_FILTER_SPEC_LIST="$CI_SPEC_LIST"
    fi
    if [[ -z "$CI_STRICT_SPEC_LIST" ]]; then
        CI_STRICT_SPEC_LIST="$CI_SPEC_LIST"
    fi
fi

if [[ -n "$CI_IGNORE_SPEC_LIST" ]]; then
    export TILLANDSIAS_STRICT_IGNORE_SPECS="$CI_IGNORE_SPEC_LIST"
fi

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

get_all_active_specs() {
    if command -v yq &>/dev/null; then
        yq eval '.specs[] | select(.status=="active") | .spec_id' "$REPO_ROOT/openspec/litmus-bindings.yaml" 2>/dev/null || true
    else
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
        ' "$REPO_ROOT/openspec/litmus-bindings.yaml"
    fi
}

if [[ "$STRICT_ALL" == "1" ]]; then
    STRICT_LIST="$(get_all_active_specs)"
    if [[ -n "${CI_IGNORE_SPEC_LIST:-}" ]]; then
        filtered_list=""
        while IFS= read -r spec_id; do
            [[ -z "$spec_id" ]] && continue
            if ! spec_in_list "$spec_id" "$CI_IGNORE_SPEC_LIST"; then
                filtered_list+="${spec_id}"$'\n'
            fi
        done <<<"$STRICT_LIST"
        STRICT_LIST="$(printf '%s' "$filtered_list" | awk 'NF')"
    fi
    if [[ -n "$STRICT_LIST" ]]; then
        CI_FILTER_SPEC_LIST="$STRICT_LIST"
        CI_STRICT_SPEC_LIST="$STRICT_LIST"
    fi
fi

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
RUNTIME_STATUS_FILE="$SIGNATURE_DIR/runtime-phase.status"
CHECK_LOG_DIR="$SIGNATURE_DIR/check-logs"
CHECK_LOG_INDEX="$SIGNATURE_DIR/check-logs.jsonl"
VERSION_VALUE="$(cat VERSION 2>/dev/null || echo "0.0.0.0")"
SOURCE_COMMIT="$(git rev-parse --short=12 HEAD 2>/dev/null || echo "unknown")"
CI_RUN_ID="local-ci-$(date -u +%Y%m%dT%H%M%SZ)"
CI_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

CHECK_IDS=(
    spec-cheatsheet-binding
    spec-code-drift
    spec-trace-coverage
    version-monotonicity
    rust-formatting
    rust-clippy
    rust-tests
    container-base-policy
    cheatsheet-tiers
    litmus-tests
)

case "$CI_PHASE" in
    pre-build)
        if [[ "$FAST_MODE" == "1" ]]; then
            CHECK_IDS=(
                spec-cheatsheet-binding
                spec-code-drift
                spec-trace-coverage
                version-monotonicity
                rust-formatting
                rust-clippy
                rust-tests
                container-base-policy
                cheatsheet-tiers
            )
        else
            CHECK_IDS=(
                spec-cheatsheet-binding
                spec-code-drift
                spec-trace-coverage
                version-monotonicity
                rust-formatting
                rust-clippy
                rust-tests
                container-base-policy
                cheatsheet-tiers
                litmus-pre-build
            )
        fi
        ;;
    post-build)
        CHECK_IDS=(
            litmus-post-build
        )
        ;;
    runtime)
        CHECK_IDS=(
            litmus-runtime
        )
        ;;
    all)
        CHECK_IDS=(
            spec-cheatsheet-binding
            spec-code-drift
            spec-trace-coverage
            version-monotonicity
            rust-formatting
            rust-clippy
            rust-tests
            container-base-policy
            cheatsheet-tiers
            litmus-pre-build
            litmus-post-build
            litmus-runtime
        )
        ;;
    *)
        echo "Unknown --phase value: $CI_PHASE" >&2
        exit 2
        ;;
esac

check_weight() {
    case "$1" in
        spec-cheatsheet-binding) echo 100 ;;
        spec-code-drift) echo 120 ;;
        spec-trace-coverage) echo 90 ;;
        version-monotonicity) echo 40 ;;
        rust-formatting) echo 40 ;;
        rust-clippy) echo 60 ;;
        rust-tests) echo 80 ;;
        container-base-policy) echo 40 ;;
        cheatsheet-tiers) echo 80 ;;
        litmus-pre-build) echo 100 ;;
        litmus-post-build) echo 120 ;;
        litmus-runtime) echo 140 ;;
        litmus-tests) echo 140 ;;
        *) echo 0 ;;
    esac
}

check_spec_ref() {
    case "$1" in
        spec-cheatsheet-binding) echo "spec:spec-traceability" ;;
        spec-code-drift) echo "spec:spec-traceability" ;;
        spec-trace-coverage) echo "spec:methodology-accountability" ;;
        version-monotonicity) echo "spec:versioning" ;;
        rust-formatting) echo "spec:dev-build" ;;
        rust-clippy) echo "spec:dev-build" ;;
        rust-tests) echo "spec:testing" ;;
        container-base-policy) echo "spec:default-image" ;;
        cheatsheet-tiers) echo "spec:cheatsheet-source-layer" ;;
        litmus-pre-build) echo "spec:podman-orchestration" ;;
        litmus-post-build) echo "spec:dev-build" ;;
        litmus-runtime) echo "spec:litmus-convergence" ;;
        litmus-tests) echo "spec:litmus-convergence" ;;
        *) echo "spec:unknown" ;;
    esac
}

failed_reason_for_check() {
    local check_name="$1"
    case "$check_name" in
        spec-cheatsheet-binding) echo "Spec-cheatsheet binding below 90% (see /tmp/binding-check.log)" ;;
        spec-code-drift) echo "Spec-code drift detected: ghost traces or zero-trace specs found (see /tmp/drift-check.log)" ;;
        spec-trace-coverage) echo "Spec trace coverage below 90% (see /tmp/trace-coverage.log)" ;;
        version-monotonicity) echo "Version is not monotonically greater than last release (see /tmp/version-check.log)" ;;
        rust-formatting) echo "Rust code not formatted: run 'cargo fmt --all' (see /tmp/fmt-check.log)" ;;
        rust-clippy) echo "Clippy warnings found: run 'cargo clippy --workspace' to see details (see /tmp/clippy-check.log)" ;;
        rust-tests) echo "Test failures detected: run 'cargo test --workspace --lib' to see details (see /tmp/test-check.log)" ;;
        container-base-policy) echo "Container base-image policy drift found (see /tmp/container-bases.log)" ;;
        cheatsheet-tiers) echo "Cheatsheet tier errors or strict warnings found (see /tmp/cheatsheet-tiers.log)" ;;
        litmus-pre-build) echo "Pre-build litmus failures detected (see /tmp/litmus-pre-build.log)" ;;
        litmus-post-build) echo "Post-build smoke failures detected (see /tmp/litmus-post-build.log)" ;;
        litmus-runtime) echo "Runtime litmus failures detected (see /tmp/litmus-runtime.log)" ;;
        litmus-tests) echo "Litmus test failures detected (see /tmp/litmus-check.log)" ;;
        *) echo "Check failed: $check_name" ;;
    esac
}

litmus_args_for_phase() {
    local phase="$1"
    local -a args=(--phase "$phase" --compact)

    if [[ -n "$CI_FILTER_SPEC_LIST" ]]; then
        args+=(--filter "$CI_FILTER_SPEC_LIST")
    fi
    if [[ -n "$CI_STRICT_SPEC_LIST" ]]; then
        args+=(--strict "$CI_STRICT_SPEC_LIST")
    fi
    if [[ -n "$CI_IGNORE_SPEC_LIST" ]]; then
        args+=(--ignore "$CI_IGNORE_SPEC_LIST")
    fi

    printf '%s\0' "${args[@]}"
}

run_litmus_phase() {
    local phase="$1"
    local log_file="$2"
    shift 2

    local -a args=()
    while IFS= read -r -d '' arg; do
        args+=("$arg")
    done < <(litmus_args_for_phase "$phase")

    if bash scripts/run-litmus-test.sh "${args[@]}" 2>&1 | tee "$log_file"; then
        return 0
    fi

    return "${PIPESTATUS[0]}"
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
    local check_log_hash="n/a"
    local check_log_records=0
    if [[ -f "$CHECK_LOG_INDEX" ]]; then
        check_log_records="$(wc -l < "$CHECK_LOG_INDEX")"
        if command -v sha256sum >/dev/null 2>&1; then
            check_log_hash="$(sha256sum "$CHECK_LOG_INDEX" | awk '{print $1}')"
        elif command -v shasum >/dev/null 2>&1; then
            check_log_hash="$(shasum -a 256 "$CHECK_LOG_INDEX" | awk '{print $1}')"
        fi
    fi

    local signature_tmp
    signature_tmp="$(mktemp)"
    jq -nc \
        --arg timestamp "$CI_TIMESTAMP" \
        --arg version "$VERSION_VALUE" \
        --arg source_commit "$SOURCE_COMMIT" \
        --arg source_namespace "local_development" \
        --arg ci_run_id "$CI_RUN_ID" \
        --arg ci_phase "$CI_PHASE" \
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
          ci_phase:$ci_phase,
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
        --arg ci_phase "$CI_PHASE" \
        --arg signature_hash "$signature_hash" \
        --arg delta_hash "$delta_hash" \
        --arg check_log_index_ref "target/convergence/check-logs.jsonl" \
        --arg check_log_index_hash "$check_log_hash" \
        --arg dashboard_hash "n/a" \
        --arg ci_run_id "$CI_RUN_ID" \
        --argjson signature_records "$(wc -l < "$SIGNATURE_JSONL")" \
        --argjson delta_records 1 \
        --argjson check_log_records "$check_log_records" \
        --argjson project_cc_total "$total_cc" \
        --argjson project_cc_earned "$passed_cc" \
        --argjson residual_cc "$residual_cc" \
        --argjson check_count "${#CHECK_IDS[@]}" \
        '{
          generated_at:$timestamp,
          version:$version,
          source_commit:$source_commit,
          source_namespace:$source_namespace,
          ci_phase:$ci_phase,
          ci_run_id:$ci_run_id,
          signature_hash:$signature_hash,
          delta_hash:$delta_hash,
          check_log_index_ref:$check_log_index_ref,
          check_log_index_hash:$check_log_index_hash,
          centicolon_dashboard_hash:$dashboard_hash,
          signature_records:$signature_records,
          delta_records:$delta_records,
          check_log_records:$check_log_records,
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

run_rust_in_nix_develop() {
    local toolbox_name="${TOOLBOX_NAME:-tillandsias}"
    local repo_root="${REPO_ROOT}"
    local nix_cmd
    nix_cmd="mkdir -p \"$HOME/.cache/tillandsias/nix-store\" && cd $(printf '%q' "$repo_root") && nix --store \"local?root=$HOME/.cache/tillandsias/nix-store\" develop --extra-experimental-features nix-command --extra-experimental-features flakes --command"
    for arg in "$@"; do
        nix_cmd+=" $(printf '%q' "$arg")"
    done
    toolbox run -c "$toolbox_name" bash -lc "$nix_cmd"
}

sha256_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        echo "n/a"
    fi
}

archive_check_log() {
    local check_id="$1"
    local status="$2"
    local source_log="${3:-}"
    local archive_name="${4:-${check_id}.log}"

    mkdir -p "$CHECK_LOG_DIR"
    touch "$CHECK_LOG_INDEX"

    local archived_log="$CHECK_LOG_DIR/$archive_name"
    if [[ -n "$source_log" && -f "$source_log" ]]; then
        cp "$source_log" "$archived_log"
    else
        printf '%s\n' "$status" >"$archived_log"
    fi

    jq -nc \
        --arg ci_run_id "$CI_RUN_ID" \
        --arg ci_phase "$CI_PHASE" \
        --arg check_id "$check_id" \
        --arg status "$status" \
        --arg source_log "${source_log:-}" \
        --arg archived_log "$archived_log" \
        --arg sha256 "$(sha256_file "$archived_log")" \
        '{
          ci_run_id:$ci_run_id,
          ci_phase:$ci_phase,
          check_id:$check_id,
          status:$status,
          source_log:$source_log,
          archived_log:$archived_log,
          sha256:$sha256
        }' >>"$CHECK_LOG_INDEX"
}

podman_runtime_health_probe() {
    local probe_log="/tmp/litmus-runtime-health.log"
    local migrate_log="/tmp/litmus-runtime-migrate.log"
    local probe_image=""

    probe_image="$(podman images --format '{{.Repository}}:{{.Tag}}' | grep 'tillandsias-forge' | head -1 || true)"
    if [[ -z "$probe_image" ]]; then
        printf 'forge image not available\n' >"$probe_log"
        return 1
    fi

    if timeout 5 podman run --rm --userns=host "$probe_image" env \
        >/dev/null 2>"$probe_log"; then
        return 0
    fi

    if grep -Eqi 'newuidmap|read-only file system|acquiring runtime init lock|cannot set up namespace' "$probe_log"; then
        podman system migrate >"$migrate_log" 2>&1 || true
        if timeout 5 podman run --rm --userns=host "$probe_image" env \
            >/dev/null 2>>"$probe_log"; then
            return 0
        fi
    fi

    return 1
}

log_info "CI phase: ${CI_PHASE}"

# ============================================================================
# CHECK 1: Spec-cheatsheet binding validation
# ============================================================================

if [[ "$CI_PHASE" == "all" || "$CI_PHASE" == "pre-build" ]]; then
    log_section "Spec-Cheatsheet Binding (90% threshold)"
    if [[ -f "scripts/validate-spec-cheatsheet-binding-fast.sh" ]]; then
        if bash scripts/validate-spec-cheatsheet-binding-fast.sh 2>&1 | tee /tmp/binding-check.log; then
            log_pass "Spec-cheatsheet binding coverage ≥ 90%"
            archive_check_log "spec-cheatsheet-binding" "pass" /tmp/binding-check.log
        else
            log_fail_tracked "spec-cheatsheet-binding" "Spec-cheatsheet binding below 90% (see /tmp/binding-check.log)"
            [[ "$VERBOSE" == "1" ]] && cat /tmp/binding-check.log >&2
            archive_check_log "spec-cheatsheet-binding" "fail" /tmp/binding-check.log
        fi
    else
        log_skip "Spec-cheatsheet binding validator not found"
        archive_check_log "spec-cheatsheet-binding" "skipped"
    fi

    # ============================================================================
    # CHECK 2: Spec-code drift detection (CI mode)
    # ============================================================================

    log_section "Spec-Code Drift Detection (CI Mode)"
    if [[ -f "scripts/hooks/pre-commit-openspec.sh" ]]; then
        if bash scripts/hooks/pre-commit-openspec.sh --ci-mode 2>&1 | tee /tmp/drift-check.log; then
            log_pass "No ghost traces or zero-trace specs"
            archive_check_log "spec-code-drift" "pass" /tmp/drift-check.log
        else
            log_fail_tracked "spec-code-drift" "Spec-code drift detected: ghost traces or zero-trace specs found (see /tmp/drift-check.log)"
            [[ "$VERBOSE" == "1" ]] && cat /tmp/drift-check.log >&2
            archive_check_log "spec-code-drift" "fail" /tmp/drift-check.log
        fi
    else
        log_skip "Spec-code drift checker not found"
        archive_check_log "spec-code-drift" "skipped"
    fi

    # ============================================================================
    # CHECK 3: Spec trace coverage threshold (90%)
    # ============================================================================

    log_section "Spec Trace Coverage (90% threshold)"
    if [[ -f "scripts/validate-traces.sh" ]]; then
        coverage_output=$(bash scripts/validate-traces.sh --coverage-threshold 2>&1 | tee /tmp/trace-coverage.log)
        if [[ $? -eq 0 ]]; then
            # Extract coverage percentage from JSON output
            coverage_pct=$(echo "$coverage_output" | jq -r '.coverage_percentage // 0' 2>/dev/null || echo "unknown")
            log_pass "Spec trace coverage: $coverage_pct% (≥ 90%)"
            archive_check_log "spec-trace-coverage" "pass" /tmp/trace-coverage.log
        else
            log_fail_tracked "spec-trace-coverage" "Spec trace coverage below 90% (see /tmp/trace-coverage.log)"
            [[ "$VERBOSE" == "1" ]] && cat /tmp/trace-coverage.log >&2
            archive_check_log "spec-trace-coverage" "fail" /tmp/trace-coverage.log
        fi
    else
        log_skip "Trace coverage validator not found"
        archive_check_log "spec-trace-coverage" "skipped"
    fi

    # ============================================================================
    # CHECK 4: Version monotonicity enforcement
    # ============================================================================

    log_section "Version Monotonicity Check"
    if [[ -f "scripts/verify-version-monotonic.sh" ]]; then
        if bash scripts/verify-version-monotonic.sh 2>&1 | tee /tmp/version-check.log; then
            log_pass "Version is monotonically valid"
            archive_check_log "version-monotonicity" "pass" /tmp/version-check.log
        else
            log_fail_tracked "version-monotonicity" "Version is not monotonically greater than last release (see /tmp/version-check.log)"
            cat /tmp/version-check.log >&2
            archive_check_log "version-monotonicity" "fail" /tmp/version-check.log
        fi
    else
        log_skip "Version monotonicity checker not found"
        archive_check_log "version-monotonicity" "skipped"
    fi

    # ============================================================================
    # CHECK 5: Cargo checks (formatting, clippy, tests)
    # ============================================================================

    log_section "Rust Code Quality (fmt, clippy, tests)"

    # @trace spec:dev-build, spec:ci-release
    # Run cargo commands through nix develop inside the toolbox boundary.
    TOOLBOX_NAME="tillandsias"

    # Formatting check
    if run_rust_in_nix_develop cargo fmt --check --all 2>&1 | tee /tmp/fmt-check.log; then
        log_pass "Rust formatting valid"
        archive_check_log "rust-formatting" "pass" /tmp/fmt-check.log
    else
        log_fail_tracked "rust-formatting" "Rust code not formatted: run 'cargo fmt --all' (see /tmp/fmt-check.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/fmt-check.log >&2
        archive_check_log "rust-formatting" "fail" /tmp/fmt-check.log
    fi

    # Clippy check
    if run_rust_in_nix_develop cargo clippy --workspace -- -D warnings 2>&1 | tee /tmp/clippy-check.log; then
        log_pass "Clippy checks pass (no warnings)"
        archive_check_log "rust-clippy" "pass" /tmp/clippy-check.log
    else
        log_fail_tracked "rust-clippy" "Clippy warnings found: run 'cargo clippy --workspace' to see details (see /tmp/clippy-check.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/clippy-check.log >&2
        archive_check_log "rust-clippy" "fail" /tmp/clippy-check.log
    fi

    # Tests - run lib tests only (integration tests require GTK headers in the Nix shell)
    # @trace spec:testing
    if run_rust_in_nix_develop cargo test --workspace --lib 2>&1 | tee /tmp/test-check.log; then
        log_pass "All unit tests pass (integration tests require the Nix shell)"
        archive_check_log "rust-tests" "pass" /tmp/test-check.log
    else
        log_fail_tracked "rust-tests" "Test failures detected: run 'cargo test --workspace --lib' to see details (see /tmp/test-check.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/test-check.log >&2
        archive_check_log "rust-tests" "fail" /tmp/test-check.log
    fi

    # Tray feature contract
    # @trace spec:tray-app, spec:tray-ux, spec:tray-progress-and-icon-states
    if run_rust_in_nix_develop cargo test -p tillandsias-headless --features tray 2>&1 | tee /tmp/tray-check.log; then
        log_pass "Tray feature tests pass"
        archive_check_log "tray-contract" "pass" /tmp/tray-check.log
    else
        log_fail_tracked "tray-contract" "Tray feature tests failed (see /tmp/tray-check.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/tray-check.log >&2
        archive_check_log "tray-contract" "fail" /tmp/tray-check.log
    fi

    # Headless signal shutdown contract
    # @trace spec:headless-mode, spec:graceful-shutdown
    if run_rust_in_nix_develop cargo test -p tillandsias-headless --test signal_handling 2>&1 | tee /tmp/signal-handling-check.log; then
        log_pass "Headless shutdown signal tests pass"
        archive_check_log "signal-handling" "pass" /tmp/signal-handling-check.log
    else
        log_fail_tracked "signal-handling" "Headless shutdown signal tests failed (see /tmp/signal-handling-check.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/signal-handling-check.log >&2
        archive_check_log "signal-handling" "fail" /tmp/signal-handling-check.log
    fi

    # ============================================================================
    # CHECK 6: Container base-image policy
    # ============================================================================

    log_section "Container Base Image Policy"
    if [[ -f "scripts/check-container-bases.sh" ]]; then
        if bash scripts/check-container-bases.sh 2>&1 | tee /tmp/container-bases.log; then
            log_pass "Container base images match role policy"
            archive_check_log "container-base-policy" "pass" /tmp/container-bases.log
        else
            log_fail_tracked "container-base-policy" "Container base-image policy drift found (see /tmp/container-bases.log)"
            [[ "$VERBOSE" == "1" ]] && cat /tmp/container-bases.log >&2
            archive_check_log "container-base-policy" "fail" /tmp/container-bases.log
        fi
    else
        log_skip "Container base-image checker not found"
        archive_check_log "container-base-policy" "skipped"
    fi

    # ============================================================================
    # CHECK 7: Cheatsheet tier validation
    # ============================================================================

    log_section "Cheatsheet Tier Discipline"
    if [[ -f "scripts/check-cheatsheet-tiers.sh" ]]; then
        if bash scripts/check-cheatsheet-tiers.sh --strict 2>&1 | tee /tmp/cheatsheet-tiers.log; then
            log_pass "Cheatsheet tier validation passed"
            archive_check_log "cheatsheet-tiers" "pass" /tmp/cheatsheet-tiers.log
        else
            log_fail_tracked "cheatsheet-tiers" "Cheatsheet tier errors or strict warnings found (see /tmp/cheatsheet-tiers.log)"
            [[ "$VERBOSE" == "1" ]] && cat /tmp/cheatsheet-tiers.log >&2
            archive_check_log "cheatsheet-tiers" "fail" /tmp/cheatsheet-tiers.log
        fi
    else
        log_skip "Cheatsheet tier validator not found"
        archive_check_log "cheatsheet-tiers" "skipped"
    fi
fi

# ============================================================================
# CHECK 7: Pre-build litmus
# ============================================================================

if [[ "$CI_PHASE" == "all" || "$CI_PHASE" == "pre-build" ]]; then
    if [[ "$FAST_MODE" == "0" ]]; then
        log_section "Pre-Build Litmus (command-shape and static contracts)"
        if [[ -f "scripts/run-litmus-test.sh" ]]; then
            if require_podman; then
                if run_litmus_phase pre-build /tmp/litmus-pre-build.log; then
                    log_pass "Pre-build litmus passed"
                    archive_check_log "litmus-pre-build" "pass" /tmp/litmus-pre-build.log
                else
                    rc=$?
                    log_fail_tracked "litmus-pre-build" "Pre-build litmus failures detected (see /tmp/litmus-pre-build.log)"
                    [[ "$VERBOSE" == "1" ]] && cat /tmp/litmus-pre-build.log >&2
                    archive_check_log "litmus-pre-build" "fail" /tmp/litmus-pre-build.log
                    if [[ "$CI_STOP_ON_FAILURE" == "1" ]]; then
                        exit "$rc"
                    fi
                fi
            else
                log_fail_tracked "podman-path-availability" "podman is not available on PATH"
                archive_check_log "podman-path-availability" "fail"
            fi
        else
            log_skip "Litmus test runner not found"
            archive_check_log "litmus-pre-build" "skipped"
        fi
    else
        log_section "Pre-Build Litmus — Skipped (--fast mode)"
        log_info "Run without --fast to execute pre-build litmus locally"
    fi
fi

# ============================================================================
# CHECK 8: Post-build smoke
# ============================================================================

if [[ "$CI_PHASE" == "all" || "$CI_PHASE" == "post-build" ]]; then
    log_section "Post-Build Status Smoke"
    if [[ -f "scripts/run-litmus-test.sh" ]]; then
        if require_podman; then
            if [[ -n "${TILLANDSIAS_STATUS_CHECK_BIN:-}" ]]; then
                export TILLANDSIAS_STATUS_CHECK_BIN
            fi
            if run_litmus_phase post-build /tmp/litmus-post-build.log; then
                log_pass "Post-build smoke passed"
                archive_check_log "litmus-post-build" "pass" /tmp/litmus-post-build.log
            else
                rc=$?
                log_fail_tracked "litmus-post-build" "Post-build smoke failures detected (see /tmp/litmus-post-build.log)"
                [[ "$VERBOSE" == "1" ]] && cat /tmp/litmus-post-build.log >&2
                archive_check_log "litmus-post-build" "fail" /tmp/litmus-post-build.log
                if [[ "$CI_STOP_ON_FAILURE" == "1" ]]; then
                    exit "$rc"
                fi
            fi
        else
            log_fail_tracked "podman-path-availability" "podman is not available on PATH"
            archive_check_log "podman-path-availability" "fail"
        fi
    else
        log_skip "Litmus test runner not found"
        archive_check_log "litmus-post-build" "skipped"
    fi
fi

# ============================================================================
# CHECK 9: Runtime residual litmus
# ============================================================================

if [[ "$CI_PHASE" == "all" || "$CI_PHASE" == "runtime" ]]; then
    if [[ "$FAST_MODE" == "0" ]]; then
        log_section "Runtime Residual Litmus"
        : >"$RUNTIME_STATUS_FILE"
        if [[ -f "scripts/run-litmus-test.sh" ]]; then
            if require_podman; then
                if podman_runtime_health_probe; then
                    if run_litmus_phase runtime /tmp/litmus-runtime.log; then
                        printf 'PASS\n' >"$RUNTIME_STATUS_FILE"
                        log_pass "Runtime litmus passed"
                        archive_check_log "litmus-runtime" "pass" /tmp/litmus-runtime.log
                    else
                        rc=$?
                        printf 'FAIL\n' >"$RUNTIME_STATUS_FILE"
                        log_fail_tracked "litmus-runtime" "Runtime litmus failures detected (see /tmp/litmus-runtime.log)"
                        [[ "$VERBOSE" == "1" ]] && cat /tmp/litmus-runtime.log >&2
                        archive_check_log "litmus-runtime" "fail" /tmp/litmus-runtime.log
                        if [[ "$CI_STOP_ON_FAILURE" == "1" ]]; then
                            exit "$rc"
                        fi
                    fi
                else
                    printf 'SKIP\n' >"$RUNTIME_STATUS_FILE"
                    log_skip "Runtime litmus skipped (host Podman runtime unhealthy; see /tmp/litmus-runtime-health.log)"
                    [[ "$VERBOSE" == "1" ]] && cat /tmp/litmus-runtime-health.log >&2
                    archive_check_log "litmus-runtime-health" "unhealthy" /tmp/litmus-runtime-health.log
                    archive_check_log "litmus-runtime-migrate" "unhealthy" /tmp/litmus-runtime-migrate.log
                    archive_check_log "litmus-runtime" "skipped"
                fi
            else
                printf 'FAIL\n' >"$RUNTIME_STATUS_FILE"
                log_fail_tracked "podman-path-availability" "podman is not available on PATH"
                archive_check_log "podman-path-availability" "fail"
            fi
        else
            printf 'SKIP\n' >"$RUNTIME_STATUS_FILE"
            log_skip "Litmus test runner not found"
            archive_check_log "litmus-runtime" "skipped"
        fi
    else
        log_section "Runtime Residual Litmus — Skipped (--fast mode)"
        log_info "Run without --fast to execute runtime litmus locally"
    fi
fi

# ============================================================================
# CHECK 10: CentiColon dashboard generation
# ============================================================================

log_section "CentiColon Dashboard Generation"
if [[ -f "scripts/update-convergence-dashboard.sh" ]]; then
    if bash scripts/update-convergence-dashboard.sh 2>&1 | tee /tmp/convergence-dashboard.log; then
        log_pass "CentiColon dashboard regenerated"
        archive_check_log "convergence-dashboard" "pass" /tmp/convergence-dashboard.log
    else
        log_fail_tracked "convergence-dashboard" "CentiColon dashboard generation failed (see /tmp/convergence-dashboard.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/convergence-dashboard.log >&2
        archive_check_log "convergence-dashboard" "fail" /tmp/convergence-dashboard.log
    fi
else
    log_skip "CentiColon dashboard generator not found"
    archive_check_log "convergence-dashboard" "skipped"
fi

# ============================================================================
# CHECK 11: CentiColon signature writer
# ============================================================================

log_section "CentiColon Signature Writing"
if write_convergence_artifacts 2>&1 | tee /tmp/convergence-writer.log; then
    log_pass "CentiColon signature and evidence bundle written"
    archive_check_log "convergence-writer" "pass" /tmp/convergence-writer.log
else
    log_fail_tracked "convergence-writer" "CentiColon signature writer failed (see /tmp/convergence-writer.log)"
    [[ "$VERBOSE" == "1" ]] && cat /tmp/convergence-writer.log >&2
    archive_check_log "convergence-writer" "fail" /tmp/convergence-writer.log
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
