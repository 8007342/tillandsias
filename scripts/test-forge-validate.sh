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
PASS push-route-dry-run
PASS workspace-check
PASS headless-tests
SKIP service-health skip:not-forge-host
SKIP e2e-eligibility skip:no-podman-binary
SUMMARY pass=4 skip=2 fail=0
EOF
)"

run_success_case eligible eligible "$(cat <<'EOF'
PASS credential-channel ok:fixture
PASS push-route-dry-run
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
FAIL push-route-dry-run exit:6
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

# BLOCKED IS A NAMED FAULT, NOT INVALID OUTPUT (order 756-2jnj). A forge whose
# mirror is reachable but not currently write-authorized upstream reports
# blocked:<reason>; the profile must surface that verdict verbatim so the
# transcript names the fault (the 2026-08-15 403 state) instead of the
# generic "invalid-output".
blocked="$tmp/blocked"
mkdir -p "$blocked"
write_stub "$blocked/credential" "blocked:upstream-push-unauthorized" 1
write_stub "$blocked/push" "dry-run fixture passed" 0
write_stub "$blocked/workspace" "workspace fixture passed" 0
write_stub "$blocked/headless" "headless fixture passed" 0
write_stub "$blocked/services" "skip:not-forge-host" 0
write_stub "$blocked/eligibility" "eligible" 0
if blocked_output="$(FORGE_VALIDATE_CHECK_DIR="$blocked" scripts/forge-validate.sh 2>/dev/null)"; then
    echo "FAIL: blocked credential fixture returned success" >&2
    exit 1
fi
expected_blocked="$(cat <<'EOF'
FAIL credential-channel blocked:upstream-push-unauthorized
PASS push-route-dry-run
PASS workspace-check
PASS headless-tests
SKIP service-health skip:not-forge-host
PASS e2e-eligibility eligible
SUMMARY pass=4 skip=1 fail=1
EOF
)"
[ "$blocked_output" = "$expected_blocked" ] || {
    printf 'FAIL: blocked-credential output mismatch\nexpected:\n%s\nactual:\n%s\n' \
        "$expected_blocked" "$blocked_output" >&2
    exit 1
}

# ABSENT IS NOT FAILED. With no branch to push (a detached HEAD), no push is
# attempted — and this used to print `FAIL push-route-dry-run exit:1`, naming an
# exit code nothing produced, with empty failure logs. Omitting the push stub
# reproduces that state: forge-validate.sh leaves push_cmd empty exactly as the
# real detached-HEAD path does.
no_push="$tmp/nopush"
mkdir -p "$no_push"
write_stub "$no_push/credential" "ok:fixture" 0
write_stub "$no_push/workspace" "workspace fixture passed" 0
write_stub "$no_push/headless" "headless fixture passed" 0
write_stub "$no_push/services" "skip:not-forge-host" 0
write_stub "$no_push/eligibility" "eligible" 0
no_push_output="$(FORGE_VALIDATE_CHECK_DIR="$no_push" scripts/forge-validate.sh)" || {
    echo "FAIL: an absent push route must not fail the profile" >&2
    exit 1
}
expected_no_push="$(cat <<'EOF'
PASS credential-channel ok:fixture
SKIP push-route-dry-run skip:no-branch-to-push
PASS workspace-check
PASS headless-tests
SKIP service-health skip:not-forge-host
PASS e2e-eligibility eligible
SUMMARY pass=4 skip=2 fail=0
EOF
)"
[ "$no_push_output" = "$expected_no_push" ] || {
    printf 'FAIL: absent-push output mismatch\nexpected:\n%s\nactual:\n%s\n' \
        "$expected_no_push" "$no_push_output" >&2
    exit 1
}

health_checks="$tmp/health"
mkdir -p "$health_checks"
write_stub "$health_checks/services" '{"services":[{"name":"proxy","status":"up"},{"name":"git-service","status":"up"},{"name":"inference","status":"up"}]}' 0
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
write_stub "$health_checks/services" '{"services":[{"name":"proxy","status":"up"},{"name":"git-service","status":"up"}]}' 0
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
