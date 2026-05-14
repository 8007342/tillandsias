#!/usr/bin/env bash
# test-convergence-dashboard.sh — Unit tests for the CentiColon dashboard projection.
# @trace spec:observability-convergence, spec:knowledge-source-of-truth
#
# Usage: bash scripts/test-convergence-dashboard.sh
#
# Tests validate:
#   1. The renderer produces a well-formed .md with the auto-generation header
#   2. The renderer produces a well-formed .json with the dashboard_contract object
#   3. Alert level classification is correct for sample percent_closed values
#   4. Trend metrics (pass_rate_7d, coverage_avg_7d) are computed over the last 7 records
#   5. Signature records include the required fields (release, commit, residual_cc, evidence)
#   6. The dashboard cites the source-of-truth spec for interpretation rules

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MD_PATH="docs/convergence/centicolon-dashboard.md"
JSON_PATH="docs/convergence/centicolon-dashboard.json"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_true() {
    local name="$1"
    local condition="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if eval "$condition"; then
        printf '  PASS  %s\n' "$name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        printf '  FAIL  %s\n' "$name"
        printf '          condition: %s\n' "$condition"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_equal() {
    local name="$1" actual="$2" expected="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$actual" = "$expected" ]; then
        printf '  PASS  %s\n' "$name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        printf '  FAIL  %s\n' "$name"
        printf '          expected: %s\n' "$expected"
        printf '          actual:   %s\n' "$actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

printf '\n[test] convergence dashboard projection\n'

# Regenerate fresh artefacts before testing so the run is hermetic
bash scripts/update-convergence-dashboard.sh >/dev/null 2>&1

# --- Group 1: rendered markdown shape ----------------------------------------
printf '\n  [group] rendered markdown shape\n'
assert_true "md exists" "[ -f '$MD_PATH' ]"
assert_true "md carries auto-generation header" \
    "grep -qF 'THIS FILE IS AUTO-GENERATED' '$MD_PATH'"
assert_true "md carries observability-convergence trace" \
    "grep -qF '@trace spec:observability-convergence' '$MD_PATH'"
assert_true "md carries knowledge-source-of-truth trace (multi-spec annotation)" \
    "grep -qF 'spec:knowledge-source-of-truth' '$MD_PATH'"
assert_true "md links back to source-of-truth spec" \
    "grep -qF 'openspec/specs/knowledge-source-of-truth/spec.md' '$MD_PATH'"
assert_true "md exposes Refresh Policy section" \
    "grep -qF '## Refresh Policy' '$MD_PATH'"
assert_true "md exposes Signature Format section" \
    "grep -qF '## Signature Format' '$MD_PATH'"
assert_true "md exposes Alert Thresholds section" \
    "grep -qF '## Alert Thresholds' '$MD_PATH'"
assert_true "md exposes Integration & Interpretation section" \
    "grep -qF '## Integration & Interpretation' '$MD_PATH'"

# --- Group 2: rendered json shape --------------------------------------------
printf '\n  [group] rendered json shape\n'
assert_true "json exists" "[ -f '$JSON_PATH' ]"
assert_true "json parses cleanly" "jq -e . '$JSON_PATH' >/dev/null"
assert_true "json has generated_at" "jq -e '.generated_at | type == \"string\"' '$JSON_PATH' >/dev/null"
assert_true "json has alert_level" "jq -e 'has(\"alert_level\")' '$JSON_PATH' >/dev/null"
assert_true "json has alert_thresholds" "jq -e '.alert_thresholds.red_below_percent_closed == 90' '$JSON_PATH' >/dev/null"
assert_true "json has yellow alert threshold" "jq -e '.alert_thresholds.yellow_below_percent_closed == 95' '$JSON_PATH' >/dev/null"
assert_true "json has dashboard_contract" "jq -e '.dashboard_contract | type == \"object\"' '$JSON_PATH' >/dev/null"
assert_true "dashboard_contract names source-of-truth spec" \
    "jq -e '.dashboard_contract.integration.source_of_truth == \"openspec/specs/knowledge-source-of-truth/spec.md\"' '$JSON_PATH' >/dev/null"
assert_true "dashboard_contract declares refresh cadence" \
    "jq -e '.dashboard_contract.refresh_policy.staleness_threshold_hours == 24' '$JSON_PATH' >/dev/null"
assert_true "dashboard_contract enumerates signature fields" \
    "jq -e '.dashboard_contract.signature_format.fields | length >= 10' '$JSON_PATH' >/dev/null"

# --- Group 3: alert level classification -------------------------------------
printf '\n  [group] alert level classification\n'
LATEST_PCT=$(jq -r '.latest.percent_closed // 0' "$JSON_PATH")
LATEST_ALERT=$(jq -r '.alert_level' "$JSON_PATH")
EXPECTED_ALERT=$(awk -v p="$LATEST_PCT" 'BEGIN {
    if (p < 90) print "red";
    else if (p < 95) print "yellow";
    else print "green";
}')
assert_equal "alert_level matches latest percent_closed=$LATEST_PCT" \
    "$LATEST_ALERT" "$EXPECTED_ALERT"

# --- Group 4: trend metrics --------------------------------------------------
printf '\n  [group] trend metrics over last 7 records\n'
RECORD_COUNT=$(jq '.record_count' "$JSON_PATH")
if [ "$RECORD_COUNT" -gt 0 ]; then
    assert_true "pass_rate_7d_percent is numeric" \
        "jq -e '.trend_metrics.pass_rate_7d_percent | type == \"number\"' '$JSON_PATH' >/dev/null"
    assert_true "coverage_avg_7d_percent is numeric" \
        "jq -e '.trend_metrics.coverage_avg_7d_percent | type == \"number\"' '$JSON_PATH' >/dev/null"

    # Compare against an independent computation from the history array
    EXPECTED_PASS=$(jq '.history[-7:] | (map(select(.ci_result == "PASS")) | length) / length * 100' "$JSON_PATH")
    ACTUAL_PASS=$(jq '.trend_metrics.pass_rate_7d_percent' "$JSON_PATH")
    assert_equal "pass_rate_7d_percent matches recomputation" \
        "$ACTUAL_PASS" "$EXPECTED_PASS"

    EXPECTED_AVG=$(jq '.history[-7:] | map(.percent_closed) | add / length' "$JSON_PATH")
    ACTUAL_AVG=$(jq '.trend_metrics.coverage_avg_7d_percent' "$JSON_PATH")
    assert_equal "coverage_avg_7d_percent matches recomputation" \
        "$ACTUAL_AVG" "$EXPECTED_AVG"
fi

# --- Group 5: signature record fields ----------------------------------------
printf '\n  [group] signature record fields\n'
if [ "$RECORD_COUNT" -gt 0 ]; then
    REQUIRED_FIELDS=(release date commit total_cc earned_cc residual_cc percent_closed worst_spec worst_reason evidence projection ci_result)
    for field in "${REQUIRED_FIELDS[@]}"; do
        assert_true "history[0] has field $field" \
            "jq -e '.history[0] | has(\"$field\")' '$JSON_PATH' >/dev/null"
    done
fi

# --- Group 5b: resource metrics block (Wave 13 Gap #3) -----------------------
# @trace spec:resource-metric-collection, spec:observability-metrics
printf '\n  [group] resource metrics block\n'
assert_true "json has metrics block" \
    "jq -e '.metrics | type == \"object\"' '$JSON_PATH' >/dev/null"
assert_true "metrics has cpu_percent" \
    "jq -e '.metrics.cpu_percent | type == \"number\"' '$JSON_PATH' >/dev/null"
assert_true "metrics has memory_percent" \
    "jq -e '.metrics.memory_percent | type == \"number\"' '$JSON_PATH' >/dev/null"
assert_true "metrics has disk_percent" \
    "jq -e '.metrics.disk_percent | type == \"number\"' '$JSON_PATH' >/dev/null"
assert_true "metrics has sample_timestamp" \
    "jq -e '.metrics.sample_timestamp | type == \"string\"' '$JSON_PATH' >/dev/null"
assert_true "metrics declares its source crate" \
    "jq -e '.metrics.source == \"tillandsias-metrics::DashboardSnapshot\"' '$JSON_PATH' >/dev/null"

# --- Group 6: source-of-truth integration ------------------------------------
printf '\n  [group] source-of-truth integration\n'
assert_true "source-of-truth spec exists and is active" \
    "grep -qF 'status: active' openspec/specs/knowledge-source-of-truth/spec.md"
assert_true "source-of-truth spec declares authority hierarchy" \
    "grep -qF 'code > specs > cheatsheets > docs' openspec/specs/knowledge-source-of-truth/spec.md"
assert_true "source-of-truth spec declares CRDT semantics" \
    "grep -qF 'CRDT-inspired monotonic convergence' openspec/specs/knowledge-source-of-truth/spec.md"
assert_true "source-of-truth spec declares evidence bundles" \
    "grep -qF 'Convergence evidence bundles' openspec/specs/knowledge-source-of-truth/spec.md"

# --- Summary -----------------------------------------------------------------
printf '\n[result] %d run, %d pass, %d fail\n' \
    "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"

if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
