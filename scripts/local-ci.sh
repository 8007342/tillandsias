#!/usr/bin/env bash
# local-ci.sh — Full CI/CD validation suite for local development
# @trace spec:ci-release, spec:spec-traceability, spec:versioning
#
# Purpose: Run ALL convergence checks locally before pushing.
# This avoids wasting cloud minutes on failures.
#
# Release-blocking checks run locally here before the hosted release workflow:
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

# On Fedora Silverblue (immutable), transparently re-exec inside the
# tillandsias-builder toolbox where Rust/gcc/ruby/etc are available.
# Non-Silverblue hosts skip with zero overhead. Sourced first so the
# ci-full container/runtime toolchain resolves inside the toolbox.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/with-tillandsias-builder.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/scripts/common.sh"

# RE-ASSERT THIS SCRIPT'S DECLARED OPTIONS (order 731-pc5r).
#
# Line 27 says `set -uo pipefail` and deliberately omits `-e`: this suite is
# built to run EVERY check and report all failures at the end
# (`if cmd; then log_pass else log_fail_tracked fi`, then the "Failed checks:"
# block). `errexit` is not merely unnecessary here, it is contrary to the
# design — it aborts at the first red check and hides the rest.
#
# But `source` runs in the CURRENT shell, and scripts/with-tillandsias-builder.sh
# does `set -euo pipefail` at its own line 27, so errexit leaked in above and
# this script had never actually been running with the options it declares.
#
# What that cost, measured on macOS 2026-08-14: the suite died at the FRESHNESS
# ADVISORY step — the one whose own comment reads "Advisory ONLY ... NEVER fails
# the suite". Its `grep -E '^freshness-stale:'` finds nothing on a host with no
# stale components (this one: 13/1242 stamped, all `freshness-unstamped`), grep
# exits 1, `pipefail` promotes it through the pipeline, and leaked errexit killed
# the run. Four lines of output, exit 1, no failure named — and every Rust check
# below it (fmt, clippy, the entire test suite) silently never ran.
#
# A non-gating step was gating, and the gate it killed was the deterministic one.
set +e

# Build/test DURATION telemetry (packet 682-emvg). Best-effort side-channel that
# times each litmus phase; a timing failure must NEVER change local-ci's exit.
. "$REPO_ROOT/scripts/timing-log.sh" 2>/dev/null || true
command -v timing_emit >/dev/null 2>&1 || { timing_now_ms() { echo 0; }; timing_emit() { return 0; }; }
# 765-dfry: per-check duration anchor. Checks run sequentially and each ends
# in archive_check_log, so "time since the previous archive (or section
# start)" IS the check's own duration. Re-anchored by log_section and by
# every archive_check_log call.
_CHECK_ANCHOR_MS="$(timing_now_ms 2>/dev/null || echo 0)"

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
    rust-clippy-all-features
    rust-tests
    container-base-policy
    cheatsheet-tiers
    no-python-scripts
    no-base64-script-injection
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
                no-python-scripts
                no-base64-script-injection
            )
        else
            CHECK_IDS=(
                spec-cheatsheet-binding
                spec-code-drift
                spec-trace-coverage
                version-monotonicity
                rust-formatting
                rust-clippy
                rust-clippy-all-features
                rust-tests
                container-base-policy
                cheatsheet-tiers
                no-python-scripts
                no-base64-script-injection
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
            rust-clippy-all-features
            rust-tests
            container-base-policy
            cheatsheet-tiers
            no-python-scripts
            no-base64-script-injection
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
        rust-clippy-all-features) echo 180 ;;
        rust-tests) echo 80 ;;
        container-base-policy) echo 40 ;;
        cheatsheet-tiers) echo 80 ;;
        no-python-scripts) echo 30 ;;
        no-base64-script-injection) echo 30 ;;
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
        rust-clippy-all-features) echo "spec:dev-build" ;;
        rust-tests) echo "spec:testing" ;;
        container-base-policy) echo "spec:default-image" ;;
        cheatsheet-tiers) echo "spec:cheatsheet-source-layer" ;;
        no-python-scripts) echo "methodology.yaml tlatoani_hard_no_python" ;;
        no-base64-script-injection) echo "methodology.yaml base64_script_injection_ban" ;;
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
        rust-clippy-all-features) echo "All-features clippy warnings: run 'cargo clippy --workspace --all-targets --all-features -- -D warnings' (see /tmp/clippy-all-features-check.log)" ;;
        rust-tests) echo "Test failures detected: run 'cargo test --workspace --lib --no-fail-fast' to see details (see /tmp/test-check.log)" ;;
        container-base-policy) echo "Container base-image policy drift found (see /tmp/container-bases.log)" ;;
        cheatsheet-tiers) echo "Cheatsheet tier errors or strict warnings found (see /tmp/cheatsheet-tiers.log)" ;;
        no-python-scripts) echo "Python scripts found in tracked files (see /tmp/no-python-check.log)" ;;
        no-base64-script-injection) echo "Base64 script injection detected (see /tmp/no-base64-script-injection.log)" ;;
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

    case "$phase" in
        pre-build) args+=(--size quick) ;;
        post-build|runtime) args+=(--size e2e) ;;
    esac

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

    # Time the phase as a telemetry side-channel (packet 682-emvg). Capturing the
    # rc first and emitting after preserves the exact return contract below —
    # 0 on success, the runner's PIPESTATUS[0] on failure — untouched.
    local _t0 _rc
    _t0="$(timing_now_ms)"
    if bash scripts/run-litmus-test.sh "${args[@]}" 2>&1 | tee "$log_file"; then
        _rc=0
    else
        _rc="${PIPESTATUS[0]}"
    fi
    timing_emit "local-ci-phase-$phase" "$phase" "$_t0" "$_rc"
    return "$_rc"
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
    # 765-dfry: a section header starts a fresh check block — re-anchor so the
    # first check in the section is not billed for inter-section work.
    _CHECK_ANCHOR_MS="$(timing_now_ms 2>/dev/null || echo 0)"
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

# A guard whose SCRIPT IS ABSENT is a repo-integrity failure, never a skip.
#
# Every gate below was written as `if [[ -f <script> ]]; then ... else log_skip
# "<name> checker not found"; fi`. Because the verdict only tests CHECKS_FAILED,
# that shape means renaming, moving, or deleting any guard script silently
# DELETES that guard from CI while CI keeps printing "Safe to push!". The Python
# ban — an explicit operator non-negotiable — evaporated if
# scripts/check-no-python-scripts.sh was ever relocated, with no message anywhere.
#
# Fail closed instead: the guards are committed files, so their absence means the
# tree is broken, not that the check is inapplicable. Environmental skips (no
# podman, deep lane excluded in fast mode) keep using log_skip, which is the
# honest signal for "this genuinely does not apply here".
log_fail_missing_guard() {
    local check_name="$1"
    local script_path="$2"
    log_fail_tracked "$check_name" \
        "guard script missing: $script_path — a guard that cannot run is not a guard. Restore it, or remove its gate from scripts/local-ci.sh deliberately."
}

    log_info() {
    printf '%b%s%b %s\n' "${BLUE}" "ℹ" "${NC}" "$*"
}

run_rust_on_host() {
    local repo_root="${REPO_ROOT}"
    (cd "$repo_root" && "$@")
}

# 880-tdwn END STATE, defined ahead of its wiring: cargo TEST invocations
# should run with the real-podman tripwire armed, so a parallel test racing
# the TILLANDSIAS_PODMAN_BIN seam fails loudly by name instead of stopping
# the live enclave (twice-measured on macuahuitl: every warm-cache --ci-full
# killed the whole stack during tray-check; vault SIGKILLed at stop-grace).
# NOT WIRED YET: arming it today fails 32 enumerated non-hermetic tests
# (28 in the featured tray target, 2 workspace-lib transport tests, 2
# signal_handling integration tests — lists on the 880-tdwn row), which
# would red the gate the whole fleet pushes behind. Wire each cargo-test
# line through this wrapper as its suite is made hermetic; the wiring IS
# the packet's closing move.
run_rust_test_on_host() {
    local repo_root="${REPO_ROOT}"
    (cd "$repo_root" && TILLANDSIAS_PODMAN_REFUSE_REAL=1 "$@")
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

    # 765-dfry: per-check duration = time since the previous archive/section
    # anchor (checks run sequentially and each ends here). A zero/absent
    # anchor (timing-log stub) records 0 rather than an epoch-sized poison
    # value; the anchor is always reset so the NEXT check measures cleanly.
    local _acl_now _acl_dur
    _acl_now="$(timing_now_ms 2>/dev/null || echo 0)"
    _acl_dur=0
    if [[ "${_CHECK_ANCHOR_MS:-0}" =~ ^[0-9]+$ && "${_CHECK_ANCHOR_MS:-0}" -gt 0 && "$_acl_now" =~ ^[0-9]+$ && "$_acl_now" -ge "${_CHECK_ANCHOR_MS}" ]]; then
        _acl_dur=$((_acl_now - _CHECK_ANCHOR_MS))
        [[ "$_acl_dur" -lt 86400000 ]] || _acl_dur=0
    fi
    _CHECK_ANCHOR_MS="$_acl_now"

    jq -nc \
        --arg ci_run_id "$CI_RUN_ID" \
        --arg ci_phase "$CI_PHASE" \
        --arg check_id "$check_id" \
        --arg status "$status" \
        --arg source_log "${source_log:-}" \
        --arg archived_log "$archived_log" \
        --arg sha256 "$(sha256_file "$archived_log")" \
        --argjson duration_ms "$_acl_dur" \
        '{
          ci_run_id:$ci_run_id,
          ci_phase:$ci_phase,
          check_id:$check_id,
          status:$status,
          source_log:$source_log,
          archived_log:$archived_log,
          sha256:$sha256,
          duration_ms:$duration_ms
        }' >>"$CHECK_LOG_INDEX"

    # Mirror into the 682-emvg side-channel so a ci-full run is attributable
    # from the timing records alone (skipped checks spent no measured time and
    # would only flatten the rolling averages — not emitted). Best-effort by
    # timing_emit's own contract; the ~15ms spawn is noise on a minutes-long
    # phase (the microseconds bound applies to the 8s --check gate, whose
    # phases batch through --emit-timing-batch instead).
    if [[ "$status" != "skipped" && "$_acl_dur" -gt 0 ]]; then
        local _acl_rc=0
        [[ "$status" == "fail" ]] && _acl_rc=1
        timing_emit "check:$check_id" "$CI_PHASE" "$((_acl_now - _acl_dur))" "$_acl_rc"
    fi
}


log_info "CI phase: ${CI_PHASE}"

# ============================================================================
# CHECK 0: FRESHNESS advisory flagging (rung 3 — order 371)
# ============================================================================
# Advisory ONLY. Per methodology component_freshness (flag -> soak -> default,
# migration_discipline): this step names the N oldest/stalest components each
# run but NEVER fails the suite. A flagged component is a claimable audit
# source for /meta-orchestration and /advance-work-from-plan — not a gate.
# Gating requires explicit The Tlatoāni approval (bar_raise_governance).

if [[ -x "scripts/freshness-inventory.sh" ]]; then
    log_section "FRESHNESS advisory flagging (non-gating)"
    _fresh_report="$(scripts/freshness-inventory.sh 2>/dev/null || true)"
    _fresh_total="$(printf '%s\n' "$_fresh_report" | grep -E '^freshness-inventory:' | grep -oE '[0-9]+ components' | grep -oE '[0-9]+')"
    _fresh_stamped="$(printf '%s\n' "$_fresh_report" | grep -E '^freshness-inventory:' | grep -oE '[0-9]+ stamped' | grep -oE '[0-9]+')"
    _fresh_cov="$(printf '%s\n' "$_fresh_report" | grep -E '^freshness-coverage:' | grep -oE '[0-9]+(\.[0-9]+)?%')"
    if [[ -n "$_fresh_cov" ]]; then
        log_info "FRESHNESS coverage: ${_fresh_cov} (${_fresh_stamped:-0}/${_fresh_total:-?} components stamped)"
    fi
    # Grammar is `freshness-stale: <path> <age-days> ...`; age is field 3.
    # Sorting field 2 ranked paths lexically and advertised the wrong audit
    # source as "top stalest" with total confidence.
    # `|| true`: belt to the `set +e` brace above (731-pc5r). grep exits 1 when a
    # host has no stale components at all, and under `pipefail` that is the
    # pipeline's status — an advisory step must not hand a failure upward on the
    # HAPPY path, whatever the caller's errexit state happens to be.
    _fresh_flagged="$(printf '%s\n' "$_fresh_report" | grep -E '^freshness-stale:' | sort -t' ' -k3,3nr | head -5 || true)"
    if [[ -n "$_fresh_flagged" ]]; then
        log_info "Top stalest components (audit candidates — advisory only):"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            log_info "  $line"
        done <<< "$_fresh_flagged"
        log_info "Disposition via /meta-orchestration freshness-audit class: refreshed|updated|obsoleted (discard-over-repair bias)."
    else
        log_info "No stale components flagged (all stamped components are fresh)."
    fi
    archive_check_log "freshness-advisory" "pass" /dev/null
else
    log_skip "FRESHNESS inventory script not found (advisory step skipped)"
    archive_check_log "freshness-advisory" "skipped"
fi

# ============================================================================
# CHECK 0b: DEAD ENV BRANCHES advisory (order 829-dkuc, wired 865-j3kd)
# ============================================================================
# Advisory ONLY, and the distinction matters. check-dead-env-branches.sh names
# TILLANDSIAS_* variables that live code READS and nothing ASSIGNS or DOCUMENTS
# — a branch guarded by a variable nothing sets is unreachable code wearing a
# feature flag's costume. It currently reports dead=14, which is a BURNDOWN
# LIST, not a release defect: those branches have been unreachable for as long
# as they have existed and shipping is not made worse by one more day of them.
#
# WHY IT IS WIRED HERE AT ALL. The guard shipped invoked by nothing, so
# audit-guard-activation reported it an orphan and ./build.sh --ci-full failed
# — one of three checks that made the trunk unreleasable for a week (865-n8vq).
# The fix for an orphaned guard is to INVOKE it, not to mention it: the auditor
# greps for the name, so a comment would have flipped the verdict while leaving
# the guard exactly as dead. Gaming a guard is the one repair worse than the
# defect.
#
# Gating it would trade one release blocker for another, which is why this is
# advisory until 829-dkuc burns the list down.
if [[ -x "scripts/check-dead-env-branches.sh" ]]; then
    log_section "DEAD ENV BRANCH advisory (non-gating)"
    _dead_report="$(scripts/check-dead-env-branches.sh 2>/dev/null || true)"
    _dead_verdict="$(printf '%s\n' "$_dead_report" | grep -E '^dead-env-branches:' | tail -1)"
    if [[ -n "$_dead_verdict" ]]; then
        log_info "${_dead_verdict}"
        log_info "Advisory: a variable nothing sets makes its branch unreachable (829-dkuc). Burndown, not a gate."
    else
        log_info "dead-env-branch detector produced no verdict line (treated as advisory-clean)."
    fi
    archive_check_log "dead-env-branches-advisory" "pass" /dev/null
else
    log_skip "dead-env-branch detector not found (advisory step skipped)"
    archive_check_log "dead-env-branches-advisory" "skipped"
fi

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
        log_fail_missing_guard "spec-cheatsheet-binding" "scripts/check-cheatsheet-refs.sh"
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
        log_fail_missing_guard "spec-code-drift" "scripts/hooks/pre-commit-openspec.sh"
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
        log_fail_missing_guard "spec-trace-coverage" "scripts/validate-traces.sh"
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
        log_fail_missing_guard "version-monotonicity" "scripts/check-version-monotonicity.sh"
        archive_check_log "version-monotonicity" "skipped"
    fi

    # ============================================================================
    # CHECK 5: Cargo checks (formatting, clippy, tests)
    # ============================================================================

    log_section "Rust Code Quality (fmt, clippy, tests)"

    # Stage the router sidecar before the first cargo invocation (723-wd8i).
    # crates/tillandsias-headless/build.rs:93 lists
    # images/router/tillandsias-router-sidecar among its REQUIRED runtime assets
    # and panics at build.rs:104 when it is absent. Order 710-w9kc un-committed
    # that file and taught build.sh and scripts/build-image.sh to produce it,
    # but not this script, so the clippy gate below dies on any fresh clone.
    # Cheap no-op when the staged binary is already current.
    if [ -x "$REPO_ROOT/scripts/build-sidecar.sh" ]; then
        run_rust_on_host bash "$REPO_ROOT/scripts/build-sidecar.sh" >/dev/null 2>&1 \
            || log_info "build-sidecar.sh could not stage the router sidecar; cargo gates may fail"
    fi

    # @trace spec:dev-build, spec:ci-release
    # Run cargo commands directly on the host workstation.

    # Formatting check
    if run_rust_on_host cargo fmt --check --all 2>&1 | tee /tmp/fmt-check.log; then
        log_pass "Rust formatting valid"
        archive_check_log "rust-formatting" "pass" /tmp/fmt-check.log
    else
        log_fail_tracked "rust-formatting" "Rust code not formatted: run 'cargo fmt --all' (see /tmp/fmt-check.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/fmt-check.log >&2
        archive_check_log "rust-formatting" "fail" /tmp/fmt-check.log
    fi

    # Clippy check
    # 765-uti9 quick win (audit F4c): --all-targets aligns this lane with
    # build.sh --check's clippy flavor, so the two share fingerprints instead
    # of recompiling — and coverage strictly widens (trunk is already held
    # clean at --all-targets -D warnings by the local gate). The heavy
    # --all-features flavor below is deliberately untouched.
    if run_rust_on_host cargo clippy --workspace --all-targets -- -D warnings 2>&1 | tee /tmp/clippy-check.log; then
        log_pass "Clippy checks pass (no warnings)"
        archive_check_log "rust-clippy" "pass" /tmp/clippy-check.log
    else
        log_fail_tracked "rust-clippy" "Clippy warnings found: run 'cargo clippy --workspace' to see details (see /tmp/clippy-check.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/clippy-check.log >&2
        archive_check_log "rust-clippy" "fail" /tmp/clippy-check.log
    fi

    # All-features clippy lane — approved bar-raise (The Tlatoāni, 2026-07-10):
    # the default pass never compiles non-default-feature units (vm-layer
    # fake/download/recipe/materialize, headless listen-vsock, materialize-cli
    # required-features bin), so their lint debt was invisible until merge or
    # e2e time. Deep lane only — skipped under --fast (--ci), runs under
    # --ci-full. Registry: methodology/convergence.yaml approved_bar_raises
    # id ci-full-all-features-clippy; slice 3 (promotion into --check) is NOT
    # approved.
    if [[ "$FAST_MODE" == "1" ]]; then
        log_skip "All-features clippy lane (deep lane, skipped in fast mode)"
        archive_check_log "rust-clippy-all-features" "skipped"
    elif run_rust_on_host cargo clippy --workspace --all-targets --all-features -- -D warnings 2>&1 | tee /tmp/clippy-all-features-check.log; then
        log_pass "All-features clippy lane passes (no warnings)"
        archive_check_log "rust-clippy-all-features" "pass" /tmp/clippy-all-features-check.log
    else
        log_fail_tracked "rust-clippy-all-features" "All-features clippy warnings: run 'cargo clippy --workspace --all-targets --all-features -- -D warnings' (see /tmp/clippy-all-features-check.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/clippy-all-features-check.log >&2
        archive_check_log "rust-clippy-all-features" "fail" /tmp/clippy-all-features-check.log
    fi

    # Tests - run lib tests only; host-sensitive integration suites are covered by
    # their dedicated litmus/runtime gates rather than the fast deterministic pass.
    # @trace spec:testing
    # --no-fail-fast (order 829-g4xf): without it cargo stops at the first
    # failing binary, so this pass reported 1 failure where there were 8 and
    # more than half the workspace never ran.
    if run_rust_on_host cargo test --workspace --lib --no-fail-fast 2>&1 | tee /tmp/test-check.log; then
        log_pass "All unit tests pass"
        archive_check_log "rust-tests" "pass" /tmp/test-check.log
    else
        log_fail_tracked "rust-tests" "Test failures detected: run 'cargo test --workspace --lib --no-fail-fast' to see details (see /tmp/test-check.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/test-check.log >&2
        archive_check_log "rust-tests" "fail" /tmp/test-check.log
    fi

    # Tray + vsock-server feature contract
    #
    # `listen-vsock` added by order 831-wmn4. This pass named only `tray`, so
    # `mod vsock_server` — the in-VM control wire's SERVER half — was compiled
    # by no gate that runs tests, exactly the way `mod tray` had been before
    # this check existed. Measured 2026-08-19: a new bound test in
    # vsock_server.rs ran nowhere, while the suite still reported all green.
    # Same defect as the macOS-tray comment below, one crate over.
    #
    # @trace spec:tray-app, spec:tray-ux, spec:tray-progress-and-icon-states
    # @trace spec:vsock-transport
    # 880-tdwn: this ONE target keeps the plain wrapper FOR NOW — arming the
    # tripwire here fails 28 named tests (the enumerated non-hermetic
    # population, list on the 880-tdwn row) and reds the gate the fleet
    # pushes behind. Until that list is drained, a warm-cache ci-full beside
    # a live enclave WILL stop the stack during this check; the queue carries
    # the operational caution and the 878-79b5 supervisor restarts it.
    if run_rust_on_host cargo test -p tillandsias-headless --bin tillandsias --features tray,listen-vsock --no-fail-fast 2>&1 | tee /tmp/tray-check.log; then
        log_pass "Tray + vsock-server feature tests pass"
        archive_check_log "tray-contract" "pass" /tmp/tray-check.log
    else
        log_fail_tracked "tray-contract" "Tray/vsock-server feature tests failed (see /tmp/tray-check.log)"
        [[ "$VERBOSE" == "1" ]] && cat /tmp/tray-check.log >&2
        archive_check_log "tray-contract" "fail" /tmp/tray-check.log
    fi

    # macOS tray contract — BIN target, so `--workspace --lib` above cannot see it.
    #
    # tillandsias-macos-tray declares only `[[bin]]` and has no src/lib.rs, and
    # `cargo test --workspace --lib` selects LIBRARY targets only. Every test in
    # action_host.rs was therefore skipped by the deterministic pass even when it
    # ran on a Mac; `build.sh --check` runs no tests at all, and the macOS
    # release job runs only build-macos-tray.sh. The single command that
    # executed them was a hand-typed `./build.sh --test`.
    #
    # That matters more than it looks. Operator ruling 2026-08-14 made test
    # evidence the closure standard for 598-kibt M5, whose entire macOS half —
    # the cloud submenu's loading-vs-confirmed-empty behaviour — is pinned in
    # this crate. Closing a criterion on assertions no gate evaluates rebuilds
    # the original defect's shape: the macOS half rots while every gate stays
    # green. Adversarial review of that closure is what surfaced this.
    #
    # Darwin-only: the crate is cfg-gated to macOS (main.rs), so on Linux and
    # Windows it compiles to a stub with nothing to assert.
    if [[ "$(uname -s)" == "Darwin" ]]; then
        # @trace spec:macos-native-tray, spec:tray-ux
        if run_rust_on_host cargo test -p tillandsias-macos-tray --bins --no-fail-fast 2>&1 | tee /tmp/macos-tray-check.log; then
            log_pass "macOS tray tests pass"
            archive_check_log "macos-tray-tests" "pass" /tmp/macos-tray-check.log
        else
            log_fail_tracked "macos-tray-tests" "macOS tray tests failed (see /tmp/macos-tray-check.log)"
            [[ "$VERBOSE" == "1" ]] && cat /tmp/macos-tray-check.log >&2
            archive_check_log "macos-tray-tests" "fail" /tmp/macos-tray-check.log
        fi
    fi

    # Headless signal shutdown contract
    # @trace spec:headless-mode, spec:graceful-shutdown
    if TILLANDSIAS_NO_TRAY=1 run_rust_on_host cargo test -p tillandsias-headless --test signal_handling 2>&1 | tee /tmp/signal-handling-check.log; then
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
        log_fail_missing_guard "container-base-policy" "scripts/check-container-bases.sh"
        archive_check_log "container-base-policy" "skipped"
    fi

    # ============================================================================
    # CHECK 6b: No tracked build artifacts (order 723-ydmk)
    # ============================================================================
    # A build artifact matching .gitignore but ALREADY TRACKED is invisible to
    # the ignore rules — the mechanism behind all three historical binary leaks.
    # git's own binary classification (numstat vs the empty tree) + an
    # executable-extension lane; image assets pass via a documented prefix
    # allowlist inside the guard.

    log_section "No Tracked Binaries"
    if [[ -f "scripts/check-no-tracked-binaries.sh" ]]; then
        if bash scripts/check-no-tracked-binaries.sh 2>&1 | tee /tmp/no-tracked-binaries.log; then
            log_pass "No tracked build artifacts outside the image-asset allowlist"
            archive_check_log "no-tracked-binaries" "pass" /tmp/no-tracked-binaries.log
        else
            log_fail_tracked "no-tracked-binaries" "Tracked binary artifact found (see /tmp/no-tracked-binaries.log)"
            [[ "$VERBOSE" == "1" ]] && cat /tmp/no-tracked-binaries.log >&2
            archive_check_log "no-tracked-binaries" "fail" /tmp/no-tracked-binaries.log
        fi
    else
        log_fail_missing_guard "no-tracked-binaries" "scripts/check-no-tracked-binaries.sh"
        archive_check_log "no-tracked-binaries" "skipped"
    fi

    # ============================================================================
    # CHECK 6c: guards that shipped 2026-08-16 without an invoker
    # ============================================================================
    # The guard-activation audit below caught all three as orphans on the
    # 2026-08-17 release gate — shipped by sibling hosts, wired by nobody, so
    # each was a guard that reads as protective and enforces nothing (the
    # 599-4wzr class the audit exists for). Both were verified passing
    # before being wired, so activation cannot turn a latent red into a
    # surprise: check-cheatsheet-frontmatter 221 checked,
    # check-dev-embed-model-agreement nomic-embed-text.
    #
    # A third, check-tracked-config-host-paths.sh, was wired here and is now
    # DELETED rather than repaired (order 789-nc2s, retired 2026-08-17). It
    # scanned tracked agent config for one-machine paths, and it passed —
    # `ok:tracked-config-host-paths:1 scanned` — while /c/Users/bullo/... sat
    # in .claude/settings.local.json, the very file that motivated it, because
    # its env-block-only severity split excused everything in the permissions
    # allowlist. A guard whose scope was narrowed until the offending tree
    # passes is not protection, it is a green light with a rationale attached.
    # The class it chased is better made unrepresentable: machine-local agent
    # settings belong in an untracked .local file, which is what the framework
    # named it for. See plan/issues/ for the untracking decision.
    # Invoked LITERALLY, one block each, deliberately. A `for` loop over the
    # three names is shorter and was the first draft — but the activation
    # audit resolves invokers by grepping for the literal script path, so a
    # loop-invoked guard still reports as an orphan. That is the audit being
    # right: a name assembled at runtime is invisible to `grep` for a human
    # reader too, and "who calls this guard?" must stay answerable by search.
    log_section "Recently Landed Guards"
    # 792-77bt (windows lane). A REPORT, not a pass/fail gate: it prints the
    # tray string-corpus drift ratio and exits 0 whatever the ratio is, so it
    # is wired to surface the number, not to fail on it. Wired here because
    # the activation audit correctly flagged it as an orphan the moment it
    # landed — an unwired guard is inert, and inert is the 599-4wzr class.
    # The packet is windows-owned; if they give it a fail threshold, this
    # block should move to the tracked-failure shape the others use.
    if [[ -f "scripts/check-tray-string-corpus-drift.sh" ]]; then
        bash scripts/check-tray-string-corpus-drift.sh 2>&1 | tee /tmp/tray-string-corpus-drift.log || true
        log_pass "Tray string-corpus drift reported (792-77bt, informational)"
        archive_check_log "tray-string-corpus-drift" "pass" /tmp/tray-string-corpus-drift.log
    else
        log_fail_missing_guard "tray-string-corpus-drift" "scripts/check-tray-string-corpus-drift.sh"
        archive_check_log "tray-string-corpus-drift" "skipped"
    fi

    if [[ -f "scripts/check-cheatsheet-frontmatter.sh" ]]; then
        if bash scripts/check-cheatsheet-frontmatter.sh 2>&1 | tee /tmp/cheatsheet-frontmatter.log; then
            log_pass "Cheatsheet frontmatter valid"
            archive_check_log "cheatsheet-frontmatter" "pass" /tmp/cheatsheet-frontmatter.log
        else
            log_fail_tracked "cheatsheet-frontmatter" "Cheatsheet frontmatter violations (see /tmp/cheatsheet-frontmatter.log)"
            archive_check_log "cheatsheet-frontmatter" "fail" /tmp/cheatsheet-frontmatter.log
        fi
    else
        log_fail_missing_guard "cheatsheet-frontmatter" "scripts/check-cheatsheet-frontmatter.sh"
        archive_check_log "cheatsheet-frontmatter" "skipped"
    fi

    if [[ -f "scripts/check-dev-embed-model-agreement.sh" ]]; then
        if bash scripts/check-dev-embed-model-agreement.sh 2>&1 | tee /tmp/dev-embed-model-agreement.log; then
            log_pass "Dev embed model agrees across surfaces"
            archive_check_log "dev-embed-model-agreement" "pass" /tmp/dev-embed-model-agreement.log
        else
            log_fail_tracked "dev-embed-model-agreement" "Dev embed model disagreement (see /tmp/dev-embed-model-agreement.log)"
            archive_check_log "dev-embed-model-agreement" "fail" /tmp/dev-embed-model-agreement.log
        fi
    else
        log_fail_missing_guard "dev-embed-model-agreement" "scripts/check-dev-embed-model-agreement.sh"
        archive_check_log "dev-embed-model-agreement" "skipped"
    fi

    # Order 801-a2by. Sibling of the check above and for the same reason: the
    # spec-index PRODUCER and its two READERS resolve the durable root
    # independently, in two runtimes that cannot share a file. A disagreement is
    # silent by construction — the index gets built where nobody looks and the
    # system reports a missing index rather than a misconfigured one, which is
    # the shape that hid the whole embedding step for weeks (552).
    if [[ -f "scripts/check-spec-index-resolution-agreement.sh" ]]; then
        if bash scripts/check-spec-index-resolution-agreement.sh 2>&1 | tee /tmp/spec-index-resolution-agreement.log; then
            log_pass "Spec-index resolution agrees across producer and readers"
            archive_check_log "spec-index-resolution-agreement" "pass" /tmp/spec-index-resolution-agreement.log
        else
            log_fail_tracked "spec-index-resolution-agreement" "Spec-index resolution drift (see /tmp/spec-index-resolution-agreement.log)"
            archive_check_log "spec-index-resolution-agreement" "fail" /tmp/spec-index-resolution-agreement.log
        fi
    else
        log_fail_missing_guard "spec-index-resolution-agreement" "scripts/check-spec-index-resolution-agreement.sh"
        archive_check_log "spec-index-resolution-agreement" "skipped"
    fi

    # Order 765-mza8. Wired here, literally, for the same reason as the two
    # above. A dead `inputs:` glob is silent by construction: it cannot make a
    # test run, only skip, so nothing else in this suite would ever go red for
    # it. Verified passing before wiring: 51 glob(s) across 11 annotated test(s).
    if [[ -f "scripts/check-litmus-dead-inputs.sh" ]]; then
        if bash scripts/check-litmus-dead-inputs.sh 2>&1 | tee /tmp/litmus-dead-inputs.log; then
            log_pass "Every litmus inputs: glob resolves to a tracked file"
            archive_check_log "litmus-dead-inputs" "pass" /tmp/litmus-dead-inputs.log
        else
            log_fail_tracked "litmus-dead-inputs" "Dead litmus inputs glob (see /tmp/litmus-dead-inputs.log)"
            archive_check_log "litmus-dead-inputs" "fail" /tmp/litmus-dead-inputs.log
        fi
    else
        log_fail_missing_guard "litmus-dead-inputs" "scripts/check-litmus-dead-inputs.sh"
        archive_check_log "litmus-dead-inputs" "skipped"
    fi

    # ============================================================================
    # Guard activation audit (order 599-4wzr) — a guard nobody can prove is
    # running is not a guard. Fails loud if any check-*.sh has no invoker.
    # ============================================================================
    log_section "Guard Activation Audit (599-4wzr)"
    if [[ -f "scripts/audit-guard-activation.sh" ]]; then
        if bash scripts/audit-guard-activation.sh 2>&1 | tee /tmp/guard-activation.log; then
            log_pass "Every shipped guard is invoked by an activation surface"
            archive_check_log "guard-activation" "pass" /tmp/guard-activation.log
        else
            log_fail_tracked "guard-activation" "Orphaned guard(s) found — shipped but never invoked (see /tmp/guard-activation.log)"
            [[ "$VERBOSE" == "1" ]] && cat /tmp/guard-activation.log >&2
            archive_check_log "guard-activation" "fail" /tmp/guard-activation.log
        fi
    else
        log_fail_missing_guard "guard-activation" "scripts/audit-guard-activation.sh"
        archive_check_log "guard-activation" "skipped"
    fi

    # Markdown distillation policy (order 599-4wzr activation): was orphaned.
    log_section "Markdown Distillation Policy"
    if [[ -f "scripts/check-markdown-distillation.sh" ]]; then
        # ORDER 831-ezea. This ran the checker into `tee` with NO `if`, then
        # logged `log_pass` unconditionally. `tee` always exits 0, so the
        # checker's exit 1 was discarded before anything could read it — the
        # gate printed "✓ Markdown distillation policy checked (advisory)" on
        # every run, including runs where the checker was naming noncanonical
        # files on stderr two lines above. Same defect class as the pre-build
        # litmus scar at the bottom of this file: a check that cannot fail.
        #
        # `set -o pipefail` is active (line 27), so `if <cmd> | tee` already
        # propagates the producer's status — that is the shape used by the
        # guard-activation audit directly above. PIPESTATUS[0] is read only to
        # NAME the exit code in the failure message; do not read `$?` there,
        # it is tee's.
        if bash scripts/check-markdown-distillation.sh 2>&1 | tee /tmp/markdown-distillation.log; then
            log_pass "Markdown distillation policy checked"
            archive_check_log "markdown-distillation" "pass" /tmp/markdown-distillation.log
        else
            rc=${PIPESTATUS[0]}
            log_fail_tracked "markdown-distillation" \
                "Markdown distillation policy FAILED (exit ${rc}) — noncanonical markdown outside the inventory; see /tmp/markdown-distillation.log"
            archive_check_log "markdown-distillation" "fail" /tmp/markdown-distillation.log
        fi
    else
        log_fail_missing_guard "markdown-distillation" "scripts/check-markdown-distillation.sh"
        archive_check_log "markdown-distillation" "skipped"
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
        log_fail_missing_guard "cheatsheet-tiers" "scripts/check-cheatsheet-tiers.sh"
        archive_check_log "cheatsheet-tiers" "skipped"
    fi

    # ============================================================================
    # CHECK 8: Policy checkers (Python ban + base64 script injection ban)
    # ============================================================================

    log_section "Policy Checkers"

    # Sub-check 8a: Python scripts ban
    if [[ -f "scripts/check-no-python-scripts.sh" ]]; then
        if bash scripts/check-no-python-scripts.sh 2>&1 | tee /tmp/no-python-check.log; then
            log_pass "No Python scripts found in tracked files"
            archive_check_log "no-python-scripts" "pass" /tmp/no-python-check.log
        else
            log_fail_tracked "no-python-scripts" "Python scripts detected in tracked files (see /tmp/no-python-check.log)"
            [[ "$VERBOSE" == "1" ]] && cat /tmp/no-python-check.log >&2
            archive_check_log "no-python-scripts" "fail" /tmp/no-python-check.log
        fi
    else
        log_fail_missing_guard "no-python-scripts" "scripts/check-no-python-scripts.sh"
        archive_check_log "no-python-scripts" "skipped"
    fi

    # Sub-check 8b: Base64 script injection ban
    if [[ -f "scripts/check-no-base64-script-injection.sh" ]]; then
        if bash scripts/check-no-base64-script-injection.sh 2>&1 | tee /tmp/no-base64-script-injection.log; then
            log_pass "No base64 script injection detected"
            archive_check_log "no-base64-script-injection" "pass" /tmp/no-base64-script-injection.log
        else
            log_fail_tracked "no-base64-script-injection" "Base64 script injection detected (see /tmp/no-base64-script-injection.log)"
            [[ "$VERBOSE" == "1" ]] && cat /tmp/no-base64-script-injection.log >&2
            archive_check_log "no-base64-script-injection" "fail" /tmp/no-base64-script-injection.log
        fi
    else
        log_fail_missing_guard "no-base64-script-injection" "scripts/check-no-base64-script-injection.sh"
        archive_check_log "no-base64-script-injection" "skipped"
    fi
fi

# ============================================================================
# CHECK 9: Pre-build litmus
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
                log_fail_tracked "podman-path-availability" "podman check failed; require_podman printed the cause on stderr (absent and present-but-unresponsive are different faults - order 793-a62g)"
                archive_check_log "podman-path-availability" "fail"
            fi
        else
            log_fail_missing_guard "litmus-runner-missing" "scripts/run-litmus-test.sh"
            archive_check_log "litmus-pre-build" "skipped"
        fi
    else
        log_section "Pre-Build Litmus (instant tests only, --fast mode)"
        if [[ -f "scripts/run-litmus-test.sh" ]]; then
            if require_podman; then
                if bash scripts/run-litmus-test.sh --phase pre-build --size instant --compact 2>&1 | tee /tmp/litmus-pre-build.log; then
                    log_pass "Pre-build instant litmus passed (instant size only — size:quick tests were NOT run)"
                    archive_check_log "litmus-pre-build" "pass" /tmp/litmus-pre-build.log
                else
                    # This branch fires when the litmus run FAILED. `set -o pipefail`
                    # is active (see the top of this file), so the pipeline through
                    # `tee` propagates the runner's non-zero status.
                    #
                    # It used to log "Instant litmus tests passed; skipping slow
                    # compilation tests" — a literal falsehood on the failure path —
                    # archive the check as `pass-partial`, and capture `rc=$?`
                    # without ever using it. Because `log_info` does not increment
                    # CHECKS_FAILED, and the final verdict is
                    # `if [[ $CHECKS_FAILED -eq 0 ]]`, `./build.sh --ci` printed
                    # "✓ ALL CHECKS PASSED — Safe to push!" and exited 0 while the
                    # pre-build litmus was genuinely red. An agent then pushed with
                    # POSITIVE EVIDENCE that its work was clean, and the failure
                    # resurfaced in someone else's --ci-full run or in the hosted
                    # release workflow — maximum distance from cause.
                    #
                    # A check that cannot fail is not a gate.
                    rc=${PIPESTATUS[0]}
                    log_fail_tracked "litmus-pre-build" \
                        "Pre-build instant litmus FAILED (exit ${rc}) — see /tmp/litmus-pre-build.log"
                    archive_check_log "litmus-pre-build" "fail" /tmp/litmus-pre-build.log
                fi
            else
                log_fail_tracked "podman-path-availability" "podman check failed; require_podman printed the cause on stderr (absent and present-but-unresponsive are different faults - order 793-a62g)"
                archive_check_log "podman-path-availability" "fail"
            fi
        else
            log_fail_missing_guard "litmus-runner-missing" "scripts/run-litmus-test.sh"
            archive_check_log "litmus-pre-build" "skipped"
        fi
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
            log_fail_tracked "podman-path-availability" "podman check failed; require_podman printed the cause on stderr (absent and present-but-unresponsive are different faults - order 793-a62g)"
            archive_check_log "podman-path-availability" "fail"
        fi
    else
        log_fail_missing_guard "litmus-runner-missing" "scripts/run-litmus-test.sh"
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
                log_fail_tracked "podman-path-availability" "podman check failed; require_podman printed the cause on stderr (absent and present-but-unresponsive are different faults - order 793-a62g)"
                archive_check_log "podman-path-availability" "fail"
            fi
        else
            printf 'SKIP\n' >"$RUNTIME_STATUS_FILE"
            log_fail_missing_guard "litmus-runner-missing" "scripts/run-litmus-test.sh"
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
    # Order 495 (preflight-evidence-dirties-forge-gate): route the generated
    # dashboards under target/ (gitignored) so this gate never dirties the
    # tracked checkout that the post-build forge gate's dirty-start guard
    # verifies. Same MD_OUT/JSON_OUT/SUMMARY_OUT redirect that build.sh's
    # _run_local_ci_gate uses (order-489 prior art); explicit caller env
    # still wins. The TRACKED docs/convergence projection is committed
    # release evidence (docs/RELEASING.md step 4) and is refreshed by
    # scripts/release-preflight-local.sh AFTER this gate completes — never
    # between generation and the forge gate.
    if MD_OUT="${MD_OUT:-$REPO_ROOT/target/convergence/centicolon-dashboard.md}" \
        JSON_OUT="${JSON_OUT:-$REPO_ROOT/target/convergence/centicolon-dashboard.json}" \
        SUMMARY_OUT="${SUMMARY_OUT:-$REPO_ROOT/target/convergence/summary.md}" \
        bash scripts/update-convergence-dashboard.sh 2>&1 | tee /tmp/convergence-dashboard.log; then
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
    # A skipped check is NOT a passed check. Printing "ALL CHECKS PASSED" while
    # N gates never ran gives an agent positive evidence of coverage it does not
    # have, and that is how a guard silently stops guarding. Say what actually
    # ran, and name what did not, so the claim matches the evidence.
    if [[ $CHECKS_SKIPPED -gt 0 ]]; then
        printf '%b%s%b\n' "${GREEN}${BOLD}" "✓ CHECKS PASSED ($CHECKS_PASSED) — with $CHECKS_SKIPPED SKIPPED, so this is NOT full coverage" "${NC}"
        printf '%b%s%b\n' "${YELLOW}" "  Skipped gates did not run and did not pass. Re-run without --fast, or on a host that satisfies their preconditions, before treating this as a release signal." "${NC}"
    else
        printf '%b%s%b\n' "${GREEN}${BOLD}" "✓ ALL CHECKS PASSED — Safe to push!" "${NC}"
    fi
    if [[ "$FAST_MODE" == "1" ]]; then
        printf '%b%s%b\n' "${YELLOW}" "  --fast ran the litmus at --size instant only; every size:quick test was SKIPPED by the runner (including the trace-index and self-clean-evidence guards)." "${NC}"
    fi
    printf '%b%s%b\n' "" "Dispatch the hosted release only for platform builds, signing, and publishing." "${NC}"
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
