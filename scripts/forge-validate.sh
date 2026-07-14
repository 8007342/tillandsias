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

if [ -n "${FORGE_VALIDATE_CHECK_DIR:-}" ]; then
    credential_cmd=("$FORGE_VALIDATE_CHECK_DIR/credential")
    headless_cmd=("$FORGE_VALIDATE_CHECK_DIR/headless")
    eligibility_cmd=("$FORGE_VALIDATE_CHECK_DIR/eligibility")
else
    credential_cmd=(scripts/check-credential-channel.sh)
    headless_cmd=(cargo test -p tillandsias-headless --bin tillandsias --no-fail-fast)
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

if "${headless_cmd[@]}" >"$tmp/headless.stdout" 2>"$tmp/headless.stderr"; then
    printf 'PASS headless-tests\n'
    pass=$((pass + 1))
else
    headless_rc=$?
    printf 'FAIL headless-tests exit:%s\n' "$headless_rc"
    fail=$((fail + 1))
    report_failure_logs headless
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
