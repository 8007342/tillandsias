#!/usr/bin/env bash
# @trace spec:observability-convergence, spec:ci-release, spec:spec-traceability
#
# Lightweight hosted convergence pass. This runs on GitHub Actions against
# committed code and produces a separate source-namespaced metrics series.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SIGNATURE_DIR="$REPO_ROOT/target/convergence"
SIGNATURE_JSONL="$SIGNATURE_DIR/github-actions-signature.jsonl"
EVIDENCE_BUNDLE="$SIGNATURE_DIR/github-actions-evidence-bundle.json"
DELTA_JSON="$SIGNATURE_DIR/github-actions-delta.json"
DASHBOARD_MD="$REPO_ROOT/docs/convergence/github-actions-dashboard.md"
DASHBOARD_JSON="$REPO_ROOT/docs/convergence/github-actions-dashboard.json"
SUMMARY_MD="$SIGNATURE_DIR/github-actions-summary.md"

CI_TIMESTAMP="${GITHUB_RUN_STARTED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
CI_RUN_ID="${GITHUB_RUN_ID:-github-actions-$(date -u +%Y%m%dT%H%M%SZ)}"
SOURCE_COMMIT="$(git rev-parse --short=12 HEAD 2>/dev/null || echo "unknown")"
VERSION_VALUE="$(cat VERSION 2>/dev/null || echo "0.0.0.0")"
SOURCE_NAMESPACE="github_actions"
SERIES_LABEL="GitHub Actions Generated Only"

CHECKS_PASSED=0
CHECKS_FAILED=0
FAILED_CHECKS=()
FAILED_REASONS=()

CHECK_IDS=(
    spec-cheatsheet-binding
    spec-code-drift
    rust-formatting
    rust-clippy
    rust-tests
    cheatsheet-tiers
)

check_weight() {
    case "$1" in
        spec-cheatsheet-binding) echo 100 ;;
        spec-code-drift) echo 120 ;;
        rust-formatting) echo 40 ;;
        rust-clippy) echo 60 ;;
        rust-tests) echo 80 ;;
        cheatsheet-tiers) echo 80 ;;
        *) echo 0 ;;
    esac
}

check_spec_ref() {
    case "$1" in
        spec-cheatsheet-binding) echo "spec:spec-traceability" ;;
        spec-code-drift) echo "spec:spec-traceability" ;;
        rust-formatting) echo "spec:dev-build" ;;
        rust-clippy) echo "spec:dev-build" ;;
        rust-tests) echo "spec:testing" ;;
        cheatsheet-tiers) echo "spec:cheatsheet-source-layer" ;;
        *) echo "spec:unknown" ;;
    esac
}

failed_reason_for_check() {
    case "$1" in
        spec-cheatsheet-binding) echo "Spec-cheatsheet binding below 90% (see hosted CI log)" ;;
        spec-code-drift) echo "Spec-code drift detected: ghost traces or zero-trace specs found (see hosted CI log)" ;;
        rust-formatting) echo "Rust code not formatted: run 'cargo fmt --all'" ;;
        rust-clippy) echo "Clippy warnings found: run 'cargo clippy --workspace' to see details" ;;
        rust-tests) echo "Test failures detected: run 'cargo test --workspace --lib' to see details" ;;
        cheatsheet-tiers) echo "Cheatsheet tier errors or strict warnings found" ;;
        *) echo "Check failed: $1" ;;
    esac
}

log_pass() {
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

log_fail() {
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    FAILED_CHECKS+=("$1")
    FAILED_REASONS+=("$2")
}

run_check() {
    local check_id="$1"
    local command="$2"
    local log_file="/tmp/${check_id}.log"

    if bash -lc "$command" 2>&1 | tee "$log_file"; then
        log_pass
        return 0
    fi

    log_fail "$check_id" "$(failed_reason_for_check "$check_id")"
    return 1
}

write_signature() {
    mkdir -p "$SIGNATURE_DIR"

    local total_cc=0
    local passed_cc=0
    local residual_cc=0
    local failed_specs=()
    local failed_weights=()
    local failed_reasons_file
    failed_reasons_file="$(mktemp)"
    trap 'rm -f "$failed_reasons_file"' RETURN

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

    local failed_reasons_json='[]'
    if [[ -s "$failed_reasons_file" ]]; then
        failed_reasons_json="$(jq -sc '.' "$failed_reasons_file")"
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

    local ci_result="FAIL"
    if [[ $CHECKS_FAILED -eq 0 ]]; then
        ci_result="PASS"
    fi

    local signature_tmp
    signature_tmp="$(mktemp)"
    jq -nc \
        --arg timestamp "$CI_TIMESTAMP" \
        --arg version "$VERSION_VALUE" \
        --arg source_commit "$SOURCE_COMMIT" \
        --arg source_namespace "$SOURCE_NAMESPACE" \
        --arg ci_run_id "$CI_RUN_ID" \
        --arg release_date "$CI_TIMESTAMP" \
        --argjson expected_total_cc "$total_cc" \
        --argjson actual_earned_cc "$passed_cc" \
        --argjson residual_cc "$residual_cc" \
        --argjson percent_closed "$(awk -v earned="$passed_cc" -v total="$total_cc" 'BEGIN { if (total > 0) printf "%.6f", (earned / total) * 100; else printf "0.0" }')" \
        --arg ci_result "$ci_result" \
        --arg evidence_bundle_ref "target/convergence/github-actions-evidence-bundle.json" \
        --arg centicolon_projection_ref "docs/convergence/github-actions-dashboard.md" \
        --argjson top_residual_reasons "$failed_reasons_json" \
        --arg max_residual_spec "$max_residual_spec" \
        --arg max_residual_reason "$max_residual_reason" \
        --argjson max_residual_cc "$max_residual_cc" \
        --argjson failed_checks "$(printf '%s\n' "${FAILED_CHECKS[@]:-}" | jq -Rsc 'split("\n")[:-1]')" \
        --argjson failed_reasons "$(printf '%s\n' "${FAILED_REASONS[@]:-}" | jq -Rsc 'split("\n")[:-1]')" \
        '{
          timestamp:$timestamp,
          version:$version,
          source_commit:$source_commit,
          source_namespace:$source_namespace,
          ci_run_id:$ci_run_id,
          release_date:$release_date,
          expected_total_cc:$expected_total_cc,
          actual_earned_cc:$actual_earned_cc,
          residual_cc:$residual_cc,
          percent_closed:$percent_closed,
          ci_result:$ci_result,
          max_residual_spec:$max_residual_spec,
          max_residual_reason:$max_residual_reason,
          max_residual_cc:$max_residual_cc,
          evidence_bundle_ref:$evidence_bundle_ref,
          centicolon_projection_ref:$centicolon_projection_ref,
          top_residual_reasons:$top_residual_reasons,
          failed_checks:$failed_checks,
          failed_reasons:$failed_reasons
        }' >"$signature_tmp"

    if [[ -f "$SIGNATURE_JSONL" ]]; then
        cat "$SIGNATURE_JSONL" "$signature_tmp" >"$SIGNATURE_JSONL.new"
    else
        cat "$signature_tmp" >"$SIGNATURE_JSONL.new"
    fi
    mv "$SIGNATURE_JSONL.new" "$SIGNATURE_JSONL"
    rm -f "$signature_tmp"

    local signature_hash="n/a"
    if command -v sha256sum >/dev/null 2>&1; then
        signature_hash="$(sha256sum "$SIGNATURE_JSONL" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        signature_hash="$(shasum -a 256 "$SIGNATURE_JSONL" | awk '{print $1}')"
    fi

    jq -nc \
        --arg generated_at "$CI_TIMESTAMP" \
        --arg version "$VERSION_VALUE" \
        --arg source_commit "$SOURCE_COMMIT" \
        --arg source_namespace "$SOURCE_NAMESPACE" \
        --arg signature_hash "$signature_hash" \
        --arg delta_hash "n/a" \
        --arg dashboard_hash "n/a" \
        --arg ci_run_id "$CI_RUN_ID" \
        --argjson signature_records "$(wc -l < "$SIGNATURE_JSONL")" \
        --argjson delta_records 1 \
        --argjson project_cc_total "$total_cc" \
        --argjson project_cc_earned "$passed_cc" \
        --argjson residual_cc "$residual_cc" \
        --argjson check_count "${#CHECK_IDS[@]}" \
        '{
          generated_at:$generated_at,
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
        }' >"$DELTA_JSON"

    local delta_hash="n/a"
    if command -v sha256sum >/dev/null 2>&1; then
        delta_hash="$(sha256sum "$DELTA_JSON" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        delta_hash="$(shasum -a 256 "$DELTA_JSON" | awk '{print $1}')"
    fi

    local dashboard_hash="n/a"
    jq -nc \
        --arg generated_at "$CI_TIMESTAMP" \
        --arg version "$VERSION_VALUE" \
        --arg source_commit "$SOURCE_COMMIT" \
        --arg source_namespace "$SOURCE_NAMESPACE" \
        --arg signature_hash "$signature_hash" \
        --arg delta_hash "$delta_hash" \
        --arg dashboard_hash "$dashboard_hash" \
        --arg ci_run_id "$CI_RUN_ID" \
        --argjson signature_records "$(wc -l < "$SIGNATURE_JSONL")" \
        --argjson delta_records 1 \
        --argjson project_cc_total "$total_cc" \
        --argjson project_cc_earned "$passed_cc" \
        --argjson residual_cc "$residual_cc" \
        --argjson check_count "${#CHECK_IDS[@]}" \
        '{
          generated_at:$generated_at,
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

    TITLE="GitHub Actions Generated Only Dashboard" \
    SERIES_NAMESPACE="$SOURCE_NAMESPACE" \
    SERIES_LABEL="$SERIES_LABEL" \
    SOURCE="$SIGNATURE_JSONL" \
    MD_OUT="$DASHBOARD_MD" \
    JSON_OUT="$DASHBOARD_JSON" \
    SUMMARY_OUT="$SUMMARY_MD" \
    bash scripts/update-convergence-dashboard.sh >/tmp/github-actions-dashboard.log

    if command -v sha256sum >/dev/null 2>&1; then
        dashboard_hash="$(sha256sum "$DASHBOARD_MD" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        dashboard_hash="$(shasum -a 256 "$DASHBOARD_MD" | awk '{print $1}')"
    fi

    jq -nc \
        --arg generated_at "$CI_TIMESTAMP" \
        --arg version "$VERSION_VALUE" \
        --arg source_commit "$SOURCE_COMMIT" \
        --arg source_namespace "$SOURCE_NAMESPACE" \
        --arg signature_hash "$signature_hash" \
        --arg delta_hash "$delta_hash" \
        --arg dashboard_hash "$dashboard_hash" \
        --arg ci_run_id "$CI_RUN_ID" \
        --argjson signature_records "$(wc -l < "$SIGNATURE_JSONL")" \
        --argjson delta_records 1 \
        --argjson project_cc_total "$total_cc" \
        --argjson project_cc_earned "$passed_cc" \
        --argjson residual_cc "$residual_cc" \
        --argjson check_count "${#CHECK_IDS[@]}" \
        '{
          generated_at:$generated_at,
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
}

run_check spec-cheatsheet-binding "bash scripts/validate-spec-cheatsheet-binding-fast.sh"
run_check spec-code-drift "bash scripts/hooks/pre-commit-openspec.sh --ci-mode"
run_check rust-formatting "cargo fmt --check --all"
run_check rust-clippy "cargo clippy --workspace -- -D warnings"
run_check rust-tests "cargo test --workspace --lib"
run_check cheatsheet-tiers "bash scripts/check-cheatsheet-tiers.sh --strict"

write_signature

if [[ $CHECKS_FAILED -gt 0 ]]; then
    exit 1
fi
