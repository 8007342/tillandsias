#!/usr/bin/env bash
# @trace spec:default-image, spec:tillandsias-vault, spec:podman-secrets-integration
#
# Order 431: prove OpenCode consumes a Vault-derived OPENCODE_AUTH_CONTENT
# document while auth.json stays absent, and prove an upstream contract break
# takes the persistent curl cache's last-good rollback.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/images/default/lib-common.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

trace_lifecycle() {
    TRACE_LOG="${TRACE_LOG:-} $*"
}

[ -r "$LIB" ] || fail "cannot read $LIB"

# Source only the credential/probe/rollback functions. Sourcing all of
# lib-common would run forge-container setup on the build host.
eval "$(
    sed -n \
        '/^opencode_auth_file_path()/,/^}/p
         /^opencode_remove_stale_auth_file()/,/^}/p
         /^prepare_opencode_vault_auth()/,/^}/p
         /^opencode_auth_contract_ok()/,/^}/p
         /^opencode_actual_auth_ok()/,/^}/p
         /^harness_contract_help_cmd()/,/^}/p
         /^harness_contract_flags()/,/^}/p
         /^harness_contract_ok()/,/^}/p
         /^harness_probe()/,/^}/p
         /^opencode_curl_last_good_path()/,/^}/p
         /^opencode_record_curl_last_good()/,/^}/p
         /^opencode_restore_curl_last_good()/,/^}/p
         /^opencode_validate_or_rollback()/,/^}/p' \
        "$LIB"
)"

for function_name in \
    prepare_opencode_vault_auth \
    opencode_auth_contract_ok \
    opencode_actual_auth_ok \
    opencode_validate_or_rollback; do
    declare -F "$function_name" >/dev/null \
        || fail "could not load $function_name from lib-common.sh"
done

# Secret-construction shape: the Gemini value must flow to jq over stdin,
# never through `--arg` (which would expose it in jq's process argv).
PREPARE_SOURCE="$(sed -n '/^prepare_opencode_vault_auth()/,/^}/p' "$LIB")"
printf '%s' "$PREPARE_SOURCE" | grep -qF "jq -Rsc" \
    || fail "Gemini auth JSON is not assembled from stdin"
if printf '%s' "$PREPARE_SOURCE" | grep -Eq 'jq .*--arg .*gemini'; then
    fail "Gemini credential is exposed through jq argv"
fi

export HOME="$WORK/home"
export XDG_DATA_HOME="$WORK/data"
export XDG_STATE_HOME="$WORK/state"
mkdir -p "$HOME" "$XDG_DATA_HOME/opencode" "$XDG_STATE_HOME"

# Credential-absent regression: free Zen/local OpenCode stays valid, ambient
# non-Vault content is discarded, and even an empty stale auth.json is removed.
: >"$XDG_DATA_HOME/opencode/auth.json"
OPENCODE_AUTH_CONTENT="ambient-$RANDOM-$$"
export OPENCODE_AUTH_CONTENT
unset TILLANDSIAS_OPENCODE_AUTH_EXPECTED
prepare_opencode_vault_auth || fail "credential-free preparation failed"
[ -z "${OPENCODE_AUTH_CONTENT+x}" ] \
    || fail "credential-free lane retained ambient non-Vault auth content"
[ ! -e "$XDG_DATA_HOME/opencode/auth.json" ] \
    || fail "credential-free lane retained stale auth.json"

# Configured regression: the existing Gemini Vault producer is adapted to the
# exact OpenCode `google` auth record in memory. The runtime key is generated
# here; no credential literal lives in this committed fixture.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/vault-cli.sh" <<'STUB'
#!/usr/bin/env bash
if [ "$*" != "read -field=key secret/gemini/api-key" ]; then
    exit 64
fi
printf '%s' "${TEST_GEMINI_KEY:?}"
STUB
chmod +x "$WORK/bin/vault-cli.sh"
export PATH="$WORK/bin:$PATH"
export TEST_GEMINI_KEY="runtime-gemini-$RANDOM-$$-$(date +%s%N)"
export TILLANDSIAS_OPENCODE_AUTH_EXPECTED=1
OPENCODE_AUTH_CONTENT="ambient-must-not-win-$RANDOM-$$"
export OPENCODE_AUTH_CONTENT
prepare_opencode_vault_auth || fail "Vault-backed preparation failed"
printf '%s' "$OPENCODE_AUTH_CONTENT" \
    | jq -e \
        'keys == ["google"] and .google == {type:"api", key:env.TEST_GEMINI_KEY}' \
        >/dev/null \
    || fail "Vault Gemini key was not adapted to the OpenCode google record"
[ ! -e "$XDG_DATA_HOME/opencode/auth.json" ] \
    || fail "Vault-backed preparation created auth.json"

# The real locally installed OpenCode is evidence for the undocumented
# upstream contract. Hosts without it retain hermetic source/stub coverage.
REAL_OPENCODE="$(command -v opencode 2>/dev/null || true)"
if [ -n "$REAL_OPENCODE" ] && [ -x "$REAL_OPENCODE" ]; then
    opencode_auth_contract_ok "$REAL_OPENCODE" \
        || fail "installed OpenCode rejected the isolated sentinel contract"
    opencode_actual_auth_ok "$REAL_OPENCODE" \
        || fail "installed OpenCode did not report the injected Vault credential"
    if grep -R -a -F -f <(printf '%s' "$TEST_GEMINI_KEY") \
        "$XDG_DATA_HOME" "$XDG_STATE_HOME" >/dev/null 2>&1; then
        fail "installed OpenCode persisted the runtime credential in test state"
    fi
    REAL_VERSION="$("$REAL_OPENCODE" --version 2>/dev/null || echo unknown)"
    echo "installed OpenCode evidence: version=$REAL_VERSION provider=google count=1 auth.json=absent"
else
    echo "SKIP: locally installed OpenCode unavailable; hermetic contract coverage continues"
fi

# Rollback regression. Both harnesses are generated in isolated test state.
# The broken candidate is live but reports zero env credentials; the last-good
# candidate parses provider/count without printing the runtime key.
mkdir -p "$WORK/curl/opencode/bin" "$WORK/curl/opencode/last-good"
cat >"$WORK/good-opencode" <<'GOOD'
#!/usr/bin/env bash
case "$*" in
    *--version*) echo good; exit 0 ;;
    "run --help") echo "--auto --format"; exit 0 ;;
    "auth list")
        provider="$(printf '%s' "${OPENCODE_AUTH_CONTENT:-{}}" | jq -r 'keys[0] // empty')"
        count="$(printf '%s' "${OPENCODE_AUTH_CONTENT:-{}}" | jq -r 'length')"
        [ "$provider" != "google" ] || provider="Google"
        printf '%s api\n%s credentials\n' "$provider" "$count"
        exit 0
        ;;
esac
exit 1
GOOD
cat >"$WORK/broken-opencode" <<'BROKEN'
#!/usr/bin/env bash
case "$*" in
    *--version*) echo broken; exit 0 ;;
    "run --help") echo "--auto --format"; exit 0 ;;
    "auth list") echo "0 credentials"; exit 0 ;;
esac
exit 1
BROKEN
chmod +x "$WORK/good-opencode" "$WORK/broken-opencode"
install -m 0755 "$WORK/good-opencode" "$WORK/curl/opencode/last-good/opencode"
install -m 0755 "$WORK/broken-opencode" "$WORK/curl/opencode/bin/opencode"
HARNESS_CURL_ROOT="$WORK/curl"
export HARNESS_CURL_ROOT
TRACE_LOG=""
opencode_validate_or_rollback "$WORK/curl/opencode/bin/opencode" \
    || fail "broken candidate did not restore last-good"
[ "${OPENCODE_ROLLBACK_USED:-0}" = "1" ] \
    || fail "rollback helper did not report last-good use"
[ "$("$WORK/curl/opencode/bin/opencode" --version)" = "good" ] \
    || fail "last-good binary was not restored"
printf '%s' "$TRACE_LOG" | grep -q "rolling back to last-good" \
    || fail "contract failure did not produce a loud rollback trace"

unset OPENCODE_AUTH_CONTENT TEST_GEMINI_KEY
echo "PASS: OpenCode Vault auth content, no-file assertion, and last-good rollback"
