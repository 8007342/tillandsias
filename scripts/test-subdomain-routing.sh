#!/usr/bin/env bash
# test-subdomain-routing.sh — Smoke test for Squid .localhost cache_peer routing
# @trace spec:subdomain-routing-via-reverse-proxy, spec:fix-router-loopback-port
#
# Purpose: Verify that Squid correctly forwards .localhost requests to the router
# via cache_peer, enforcing enclave-internal routing for browser isolation.
#
# Tests validate:
#   1. Squid config contains localhost_subdomain ACL definition
#   2. Squid config allows http_access for localhost_subdomain
#   3. Squid config contains cache_peer routing to router:8080
#   4. cache_peer_access restricts to localhost_subdomain only
#   5. never_direct enforcement prevents public DNS resolution
#
# Usage: bash scripts/test-subdomain-routing.sh
#
# Exit codes:
#   0 = all tests pass
#   1 = at least one test failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SQUID_CONF="$PROJECT_ROOT/images/proxy/squid.conf"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper: print test result (uses literal string match with grep -F)
assert_present() {
    local name="$1"
    local file="$2"
    local pattern="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF "$pattern" "$file" 2>/dev/null; then
        echo "  ✓ $name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  ✗ $name (pattern not found: $pattern)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Helper: check pattern using extended regex
assert_regex() {
    local name="$1"
    local file="$2"
    local pattern="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        echo "  ✓ $name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  ✗ $name (pattern not found: $pattern)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_count() {
    local name="$1"
    local file="$2"
    local pattern="$3"
    local expected_count="$4"
    TESTS_RUN=$((TESTS_RUN + 1))
    local actual_count
    actual_count=$(grep -cE "$pattern" "$file" 2>/dev/null) || actual_count=0
    if [ "$actual_count" -ge "$expected_count" ]; then
        echo "  ✓ $name (found $actual_count occurrences)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  ✗ $name (expected $expected_count, found $actual_count)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

echo "=========================================="
echo "Smoke Test: Squid Subdomain Routing"
echo "=========================================="
echo ""

# Verify Squid config file exists
echo "Checking prerequisites..."
if [ ! -f "$SQUID_CONF" ]; then
    echo "ERROR: Squid config not found at $SQUID_CONF"
    exit 2
fi
echo "  ✓ Squid config found at $SQUID_CONF"
echo ""

# Test: ACL definition for .localhost subdomain
echo "Testing localhost_subdomain ACL definition..."
assert_regex \
    "ACL localhost_subdomain defines .localhost dstdomain rule" \
    "$SQUID_CONF" \
    "^acl localhost_subdomain dstdomain \.localhost$"
echo ""

# Test: HTTP access rule for localhost_subdomain
echo "Testing http_access for localhost_subdomain..."
assert_regex \
    "http_access allows localhost_subdomain traffic" \
    "$SQUID_CONF" \
    "^http_access allow localhost_subdomain$"
echo ""

# Test: cache_peer definition for router
echo "Testing cache_peer configuration..."
assert_present \
    "cache_peer routes to tillandsias-router" \
    "$SQUID_CONF" \
    "name=tillandsias-router"
echo ""

# Test: cache_peer address uses 127.0.0.1 (avoid DNS issues)
echo "Testing cache_peer loopback isolation..."
assert_regex \
    "cache_peer uses 127.0.0.1 to avoid DNS resolution issues" \
    "$SQUID_CONF" \
    "^cache_peer 127\.0\.0\.1 parent 8080"
echo ""

# Test: cache_peer_access restricts to localhost_subdomain
echo "Testing cache_peer access control..."
assert_regex \
    "cache_peer_access allows only localhost_subdomain traffic" \
    "$SQUID_CONF" \
    "^cache_peer_access tillandsias-router allow localhost_subdomain$"
assert_regex \
    "cache_peer_access denies all other traffic" \
    "$SQUID_CONF" \
    "^cache_peer_access tillandsias-router deny all$"
echo ""

# Test: never_direct enforcement
echo "Testing never_direct enforcement..."
assert_regex \
    "never_direct prevents public DNS for .localhost" \
    "$SQUID_CONF" \
    "^never_direct allow localhost_subdomain$"
echo ""

# Test: Trace annotations are present
echo "Testing trace annotations..."
assert_present \
    "@trace spec:subdomain-routing-via-reverse-proxy appears in config" \
    "$SQUID_CONF" \
    "spec:subdomain-routing-via-reverse-proxy"
assert_present \
    "spec:fix-router-loopback-port appears in config" \
    "$SQUID_CONF" \
    "spec:fix-router-loopback-port"
echo ""

# Summary
echo "=========================================="
echo "Results: $TESTS_PASSED/$TESTS_RUN tests passed"
echo "=========================================="

if [ $TESTS_FAILED -eq 0 ]; then
    echo "✓ All smoke tests passed"
    exit 0
else
    echo "✗ $TESTS_FAILED test(s) failed"
    exit 1
fi
