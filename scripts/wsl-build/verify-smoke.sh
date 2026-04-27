#!/usr/bin/env bash
# scripts/wsl-build/verify-smoke.sh — post-init smoke test verifier.
#
# @trace spec:cross-platform
#
# Verifies that `tillandsias --init` on Windows produced a working
# enclave: all six WSL distros are imported and the basic forge-offline
# Layer 1 rules apply.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

FAIL=0
pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() { printf '  \xe2\x9c\x97 %s\n' "$*"; FAIL=$((FAIL+1)); }

[[ "$TILL_HAS_WSL" == 1 ]] || { echo "wsl.exe not available"; exit 1; }

echo "=== distro presence ==="
for s in enclave-init proxy forge git inference router; do
    if wsl_distro_exists "tillandsias-${s}"; then
        pass "tillandsias-${s} imported"
    else
        fail "tillandsias-${s} NOT imported"
    fi
done

echo "=== forge-offline Layer 1 (uid-iptables) ==="
# Boot enclave-init by running a no-op command — its [boot] command
# applies the iptables rules.
MSYS_NO_PATHCONV=1 wsl.exe -d tillandsias-enclave-init --user root -- /bin/true >/dev/null 2>&1 || true
sleep 2
# Inspect the iptables rules using any distro (they're in the shared netns).
rules=$(MSYS_NO_PATHCONV=1 wsl.exe -d tillandsias-proxy --user root -- /bin/sh -c 'iptables -L OUTPUT -v 2>/dev/null || apk add --no-cache iptables >/dev/null 2>&1; iptables -L OUTPUT -v 2>/dev/null' 2>&1 | tr -d '\0' | tr -d '\r')
if echo "$rules" | grep -q "TILLANDSIAS_FORGE_EGRESS"; then
    pass "iptables egress chain present"
else
    fail "iptables egress chain MISSING"
    echo "    rules dump:"
    echo "$rules" | sed 's/^/      /'
fi

echo "=== forge user uid range ==="
if wsl_distro_exists "tillandsias-forge"; then
    forge_uid=$(MSYS_NO_PATHCONV=1 wsl.exe -d tillandsias-forge --user forge -- /bin/sh -c 'id -u' 2>&1 | tr -d '\0' | tr -d '\r' | head -1)
    # Per design D4 / forge-offline spec: forge agents should run in 2000-2999.
    # Image-baked user is uid 1000 today; tray flips to 2000-2999 at attach
    # time. Just check the user exists.
    if [[ "$forge_uid" =~ ^[0-9]+$ ]]; then
        pass "tillandsias-forge runs forge user (uid=$forge_uid; tray will use 2000-2999 at attach)"
    else
        fail "tillandsias-forge has no forge user: $forge_uid"
    fi
fi

echo "=== no podman.exe on host ==="
if command -v podman.exe >/dev/null 2>&1; then
    fail "podman.exe is on PATH (Windows path should be wsl-only)"
else
    pass "no podman.exe (correct: Windows uses WSL only)"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "ALL SMOKE TESTS PASSED"
    exit 0
else
    echo "FAILED: $FAIL check(s)"
    exit 1
fi
