#!/usr/bin/env bash
# @trace spec:default-image
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
skip=0
fail=0
push_cmd=()

if [ -n "${FORGE_VALIDATE_CHECK_DIR:-}" ]; then
    credential_cmd=("$FORGE_VALIDATE_CHECK_DIR/credential")
    push_cmd=("$FORGE_VALIDATE_CHECK_DIR/push")
    workspace_cmd=("$FORGE_VALIDATE_CHECK_DIR/workspace")
    headless_cmd=("$FORGE_VALIDATE_CHECK_DIR/headless")
    services_cmd=("$FORGE_VALIDATE_CHECK_DIR/services")
    eligibility_cmd=("$FORGE_VALIDATE_CHECK_DIR/eligibility")
else
    credential_cmd=(scripts/check-credential-channel.sh)
    workspace_cmd=(cargo check --workspace)
    headless_cmd=(cargo test -p tillandsias-headless --bin tillandsias --no-fail-fast)
    services_cmd=(scripts/check-forge-service-health.sh)
    eligibility_cmd=(scripts/e2e-preflight.sh eligibility)
fi

report_failure_logs() {
    local check="$1"
    for stream in stdout stderr; do
        if [ -s "$tmp/$check.$stream" ]; then
            printf '%s %s:\n' "$check" "$stream" >&2
            cat "$tmp/$check.$stream" >&2
        fi
    done
}

if "${credential_cmd[@]}" >"$tmp/credential.stdout" 2>"$tmp/credential.stderr"; then
    credential_rc=0
else
    credential_rc=$?
fi
credential_verdict="$(cat "$tmp/credential.stdout")"
if [ "$credential_rc" -eq 0 ] && [[ "$credential_verdict" =~ ^ok:[a-z0-9-]+$ ]]; then
    printf 'PASS credential-channel %s\n' "$credential_verdict"
    pass=$((pass + 1))
else
    case "$credential_verdict" in
        missing:no-credential-channel) credential_reason="$credential_verdict" ;;
        *) credential_reason="invalid-output" ;;
    esac
    printf 'FAIL credential-channel %s\n' "$credential_reason"
    fail=$((fail + 1))
    report_failure_logs credential
fi

if [ -z "${FORGE_VALIDATE_CHECK_DIR:-}" ]; then
    branch="$(git symbolic-ref --quiet --short HEAD || true)"
    if [ -n "$branch" ]; then
        push_cmd=(timeout 30 git push --dry-run origin "HEAD:refs/heads/$branch")
    fi
fi
if [ "${#push_cmd[@]}" -gt 0 ] \
    && "${push_cmd[@]}" >"$tmp/push.stdout" 2>"$tmp/push.stderr"; then
    printf 'PASS push-route-dry-run\n'
    pass=$((pass + 1))
else
    push_rc=$?
    printf 'FAIL push-route-dry-run exit:%s\n' "$push_rc"
    fail=$((fail + 1))
    report_failure_logs push
fi

if "${workspace_cmd[@]}" >"$tmp/workspace.stdout" 2>"$tmp/workspace.stderr"; then
    printf 'PASS workspace-check\n'
    pass=$((pass + 1))
else
    workspace_rc=$?
    printf 'FAIL workspace-check exit:%s\n' "$workspace_rc"
    fail=$((fail + 1))
    report_failure_logs workspace
fi

if "${headless_cmd[@]}" >"$tmp/headless.stdout" 2>"$tmp/headless.stderr"; then
    printf 'PASS headless-tests\n'
    pass=$((pass + 1))
else
    headless_rc=$?
    printf 'FAIL headless-tests exit:%s\n' "$headless_rc"
    fail=$((fail + 1))
    report_failure_logs headless
fi

if "${services_cmd[@]}" >"$tmp/services.stdout" 2>"$tmp/services.stderr"; then
    services_rc=0
else
    services_rc=$?
fi
services_verdict="$(cat "$tmp/services.stdout")"
if [ "$services_rc" -eq 0 ] && [[ "$services_verdict" =~ ^ok:[a-z0-9-]+$ ]]; then
    printf 'PASS service-health %s\n' "$services_verdict"
    pass=$((pass + 1))
elif [ "$services_rc" -eq 0 ] && [[ "$services_verdict" =~ ^skip:[a-z0-9-]+$ ]]; then
    printf 'SKIP service-health %s\n' "$services_verdict"
    skip=$((skip + 1))
else
    case "$services_verdict" in
        failed:*) services_reason="$services_verdict" ;;
        *) services_reason="invalid-output" ;;
    esac
    printf 'FAIL service-health %s\n' "$services_reason"
    fail=$((fail + 1))
    report_failure_logs services
fi

if "${eligibility_cmd[@]}" >"$tmp/eligibility.stdout" 2>"$tmp/eligibility.stderr"; then
    eligibility_rc=0
else
    eligibility_rc=$?
fi
eligibility_verdict="$(cat "$tmp/eligibility.stdout")"
if [ "$eligibility_rc" -eq 0 ] && [ "$eligibility_verdict" = "eligible" ]; then
    printf 'PASS e2e-eligibility eligible\n'
    pass=$((pass + 1))
elif [ "$eligibility_rc" -eq 0 ] && [[ "$eligibility_verdict" =~ ^skip:[a-z0-9-]+$ ]]; then
    printf 'SKIP e2e-eligibility %s\n' "$eligibility_verdict"
    skip=$((skip + 1))
else
    printf 'FAIL e2e-eligibility invalid-output\n'
    fail=$((fail + 1))
    report_failure_logs eligibility
fi

printf 'SUMMARY pass=%s skip=%s fail=%s\n' "$pass" "$skip" "$fail"
[ "$fail" -eq 0 ]
