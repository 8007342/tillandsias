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
    write_stub "$checks/push" "dry-run fixture passed" 0
    write_stub "$checks/workspace" "workspace fixture passed" 0
    write_stub "$checks/headless" "headless fixture passed" 0
    write_stub "$checks/services" "skip:not-forge-host" 0
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
PASS push-dry-run
PASS workspace-check
PASS headless-tests
SKIP service-health skip:not-forge-host
SKIP e2e-eligibility skip:no-podman-binary
SUMMARY pass=4 skip=2 fail=0
EOF
)"

run_success_case eligible eligible "$(cat <<'EOF'
PASS credential-channel ok:fixture
PASS push-dry-run
PASS workspace-check
PASS headless-tests
SKIP service-health skip:not-forge-host
PASS e2e-eligibility eligible
SUMMARY pass=5 skip=1 fail=0
EOF
)"

checks="$tmp/fail"
mkdir -p "$checks"
write_stub "$checks/credential" "missing:no-credential-channel" 1
write_stub "$checks/push" "push fixture failed" 6
write_stub "$checks/workspace" "workspace fixture failed" 8
write_stub "$checks/headless" "headless fixture failed" 7
write_stub "$checks/services" "failed:vault-health" 1
write_stub "$checks/eligibility" "unexpected" 0
if failure_output="$(FORGE_VALIDATE_CHECK_DIR="$checks" scripts/forge-validate.sh 2>/dev/null)"; then
    echo "FAIL: failing validation fixture returned success" >&2
    exit 1
fi
expected_failure="$(cat <<'EOF'
FAIL credential-channel missing:no-credential-channel
FAIL push-dry-run exit:6
FAIL workspace-check exit:8
FAIL headless-tests exit:7
FAIL service-health failed:vault-health
FAIL e2e-eligibility invalid-output
SUMMARY pass=0 skip=0 fail=6
EOF
)"
[ "$failure_output" = "$expected_failure" ] || {
    printf 'FAIL: failure output mismatch\nexpected:\n%s\nactual:\n%s\n' \
        "$expected_failure" "$failure_output" >&2
    exit 1
}

health_checks="$tmp/health"
mkdir -p "$health_checks"
write_stub "$health_checks/services" '{"services":[{"status":"up"},{"status":"up"}]}' 0
write_stub "$health_checks/vault" "vault healthy" 0
write_stub "$health_checks/outbound" "outbound healthy" 0
health_output="$(
    TILLANDSIAS_HOST_KIND=forge \
    FORGE_SERVICE_HEALTH_CHECK_DIR="$health_checks" \
    scripts/check-forge-service-health.sh
)"
[ "$health_output" = "ok:forge-services" ] || {
    echo "FAIL: healthy forge service fixture did not pass" >&2
    exit 1
}
write_stub "$health_checks/services" '{"services":[{"status":"unreachable"}]}' 0
if health_output="$(
    TILLANDSIAS_HOST_KIND=forge \
    FORGE_SERVICE_HEALTH_CHECK_DIR="$health_checks" \
    scripts/check-forge-service-health.sh
)"; then
    echo "FAIL: unreachable forge service fixture returned success" >&2
    exit 1
fi
[ "$health_output" = "failed:enclave-services" ]

echo "PASS: forge validation profile classifies PASS/SKIP/FAIL deterministically"
