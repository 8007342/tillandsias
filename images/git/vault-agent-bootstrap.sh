#!/bin/sh
# @trace spec:tillandsias-vault, spec:git-mirror-service
#
# Convert the launcher-provided AppRole JSON document into tmpfs files and
# exec the official Vault Agent. Credential values are never placed in argv or
# environment variables. Vault Agent owns renewal plus max_ttl re-authentication
# and atomically refreshes the file sink consumed by vault-cli.

set -eu

APPROLE_DOCUMENT="${VAULT_APPROLE_DOCUMENT:-/run/secrets/vault-approle}"
ROLE_ID_FILE="${VAULT_ROLE_ID_FILE:-/tmp/tillandsias-vault-role-id}"
SECRET_ID_FILE="${VAULT_SECRET_ID_FILE:-/tmp/tillandsias-vault-secret-id}"
VAULT_AGENT_CONFIG="${VAULT_AGENT_CONFIG:-/etc/tillandsias/vault-agent.hcl}"
VAULT_AGENT_BIN="${VAULT_AGENT_BIN:-/usr/local/bin/vault}"

fail() {
    echo "[vault-agent] auto-auth bootstrap failed: $*" >&2
    exit 1
}

[ -r "$APPROLE_DOCUMENT" ] \
    || fail "AppRole document is not readable at $APPROLE_DOCUMENT"
[ -r "$VAULT_AGENT_CONFIG" ] \
    || fail "Vault Agent config is not readable at $VAULT_AGENT_CONFIG"
[ -x "$VAULT_AGENT_BIN" ] \
    || fail "Vault Agent binary is not executable at $VAULT_AGENT_BIN"

umask 077
jq -er '.role_id | strings | select(length > 0)' \
    "$APPROLE_DOCUMENT" > "$ROLE_ID_FILE" \
    || fail "AppRole document has no non-empty role_id"
jq -er '.secret_id | strings | select(length > 0)' \
    "$APPROLE_DOCUMENT" > "$SECRET_ID_FILE" \
    || fail "AppRole document has no non-empty secret_id"
chmod 0400 "$ROLE_ID_FILE" "$SECRET_ID_FILE"

echo "[vault-agent] starting auto-auth (renew + re-auth enabled)"
exec "$VAULT_AGENT_BIN" agent -config="$VAULT_AGENT_CONFIG"
