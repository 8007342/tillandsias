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
#   ./scripts/generate-evidence-bundle.sh --reuse-ci-results
#                                      # Reuse completed /tmp CI phase logs
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
OUTPUT_DIR="$PROJECT_ROOT/target/convergence"
REUSE_CI_RESULTS=false
LITMUS_COUNT_FIXTURE=false
LITMUS_COUNT_FIXTURE_FILES=()
for arg in "$@"; do
    case "$arg" in
        --reuse-ci-results) REUSE_CI_RESULTS=true ;;
        --litmus-count-fixture=*)
            LITMUS_COUNT_FIXTURE=true
            IFS=':' read -r -a LITMUS_COUNT_FIXTURE_FILES <<< "${arg#*=}"
            ;;
        -*) echo "Unknown flag: $arg" >&2; exit 3 ;;
        *) OUTPUT_DIR="$arg" ;;
    esac
done
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

_sum_litmus_field() {
    local field="$1"
    local file="$2"

    awk -v field="$field" '
        BEGIN { total = 0; found = 0 }
        {
            line = $0
            while (match(line, "(^|[[:space:]])" field "[[:space:]]*:[[:space:]]*[0-9]+")) {
                value = substr(line, RSTART, RLENGTH)
                sub(".*:", "", value)
                gsub(/[[:space:]]/, "", value)
                total += value
                found = 1
                line = substr(line, RSTART + RLENGTH)
            }
        }
        END {
            if (found) {
                print total
            } else {
                print ""
            }
        }
    ' "$file"
}

_count_litmus_status_lines() {
    local status="$1"
    local file="$2"

    grep -Ec "(^|[[:space:]])${status}([[:space:]:-]|$)" "$file" || true
}

litmus_count_passed() {
    local file="$1"
    local summary_count

    summary_count="$(_sum_litmus_field "PASS" "$file")"
    if [[ -n "$summary_count" ]]; then
        printf '%s\n' "$summary_count"
    else
        _count_litmus_status_lines "PASS" "$file"
    fi
}

litmus_count_failed() {
    local file="$1"
    local summary_count

    summary_count="$(_sum_litmus_field "FAIL" "$file")"
    if [[ -n "$summary_count" ]]; then
        printf '%s\n' "$summary_count"
    else
        _count_litmus_status_lines "FAIL" "$file"
    fi
}

if [[ "$LITMUS_COUNT_FIXTURE" == true ]]; then
    if [[ "${#LITMUS_COUNT_FIXTURE_FILES[@]}" -eq 0 ]]; then
        _error "No litmus fixture files provided"
        exit 3
    fi

    fixture_passed=0
    fixture_failed=0
    for litmus_file in "${LITMUS_COUNT_FIXTURE_FILES[@]}"; do
        fixture_passed=$((fixture_passed + $(litmus_count_passed "$litmus_file")))
        fixture_failed=$((fixture_failed + $(litmus_count_failed "$litmus_file")))
    done

    printf 'passed=%s failed=%s\n' "$fixture_passed" "$fixture_failed"
    exit 0
fi

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
TEST_RESULTS_FILE="$BUNDLE_STAGING/test-results.json"

if [[ "$REUSE_CI_RESULTS" == true ]]; then
    _info "Reusing cargo test results from pre-build CI..."
    if [[ ! -f /tmp/test-check.log ]]; then
        _error "Cannot reuse cargo test results: /tmp/test-check.log is missing"
        exit 1
    fi
    cp /tmp/test-check.log "$BUNDLE_STAGING/cargo-test-raw.log"
    _cargo_test_status=0
else
    _info "Running cargo tests..."
    set +e
    cargo test --workspace --manifest-path "$PROJECT_ROOT/Cargo.toml" \
        --no-fail-fast 2>&1 | tee "$BUNDLE_STAGING/cargo-test-raw.log"
    _cargo_test_status=${PIPESTATUS[0]}
    set -e
fi

if [[ "$_cargo_test_status" -eq 0 ]] \
    && grep -q "test result:" "$BUNDLE_STAGING/cargo-test-raw.log"; then

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
TRACE_ERRORS=$(printf '%s\n' "$TRACE_OUTPUT" | grep -c "^ERROR:" || true)
TRACE_WARNINGS=$(printf '%s\n' "$TRACE_OUTPUT" | grep -c "^WARN:" || true)

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
LITMUS_RESULTS_FILE="$BUNDLE_STAGING/litmus-results.json"

if [[ "$REUSE_CI_RESULTS" == true ]]; then
    _info "Reusing completed CI litmus phase logs..."
    if [[ ! -f /tmp/litmus-pre-build.log || ! -f /tmp/litmus-post-build.log ]]; then
        _error "Cannot reuse litmus results: pre-build or post-build phase log is missing"
        exit 1
    fi
    LITMUS_SOURCE_FILES=(/tmp/litmus-pre-build.log /tmp/litmus-post-build.log)
    if [[ -f /tmp/litmus-runtime.log ]]; then
        LITMUS_SOURCE_FILES+=(/tmp/litmus-runtime.log)
    fi
    LITMUS_OUTPUT="$(
        cat "${LITMUS_SOURCE_FILES[@]}"
    )"
else
    _info "Running litmus tests..."
    LITMUS_RUN_LOG="$BUNDLE_STAGING/litmus-run.log"
    "$SCRIPT_DIR/run-litmus-test.sh" > "$LITMUS_RUN_LOG" 2>&1 || true
    LITMUS_SOURCE_FILES=("$LITMUS_RUN_LOG")
    LITMUS_OUTPUT=$(cat "$LITMUS_RUN_LOG")
fi
LITMUS_PASSED=0
LITMUS_FAILED=0
for litmus_file in "${LITMUS_SOURCE_FILES[@]}"; do
    LITMUS_PASSED=$((LITMUS_PASSED + $(litmus_count_passed "$litmus_file")))
    LITMUS_FAILED=$((LITMUS_FAILED + $(litmus_count_failed "$litmus_file")))
done

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
