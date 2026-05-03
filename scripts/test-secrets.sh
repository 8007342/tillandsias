#!/usr/bin/env bash
# Test script to verify podman secrets are created, mounted, and protected correctly.
#
# This script runs four independent tests:
#   Test 1: Create dummy secret, mount to container, verify readable at /run/secrets/
#   Test 2: Verify secret NOT visible in `podman inspect` output
#   Test 3: Verify secret NOT visible in `ps -eaux` inside container
#   Test 4: Cleanup and verify secret is removed
#
# Usage: scripts/test-secrets.sh [--verbose]
#
# Environment:
#   PODMAN_PATH           Path to podman binary (optional, auto-detected)
#   TEST_IMAGE            Container image to use for testing (default: alpine:latest)
#
# Exit codes:
#   0 = all tests passed
#   1 = any test failed
#
# @trace spec:secrets-management, spec:podman-secrets-integration

set -euo pipefail

# Resolve the podman binary
if [[ -n "${PODMAN_PATH:-}" ]] && [[ -x "$PODMAN_PATH" ]]; then
    PODMAN="$PODMAN_PATH"
elif [[ -x /usr/bin/podman ]]; then
    PODMAN=/usr/bin/podman
elif [[ -x /usr/local/bin/podman ]]; then
    PODMAN=/usr/local/bin/podman
else
    PODMAN=podman
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[test-secrets]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[test-secrets]${NC} $*"; }
_error() { echo -e "${RED}[test-secrets]${NC} $*" >&2; }
_step()  { echo -e "${CYAN}[test-secrets]${NC} $*"; }
_pass()  { echo -e "${GREEN}[test-secrets] ✓${NC} $*"; }
_fail()  { echo -e "${RED}[test-secrets] ✗${NC} $*" >&2; }

# Argument parsing
VERBOSE=false
TEST_IMAGE="${TEST_IMAGE:-alpine:latest}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose)
            VERBOSE=true
            ;;
        --help|-h)
            echo "Usage: scripts/test-secrets.sh [--verbose]"
            echo ""
            echo "Test podman secrets creation, mounting, and protection."
            echo ""
            echo "Options:"
            echo "  --verbose   Show detailed test output"
            echo "  --help      Show this message"
            exit 0
            ;;
        *)
            _error "Unknown argument: $1 (try --help)"
            exit 1
            ;;
    esac
    shift
done

# Verify podman is available
if ! command -v "$PODMAN" &>/dev/null; then
    _error "podman not found at $PODMAN"
    exit 1
fi

_step "Testing podman secrets (rootless mode: --userns=keep-id)"

# Global test state
TESTS_PASSED=0
TESTS_FAILED=0

# Test image to use (pull if needed)
_ensure_test_image() {
    if ! "$PODMAN" image exists "$TEST_IMAGE" &>/dev/null; then
        _info "Pulling test image: $TEST_IMAGE"
        if ! "$PODMAN" pull "$TEST_IMAGE" &>/dev/null; then
            _error "Failed to pull $TEST_IMAGE"
            return 1
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Test 1: Create secret, mount to container, verify readable
# ---------------------------------------------------------------------------
_test_secret_creation_and_mount() {
    _step "Test 1: Secret creation and container mount"

    local test_secret="test-secret-readable"
    local test_value="super-secret-token-12345"
    local container_name="test-secrets-mount-$$"

    # Cleanup any leftover secret/container from previous run
    "$PODMAN" secret rm "$test_secret" 2>/dev/null || true
    "$PODMAN" rm -f "$container_name" 2>/dev/null || true

    if [[ "$VERBOSE" == true ]]; then
        _info "  Creating secret: $test_secret"
    fi

    # Create the secret
    if ! echo "$test_value" | "$PODMAN" secret create --driver=file "$test_secret" - &>/dev/null; then
        _fail "Secret creation failed"
        ((TESTS_FAILED++)) || true
        return 1
    fi

    if [[ "$VERBOSE" == true ]]; then
        _info "  Launching container with secret mount..."
    fi

    # Launch container with secret mounted at /run/secrets/test_secret
    # Use --userns=keep-id for rootless testing
    local mount_output
    if ! mount_output=$("$PODMAN" run \
        --rm \
        --userns=keep-id \
        --secret "$test_secret" \
        "$TEST_IMAGE" \
        cat /run/secrets/"$test_secret" 2>&1); then
        _fail "Container mount failed: $mount_output"
        "$PODMAN" secret rm "$test_secret" 2>/dev/null || true
        ((TESTS_FAILED++)) || true
        return 1
    fi

    # Verify the secret content matches
    if [[ "$mount_output" == "$test_value" ]]; then
        _pass "Secret mounted and readable at /run/secrets/"
        ((TESTS_PASSED++)) || true
    else
        _fail "Secret content mismatch (expected '$test_value', got '$mount_output')"
        ((TESTS_FAILED++)) || true
    fi

    # Cleanup
    "$PODMAN" secret rm "$test_secret" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test 2: Verify secret NOT visible in `podman inspect`
# ---------------------------------------------------------------------------
_test_secret_not_in_inspect() {
    _step "Test 2: Secret NOT visible in podman inspect"

    local test_secret="test-secret-inspect"
    local test_value="confidential-token-$$"
    local container_name="test-secrets-inspect-$$"

    # Cleanup
    "$PODMAN" secret rm "$test_secret" 2>/dev/null || true
    "$PODMAN" rm -f "$container_name" 2>/dev/null || true

    if [[ "$VERBOSE" == true ]]; then
        _info "  Creating secret: $test_secret"
    fi

    # Create the secret
    if ! echo "$test_value" | "$PODMAN" secret create --driver=file "$test_secret" - &>/dev/null; then
        _fail "Secret creation failed"
        ((TESTS_FAILED++)) || true
        return 1
    fi

    if [[ "$VERBOSE" == true ]]; then
        _info "  Launching container and inspecting..."
    fi

    # Launch container and capture its ID
    local container_id
    container_id=$("$PODMAN" run \
        --rm \
        -d \
        --userns=keep-id \
        --secret "$test_secret" \
        "$TEST_IMAGE" \
        sleep 10)

    # Inspect the container and check if secret VALUE appears anywhere
    local inspect_output
    inspect_output=$("$PODMAN" inspect "$container_id" 2>&1 || true)

    # Secret VALUES should never appear in inspect output
    # Note: The secret NAME may appear in the Secrets section (expected), but not the VALUE
    if echo "$inspect_output" | grep -q "$test_value"; then
        _fail "Secret VALUE visible in podman inspect output"
        "$PODMAN" rm -f "$container_id" 2>/dev/null || true
        "$PODMAN" secret rm "$test_secret" 2>/dev/null || true
        ((TESTS_FAILED++)) || true
        return 1
    fi

    _pass "Secret value NOT visible in podman inspect"
    ((TESTS_PASSED++)) || true

    # Cleanup
    "$PODMAN" rm -f "$container_id" 2>/dev/null || true
    "$PODMAN" secret rm "$test_secret" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test 3: Verify secret NOT visible in ps inside container
# ---------------------------------------------------------------------------
_test_secret_not_in_ps() {
    _step "Test 3: Secret NOT visible in ps inside container"

    local test_secret="test-secret-ps"
    local test_value="hidden-credential-$$"

    # Cleanup
    "$PODMAN" secret rm "$test_secret" 2>/dev/null || true

    if [[ "$VERBOSE" == true ]]; then
        _info "  Creating secret: $test_secret"
    fi

    # Create the secret
    if ! echo "$test_value" | "$PODMAN" secret create --driver=file "$test_secret" - &>/dev/null; then
        _fail "Secret creation failed"
        ((TESTS_FAILED++)) || true
        return 1
    fi

    if [[ "$VERBOSE" == true ]]; then
        _info "  Running ps inside container with mounted secret..."
    fi

    # Run ps inside the container and capture output
    # Note: Alpine's ps is minimal and doesn't support all flags; use basic ps with args
    local ps_output
    if ! ps_output=$("$PODMAN" run \
        --rm \
        --userns=keep-id \
        --secret "$test_secret" \
        "$TEST_IMAGE" \
        ps -o pid,args 2>&1); then
        _fail "ps command in container failed: $ps_output"
        "$PODMAN" secret rm "$test_secret" 2>/dev/null || true
        ((TESTS_FAILED++)) || true
        return 1
    fi

    # Secret value should never appear in ps output
    if echo "$ps_output" | grep -q "$test_value"; then
        _fail "Secret value visible in container ps output"
        "$PODMAN" secret rm "$test_secret" 2>/dev/null || true
        ((TESTS_FAILED++)) || true
        return 1
    fi

    _pass "Secret value NOT visible in container ps output"
    ((TESTS_PASSED++)) || true

    # Cleanup
    "$PODMAN" secret rm "$test_secret" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test 4: Cleanup and verify removal
# ---------------------------------------------------------------------------
_test_secret_cleanup() {
    _step "Test 4: Secret cleanup and removal verification"

    local test_secret="test-secret-cleanup"
    local test_value="temporary-secret-$$"

    if [[ "$VERBOSE" == true ]]; then
        _info "  Creating secret: $test_secret"
    fi

    # Create the secret
    if ! echo "$test_value" | "$PODMAN" secret create --driver=file "$test_secret" - &>/dev/null; then
        _fail "Secret creation failed"
        ((TESTS_FAILED++)) || true
        return 1
    fi

    # Verify it exists
    if ! "$PODMAN" secret inspect "$test_secret" &>/dev/null; then
        _fail "Created secret not found in podman"
        ((TESTS_FAILED++)) || true
        return 1
    fi

    if [[ "$VERBOSE" == true ]]; then
        _info "  Removing secret: $test_secret"
    fi

    # Remove the secret
    if ! "$PODMAN" secret rm "$test_secret" &>/dev/null; then
        _fail "Secret removal failed"
        ((TESTS_FAILED++)) || true
        return 1
    fi

    # Verify it's gone
    if "$PODMAN" secret inspect "$test_secret" &>/dev/null; then
        _fail "Secret still exists after removal"
        ((TESTS_FAILED++)) || true
        return 1
    fi

    _pass "Secret successfully removed and verified gone"
    ((TESTS_PASSED++)) || true
}

# ---------------------------------------------------------------------------
# Main test execution
# ---------------------------------------------------------------------------

# Ensure test image is available
if ! _ensure_test_image; then
    _error "Cannot proceed without test image"
    exit 1
fi

_info "Running test suite..."
_info ""

# Run all tests
_test_secret_creation_and_mount
_test_secret_not_in_inspect
_test_secret_not_in_ps
_test_secret_cleanup

# Print summary
_info ""
_step "Test Summary"
_info "  Passed: $TESTS_PASSED"
_info "  Failed: $TESTS_FAILED"
_info ""

# Exit with appropriate code
if [[ $TESTS_FAILED -eq 0 ]]; then
    _info "All tests ${BOLD}PASSED${NC}"
    exit 0
else
    _error "Some tests ${BOLD}FAILED${NC}"
    exit 1
fi
