#!/usr/bin/env bash
# @trace spec:tillandsias-vault
# provider-oauth-vault — generic restore/harvest/digest/watch for Claude and
# Antigravity OAuth credential documents (Codex has its own verified helper:
# codex-oauth-vault; a dedup migration is a filed follow-up). Same contract:
#   restore  vault -> credential file (fail loud, actionable)
#   harvest  credential file -> vault (opaque, stdin only)
#   digest   sha256 of the credential file (or "missing")
#   watch    poll while CHILD_PID lives; harvest on change
#
# Provider selection is ENV-driven (TILLANDSIAS_OAUTH_PROVIDER) so the
# generic session wrapper (codex-oauth-session, which invokes the helper as
# "$VAULT_HELPER <command>") can reuse this helper without argv changes.
#
# Usage: TILLANDSIAS_OAUTH_PROVIDER={claude|antigravity} \
#        provider-oauth-vault {restore|harvest|digest|watch CHILD_PID [DIGEST]}
set -euo pipefail

PROVIDER="${TILLANDSIAS_OAUTH_PROVIDER:-}"

case "$PROVIDER" in
    claude)
        AUTH_FILE="${TILLANDSIAS_CLAUDE_AUTH_FILE:-$HOME/.claude/.credentials.json}"
        VAULT_PATH="secret/claude/oauth"
        LOGIN_HINT="tillandsias --claude-login"
        ;;
    antigravity)
        AUTH_FILE="${TILLANDSIAS_AGY_AUTH_FILE:-$HOME/.gemini/antigravity-cli/antigravity-oauth-token}"
        VAULT_PATH="secret/antigravity/oauth"
        LOGIN_HINT="tillandsias --agy-login"
        ;;
    *) echo "Usage: TILLANDSIAS_OAUTH_PROVIDER={claude|antigravity} {restore|harvest|digest|watch CHILD_PID [DIGEST]}" >&2; exit 64 ;;
esac

restore_auth() {
    local auth_dir tmp
    auth_dir="$(dirname "$AUTH_FILE")"
    mkdir -p "$auth_dir"
    chmod 700 "$auth_dir"
    umask 077
    tmp="$(mktemp "$auth_dir/.auth.XXXXXX")"
    trap 'rm -f "$tmp"' RETURN

    if ! vault-cli.sh read -field=credentials_b64 "$VAULT_PATH" | base64 -d >"$tmp"; then
        echo "ERROR: $PROVIDER credentials are unavailable or invalid; run '$LOGIN_HINT' in a terminal." >&2
        return 2
    fi
    if [[ ! -s "$tmp" ]]; then
        echo "ERROR: Vault returned an empty $PROVIDER credential document; rerun '$LOGIN_HINT'." >&2
        return 3
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$AUTH_FILE"
    trap - RETURN

    # Antigravity upstream issue #479: the file store can be write-only for
    # fresh processes in headless containers; the sanctioned headless channel
    # is the ANTIGRAVITY_TOKEN env var. Emit an export line the entrypoint
    # can eval so BOTH channels are populated.
    if [[ "$PROVIDER" == antigravity ]]; then
        printf 'export ANTIGRAVITY_TOKEN=%q\n' "$(cat "$AUTH_FILE")" >"${TILLANDSIAS_AGY_TOKEN_ENV_FILE:-/tmp/agy-token.env}"
        chmod 600 "${TILLANDSIAS_AGY_TOKEN_ENV_FILE:-/tmp/agy-token.env}"
    fi
}

harvest_auth() {
    [[ -s "$AUTH_FILE" ]] || return 0
    base64 -w0 <"$AUTH_FILE" | \
        vault-cli.sh write-stdin "$VAULT_PATH" credentials_b64 >/dev/null
}

auth_digest() {
    if [[ -s "$AUTH_FILE" ]]; then
        sha256sum "$AUTH_FILE" | awk '{print $1}'
    else
        printf 'missing'
    fi
}

watch_auth() {
    local child_pid="$1" initial_digest="${2:-}" poll_secs last current
    poll_secs="${TILLANDSIAS_OAUTH_POLL_SECS:-2}"
    last="${initial_digest:-$(auth_digest)}"
    while kill -0 "$child_pid" 2>/dev/null; do
        sleep "$poll_secs"
        current="$(auth_digest)"
        if [[ "$current" != "$last" && "$current" != missing ]]; then
            harvest_auth
            last="$current"
        fi
    done
}

case "${1:-}" in
    restore) restore_auth ;;
    harvest) harvest_auth ;;
    digest) auth_digest ;;
    watch)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "Usage: provider-oauth-vault watch CHILD_PID" >&2; exit 64; }
        watch_auth "$2" "${3:-}"
        ;;
    *) echo "Usage: provider-oauth-vault {restore|harvest|digest|watch CHILD_PID [INITIAL_DIGEST]}" >&2; exit 64 ;;
esac
