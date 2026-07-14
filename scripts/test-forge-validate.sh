#!/usr/bin/env bash
# @trace spec:default-image
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

write_stub() {
    local path="$1"
    local output="$2"
    local status="$3"
    printf '#!/bin/sh\nprintf '\''%%s\\n'\'' '\''%s'\''\nexit %s\n' "$output" "$status" >"$path"
    chmod +x "$path"
}

run_success_case() {
    local name="$1"
    local eligibility="$2"
    local expected="$3"
    local checks="$tmp/$name"
    mkdir -p "$checks"
    write_stub "$checks/credential" "ok:fixture" 0
    write_stub "$checks/headless" "headless fixture passed" 0
    write_stub "$checks/eligibility" "$eligibility" 0

    actual="$(FORGE_VALIDATE_CHECK_DIR="$checks" scripts/forge-validate.sh)"
    [ "$actual" = "$expected" ] || {
        printf 'FAIL: %s output mismatch\nexpected:\n%s\nactual:\n%s\n' \
            "$name" "$expected" "$actual" >&2
        exit 1
    }
}

run_success_case skip skip:no-podman-binary "$(cat <<'EOF'
PASS credential-channel ok:fixture
PASS headless-tests
SKIP e2e-eligibility skip:no-podman-binary
SUMMARY pass=2 skip=1 fail=0
EOF
)"

run_success_case eligible eligible "$(cat <<'EOF'
PASS credential-channel ok:fixture
PASS headless-tests
PASS e2e-eligibility eligible
SUMMARY pass=3 skip=0 fail=0
EOF
)"

checks="$tmp/fail"
mkdir -p "$checks"
write_stub "$checks/credential" "missing:no-credential-channel" 1
write_stub "$checks/headless" "headless fixture failed" 7
write_stub "$checks/eligibility" "unexpected" 0
if failure_output="$(FORGE_VALIDATE_CHECK_DIR="$checks" scripts/forge-validate.sh 2>/dev/null)"; then
    echo "FAIL: failing validation fixture returned success" >&2
    exit 1
fi
expected_failure="$(cat <<'EOF'
FAIL credential-channel missing:no-credential-channel
FAIL headless-tests exit:7
FAIL e2e-eligibility invalid-output
SUMMARY pass=0 skip=0 fail=3
EOF
)"
[ "$failure_output" = "$expected_failure" ] || {
    printf 'FAIL: failure output mismatch\nexpected:\n%s\nactual:\n%s\n' \
        "$expected_failure" "$failure_output" >&2
    exit 1
}

echo "PASS: forge validation profile classifies PASS/SKIP/FAIL deterministically"
