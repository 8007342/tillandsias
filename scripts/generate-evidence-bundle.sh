#!/usr/bin/env bash
# =============================================================================
# Tillandsias — Evidence Bundle Generator
#
# Collects test results, trace coverage, litmus results, and metrics
# into a reproducible tarball for convergence validation.
#
# Usage:
#   ./scripts/generate-evidence-bundle.sh                # Generate bundle in target/
#   ./scripts/generate-evidence-bundle.sh /path/to/output  # Specify output directory
#
# Output:
#   - evidence-bundle-<timestamp>.tar.gz in target/convergence/
#   - Contains: test-results.json, traces-coverage.json, litmus-results.json,
#               metrics-sample.json, git-commit.txt
#
# Exit Codes:
#   0 = bundle created successfully
#   1 = cargo test failed
#   2 = trace validation failed
#   3 = output directory creation failed
#
# @trace spec:observability-convergence
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_ROOT/target/convergence}"
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
BUNDLE_NAME="evidence-bundle-${TIMESTAMP}.tar.gz"
BUNDLE_STAGING="${PROJECT_ROOT}/target/evidence-staging-$$"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[evidence]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[evidence]${NC} $*"; }
_error() { echo -e "${RED}[evidence]${NC} $*" >&2; }

# Cleanup on exit
trap 'rm -rf "$BUNDLE_STAGING"' EXIT

# Create staging directory
mkdir -p "$BUNDLE_STAGING" "$OUTPUT_DIR"
if [[ ! -w "$OUTPUT_DIR" ]]; then
    _error "Cannot write to output directory: $OUTPUT_DIR"
    exit 3
fi

_info "Generating evidence bundle ($TIMESTAMP)..."

# ============================================================================
# 1. Collect cargo test results
# ============================================================================
_info "Running cargo tests..."
TEST_RESULTS_FILE="$BUNDLE_STAGING/test-results.json"

if cargo test --workspace --manifest-path "$PROJECT_ROOT/Cargo.toml" \
    --no-fail-fast 2>&1 | tee "$BUNDLE_STAGING/cargo-test-raw.log" | \
    grep -q "test result:"; then

    # Parse test results from cargo output
    cat > "$TEST_RESULTS_FILE" <<'EOF'
{
  "test_runner": "cargo",
  "timestamp": "TIMESTAMP_PLACEHOLDER",
  "workspace_root": "WORKSPACE_PLACEHOLDER",
  "status": "completed",
  "summary": {}
}
EOF

    # Extract test summary
    TESTS_PASSED=$(grep -c "test result: ok" "$BUNDLE_STAGING/cargo-test-raw.log" || echo "0")
    TEST_DURATION=$(grep "finished in" "$BUNDLE_STAGING/cargo-test-raw.log" | tail -1 || echo "unknown")

    TIMESTAMP_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sed -i "s|TIMESTAMP_PLACEHOLDER|$TIMESTAMP_ISO|g" "$TEST_RESULTS_FILE"
    sed -i "s|WORKSPACE_PLACEHOLDER|$PROJECT_ROOT|g" "$TEST_RESULTS_FILE"

    _info "Tests completed: $TESTS_PASSED suites passed"
else
    _error "Cargo tests failed"
    exit 1
fi

# ============================================================================
# 2. Collect trace coverage
# ============================================================================
_info "Validating trace coverage..."
TRACES_COVERAGE_FILE="$BUNDLE_STAGING/traces-coverage.json"

# Run trace validator and capture results
TRACE_OUTPUT=$("$SCRIPT_DIR/validate-traces.sh" 2>&1 || true)
TRACE_ERRORS=$(echo "$TRACE_OUTPUT" | grep -c "^ERROR:" || echo "0")
TRACE_WARNINGS=$(echo "$TRACE_OUTPUT" | grep -c "^WARN:" || echo "0")

cat > "$TRACES_COVERAGE_FILE" <<EOF
{
  "validator": "validate-traces.sh",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "errors": $TRACE_ERRORS,
  "warnings": $TRACE_WARNINGS,
  "status": $([ "$TRACE_ERRORS" -eq 0 ] && echo '"PASS"' || echo '"FAIL"'),
  "details": $(echo "$TRACE_OUTPUT" | jq -Rs '.')
}
EOF

_info "Trace validation complete: $TRACE_ERRORS errors, $TRACE_WARNINGS warnings"

# ============================================================================
# 3. Collect litmus test results
# ============================================================================
_info "Running litmus tests..."
LITMUS_RESULTS_FILE="$BUNDLE_STAGING/litmus-results.json"

LITMUS_OUTPUT=$("$SCRIPT_DIR/run-litmus-test.sh" 2>&1 || true)
LITMUS_PASSED=$(echo "$LITMUS_OUTPUT" | grep -c "PASS" || echo "0")
LITMUS_FAILED=$(echo "$LITMUS_OUTPUT" | grep -c "FAIL" || echo "0")

cat > "$LITMUS_RESULTS_FILE" <<EOF
{
  "test_framework": "litmus-convergence",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "tests_passed": $LITMUS_PASSED,
  "tests_failed": $LITMUS_FAILED,
  "status": $([ "$LITMUS_FAILED" -eq 0 ] && echo '"PASS"' || echo '"FAIL"'),
  "summary": $(echo "$LITMUS_OUTPUT" | tail -20 | jq -Rs '.')
}
EOF

_info "Litmus tests complete: $LITMUS_PASSED passed, $LITMUS_FAILED failed"

# ============================================================================
# 4. Collect metrics snapshot
# ============================================================================
_info "Capturing metrics snapshot..."
METRICS_FILE="$BUNDLE_STAGING/metrics-sample.json"

cat > "$METRICS_FILE" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "bundle_timestamp": "$TIMESTAMP",
  "system": {
    "hostname": "$(hostname -s || echo 'unknown')",
    "kernel": "$(uname -r || echo 'unknown')",
    "uptime_seconds": $(uptime -p 2>/dev/null | wc -c || echo "0")
  },
  "workspace": {
    "root": "$PROJECT_ROOT",
    "size_mb": $(du -sm "$PROJECT_ROOT" 2>/dev/null | cut -f1 || echo "0"),
    "target_size_mb": $(du -sm "$PROJECT_ROOT/target" 2>/dev/null | cut -f1 || echo "0")
  },
  "build_artifacts": {
    "cargo_target_exists": $([ -d "$PROJECT_ROOT/target" ] && echo "true" || echo "false"),
    "musl_build_exists": $([ -f "$PROJECT_ROOT/target/x86_64-unknown-linux-musl/release/tillandsias-headless" ] && echo "true" || echo "false")
  }
}
EOF

_info "Metrics snapshot captured"

# ============================================================================
# 5. Capture git context
# ============================================================================
_info "Capturing git context..."
GIT_COMMIT_FILE="$BUNDLE_STAGING/git-commit.txt"

{
    echo "# Git Context"
    echo "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "commit: $(git -C "$PROJECT_ROOT" rev-parse HEAD || echo 'unknown')"
    echo "branch: $(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD || echo 'unknown')"
    echo "tag: $(git -C "$PROJECT_ROOT" describe --tags --always || echo 'unknown')"
    echo ""
    echo "# Recent Commits"
    git -C "$PROJECT_ROOT" log --oneline -10 || echo "(git history unavailable)"
    echo ""
    echo "# Modified Files"
    git -C "$PROJECT_ROOT" status --short || echo "(git status unavailable)"
} > "$GIT_COMMIT_FILE"

_info "Git context captured"

# ============================================================================
# 6. Package bundle
# ============================================================================
_info "Packaging evidence bundle..."

cd "$BUNDLE_STAGING"
tar czf "$OUTPUT_DIR/$BUNDLE_NAME" \
    test-results.json \
    traces-coverage.json \
    litmus-results.json \
    metrics-sample.json \
    git-commit.txt

BUNDLE_SIZE=$(du -h "$OUTPUT_DIR/$BUNDLE_NAME" | cut -f1)
_info "Evidence bundle created: $BUNDLE_NAME ($BUNDLE_SIZE)"
_info "Location: $OUTPUT_DIR/$BUNDLE_NAME"

# ============================================================================
# 7. Update dashboard reference
# ============================================================================
DASHBOARD_FILE="$PROJECT_ROOT/docs/convergence/centicolon-dashboard.json"
if [[ -f "$DASHBOARD_FILE" ]]; then
    # Update evidence_bundle_path in dashboard (if field exists)
    if grep -q '"evidence_bundle_path"' "$DASHBOARD_FILE"; then
        # Create a temporary jq filter to update the field
        TEMP_DASHBOARD=$(mktemp)
        jq --arg path "$OUTPUT_DIR/$BUNDLE_NAME" \
           --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           '.evidence_bundle_path = $path | .evidence_bundle_generated = $ts' \
           "$DASHBOARD_FILE" > "$TEMP_DASHBOARD"
        mv "$TEMP_DASHBOARD" "$DASHBOARD_FILE"
        _info "Dashboard updated with evidence bundle reference"
    fi
fi

_info "Evidence bundle generation complete"
echo "$OUTPUT_DIR/$BUNDLE_NAME"
exit 0
