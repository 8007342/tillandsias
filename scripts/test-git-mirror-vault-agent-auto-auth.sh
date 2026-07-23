#!/usr/bin/env bash
# @trace spec:git-mirror-service, spec:tillandsias-vault, spec:podman-secrets-integration
#
# Hermetic order-424 fixture. A stub Vault Agent writes successive client-token
# generations to the same sink, modeling initial auth and max_ttl re-auth. The
# real relay and credential helper must complete a push with the new generation
# without restarting the Agent process. A deliberately absent sink must fail
# closed, then recover when auto-auth refreshes it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT/images/git/vault-agent-bootstrap.sh"
AGENT_CONFIG="$ROOT/images/git/vault-agent.hcl"
HELPER="$ROOT/images/git/git-credential-tillandsias.sh"
RELAY="$ROOT/images/git/relay-refs.sh"
ENTRYPOINT="$ROOT/images/git/entrypoint.sh"
WORK="$(mktemp -d)"
AGENT_PID=""

cleanup() {
    if [[ -n "$AGENT_PID" ]]; then
        kill -TERM "$AGENT_PID" 2>/dev/null || true
        wait "$AGENT_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for path in "$BOOTSTRAP" "$HELPER" "$RELAY" "$ENTRYPOINT" "$AGENT_CONFIG"; do
    [[ -r "$path" ]] || fail "required fixture input missing: $path"
done

REAL_GIT="$(command -v git)"
mkdir -p "$WORK/bin" "$WORK/state" "$WORK/home"
printf '%s\n' \
    '{"role_id":"role-id-order-424","secret_id":"secret-id-order-424"}' \
    > "$WORK/vault-approle.json"

# Stub only the official Agent process boundary. The repository bootstrap,
# relay, and credential helper remain the production implementations.
cat > "$WORK/bin/vault-agent-stub" <<'STUB'
#!/bin/sh
set -eu
[ "${1:-}" = "agent" ] || exit 64
case "${2:-}" in -config=*) ;; *) exit 64 ;; esac

generation=1
write_generation() {
    tmp="${VAULT_TOKEN_SINK_FILE}.tmp.$$"
    printf 'agent-token-generation-%s\n' "$generation" > "$tmp"
    chmod 0400 "$tmp"
    mv "$tmp" "$VAULT_TOKEN_SINK_FILE"
}
reauthenticate() {
    generation=$((generation + 1))
    write_generation
}
trap reauthenticate USR1
printf '%s\n' "$*" > "$VAULT_AGENT_ARGV_LOG"
write_generation
while true; do sleep 1; done
STUB
chmod +x "$WORK/bin/vault-agent-stub"

export VAULT_APPROLE_DOCUMENT="$WORK/vault-approle.json"
export VAULT_ROLE_ID_FILE="$WORK/state/role-id"
export VAULT_SECRET_ID_FILE="$WORK/state/secret-id"
export VAULT_AGENT_CONFIG="$AGENT_CONFIG"
export VAULT_AGENT_BIN="$WORK/bin/vault-agent-stub"
export VAULT_TOKEN_FILE="$WORK/state/client-token"
export VAULT_TOKEN_SINK_FILE="$VAULT_TOKEN_FILE"
export VAULT_AGENT_ARGV_LOG="$WORK/state/agent-argv"

"$BOOTSTRAP" > "$WORK/state/agent.log" 2>&1 &
AGENT_PID=$!

wait_for_generation() {
    local expected="$1"
    local _attempt
    for _attempt in {1..80}; do
        if [[ -r "$VAULT_TOKEN_FILE" ]] \
            && [[ "$(<"$VAULT_TOKEN_FILE")" == "$expected" ]]; then
            return 0
        fi
        sleep 0.1
    done
    fail "timed out waiting for token generation '$expected'"
}

wait_for_generation "agent-token-generation-1"
[[ "$(<"$VAULT_ROLE_ID_FILE")" == "role-id-order-424" ]] \
    || fail "bootstrap did not extract role_id"
[[ "$(<"$VAULT_SECRET_ID_FILE")" == "secret-id-order-424" ]] \
    || fail "bootstrap did not extract secret_id"
if grep -Eq 'role-id-order-424|secret-id-order-424' "$VAULT_AGENT_ARGV_LOG"; then
    fail "AppRole material leaked into Vault Agent argv"
fi
echo "case 1 ok: AppRole material reaches tmpfs files, never Agent argv"

# vault-cli seam used by the production helper and relay. It reads whichever
# Agent generation is current; a missing sink models the bounded expiry gap.
cat > "$WORK/bin/vault-cli" <<'STUB'
#!/bin/sh
set -eu
case "${1:-}" in
    read)
        [ -s "$VAULT_TOKEN_FILE" ] || exit 2
        printf 'github-%s' "$(cat "$VAULT_TOKEN_FILE")"
        ;;
    lookup-self)
        [ -s "$VAULT_TOKEN_FILE" ] || exit 2
        ;;
    *)
        exit 4
        ;;
esac
STUB

# The fake transport consumes Git's real credential-helper protocol but avoids
# external network I/O. It records only argv and the helper result so this
# fixture can prove a whole relay transaction selected the refreshed secret.
cat > "$WORK/bin/git" <<'STUB'
#!/bin/sh
set -eu
case "${1:-} ${2:-}" in
    "remote get-url")
        exec "$REAL_GIT" "$@"
        ;;
esac
case "${1:-}" in
    fetch)
        printf 'fetch %s\n' "$*" >> "$GIT_ARGV_LOG"
        exit 0
        ;;
    push)
        printf 'push %s\n' "$*" >> "$GIT_ARGV_LOG"
        credential="$(
            printf 'protocol=https\nhost=github.example.invalid\n\n' \
                | "$GIT_CONFIG_VALUE_1" get
        )"
        password="$(printf '%s\n' "$credential" | sed -n 's/^password=//p')"
        [ -n "$password" ] || exit 1
        printf '%s\n' "$password" >> "$GIT_PASSWORD_LOG"
        exit 0
        ;;
    *)
        exec "$REAL_GIT" "$@"
        ;;
esac
STUB
chmod +x "$WORK/bin/vault-cli" "$WORK/bin/git"

export REAL_GIT
export PATH="$WORK/bin:$PATH"
export HOME="$WORK/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CREDENTIAL_HELPER="$HELPER"
export GIT_ARGV_LOG="$WORK/state/git-argv"
export GIT_PASSWORD_LOG="$WORK/state/git-passwords"
: > "$GIT_CONFIG_GLOBAL"
: > "$GIT_ARGV_LOG"
: > "$GIT_PASSWORD_LOG"

MIRROR="$WORK/mirror.git"
"$REAL_GIT" init -q --bare "$MIRROR"
"$REAL_GIT" -C "$MIRROR" remote add origin \
    https://github.example.invalid/org/repo.git
RECORD="0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 refs/heads/main"

run_relay() {
    printf '%s\n' "$RECORD" | (cd "$MIRROR" && "$RELAY")
}

run_relay > "$WORK/state/relay-1.log" 2>&1 \
    || fail "initial relay transaction failed"
grep -qx 'github-agent-token-generation-1' "$GIT_PASSWORD_LOG" \
    || fail "initial relay did not consume generation 1 through the helper"

ORIGINAL_AGENT_PID="$AGENT_PID"
kill -USR1 "$AGENT_PID"
wait_for_generation "agent-token-generation-2"
run_relay > "$WORK/state/relay-2.log" 2>&1 \
    || fail "relay failed after simulated max_ttl re-authentication"
if [[ "$AGENT_PID" != "$ORIGINAL_AGENT_PID" ]] || ! kill -0 "$AGENT_PID"; then
    fail "Agent was restarted instead of re-authenticating in place"
fi
tail -n 1 "$GIT_PASSWORD_LOG" \
    | grep -qx 'github-agent-token-generation-2' \
    || fail "post-max_ttl relay did not consume the refreshed generation"
echo "case 2 ok: relay push succeeds after original token expiry without relaunch"

rm -f "$VAULT_TOKEN_FILE"
if run_relay > "$WORK/state/relay-expired.log" 2>&1; then
    fail "relay succeeded while the Vault Agent sink was absent"
fi
grep -Fq 'Vault Agent token is expired or unavailable' \
    "$WORK/state/relay-expired.log" \
    || fail "expiry gap did not emit the Vault Agent diagnosis"
kill -USR1 "$AGENT_PID"
wait_for_generation "agent-token-generation-3"
run_relay > "$WORK/state/relay-3.log" 2>&1 \
    || fail "relay did not recover after Agent refreshed an absent sink"
tail -n 1 "$GIT_PASSWORD_LOG" \
    | grep -qx 'github-agent-token-generation-3' \
    || fail "recovered relay did not consume generation 3"
echo "case 3 ok: expiry fails closed, then auto-auth refresh recovers"

if grep -Eq \
    'role-id-order-424|secret-id-order-424|github-agent-token-generation-' \
    "$GIT_ARGV_LOG"; then
    fail "credential material leaked into git fetch/push argv"
fi
grep -Fq 'GIT_CONFIG_VALUE_0=""' "$RELAY" \
    || fail "relay no longer resets inherited credential helpers"
echo "case 4 ok: AppRole and GitHub credentials stay out of git argv"

cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' "$@" > "$CURL_ARGV_LOG"
header_source=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --header)
            shift
            header_source="${1:-}"
            ;;
    esac
    shift
done
case "$header_source" in
    @*) cat "${header_source#@}" > "$CURL_HEADER_CAPTURE" ;;
    *) exit 65 ;;
esac
printf '{"data":{"ttl":3600}}\n'
STUB
chmod +x "$WORK/bin/curl"
: > "$WORK/state/ca.crt"
export CURL_ARGV_LOG="$WORK/state/curl-argv"
export CURL_HEADER_CAPTURE="$WORK/state/curl-header"
CURRENT_AGENT_TOKEN="$(<"$VAULT_TOKEN_FILE")"
LOOKUP_TTL="$(
    VAULT_CACERT="$WORK/state/ca.crt" \
    VAULT_ADDR="https://vault.example.invalid:8200" \
    "$ROOT/images/git/vault-cli.sh" lookup-self -field=ttl
)"
[[ "$LOOKUP_TTL" == "3600" ]] \
    || fail "production vault-cli did not parse lookup-self through the header file"
if grep -Fq "$CURRENT_AGENT_TOKEN" "$CURL_ARGV_LOG"; then
    fail "Vault Agent client token leaked into curl argv"
fi
grep -Fqx "X-Vault-Token: $CURRENT_AGENT_TOKEN" "$CURL_HEADER_CAPTURE" \
    || fail "vault-cli did not deliver the current Agent token as an HTTP header"
echo "case 5 ok: Vault client token reaches curl through tmpfs, never curl argv"

SHUTDOWN_WINDOW="$(sed -n '/^shutdown_git_service() {/,/^}/p' "$ENTRYPOINT")"
# Literal source assertion; expansion would search for this fixture's PID.
# shellcheck disable=SC2016
AGENT_STOP_LINE="$(
    printf '%s\n' "$SHUTDOWN_WINDOW" \
        | grep -nF 'kill -TERM "$VAULT_AGENT_PID"' \
        | head -n 1 \
        | cut -d: -f1
)"
TOKEN_REVOKE_LINE="$(
    printf '%s\n' "$SHUTDOWN_WINDOW" \
        | grep -nF 'vault-cli revoke-self' \
        | head -n 1 \
        | cut -d: -f1
)"
[[ -n "$AGENT_STOP_LINE" && -n "$TOKEN_REVOKE_LINE" ]] \
    || fail "shutdown does not contain both Agent stop and token revocation"
[[ "$AGENT_STOP_LINE" -lt "$TOKEN_REVOKE_LINE" ]] \
    || fail "shutdown revokes before stopping Agent, allowing a re-auth race"
TRAP_LINE="$(
    grep -nF "trap 'shutdown_git_service \$?' EXIT" "$ENTRYPOINT" \
        | head -n 1 \
        | cut -d: -f1
)"
START_LINE="$(
    grep -n '^start_vault_agent$' "$ENTRYPOINT" \
        | head -n 1 \
        | cut -d: -f1
)"
[[ -n "$TRAP_LINE" && -n "$START_LINE" && "$TRAP_LINE" -lt "$START_LINE" ]] \
    || fail "EXIT cleanup trap must be installed before Vault Agent starts"
grep -Fq 'refusing a credentialed mirror' "$ENTRYPOINT" \
    || fail "an expected-but-missing AppRole mount must fail loud"
echo "case 6 ok: shutdown/EXIT quiesces Agent before revoke and preserves fail-loud startup"

echo "PASS: git-mirror Vault Agent auto-auth survives max_ttl fixture (order 424)"
