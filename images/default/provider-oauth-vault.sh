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
    copilot)
        # 2063-nfag: the credential is an opaque archive of COPILOT_HOME's
        # credential files (copilot picks the file name), restored into RAM
        # (/dev/shm) in the copilot forge only; secret/copilot/oauth is
        # readable by no other lane's policy.
        COPILOT_HOME="${COPILOT_HOME:-/dev/shm/copilot-home}"
        AUTH_FILE=""
        VAULT_PATH="secret/copilot/oauth"
        LOGIN_HINT="tillandsias --copilot-login"
        ;;
    *) echo "Usage: TILLANDSIAS_OAUTH_PROVIDER={claude|antigravity|copilot} {restore|harvest|digest|watch CHILD_PID [DIGEST]}" >&2; exit 64 ;;
esac

# copilot: the archive's member files, minus copilot's volatile state.
copilot_cred_files() {
    find "$COPILOT_HOME" -type f ! -path "$COPILOT_HOME/session-state/*" \
        ! -path "$COPILOT_HOME/logs/*" ! -path "$COPILOT_HOME/pkg/*" 2>/dev/null | LC_ALL=C sort
}

restore_auth() {
    if [[ "$PROVIDER" == copilot ]]; then
        local tmp
        mkdir -p "$COPILOT_HOME" && chmod 700 "$COPILOT_HOME"
        umask 077
        tmp="$(mktemp "$COPILOT_HOME/.restore.XXXXXX")"
        if ! vault-cli.sh read -field=credentials_b64 "$VAULT_PATH" | base64 -d >"$tmp" \
            || [[ ! -s "$tmp" ]] || ! tar -xzf "$tmp" -C "$COPILOT_HOME"; then
            rm -f "$tmp"
            echo "ERROR: copilot credentials are unavailable or invalid; run '$LOGIN_HINT' in a terminal." >&2
            return 2
        fi
        rm -f "$tmp"
        return 0
    fi
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
    if [[ "$PROVIDER" == copilot ]]; then
        [[ -n "$(copilot_cred_files)" ]] || return 0
        tar -C "$COPILOT_HOME" --exclude=./session-state --exclude=./logs --exclude=./pkg \
            --exclude='./.restore.*' -czf - . | base64 -w0 | \
            vault-cli.sh write-stdin "$VAULT_PATH" credentials_b64 >/dev/null
        return
    fi
    [[ -s "$AUTH_FILE" ]] || return 0
    base64 -w0 <"$AUTH_FILE" | \
        vault-cli.sh write-stdin "$VAULT_PATH" credentials_b64 >/dev/null
}

auth_digest() {
    if [[ "$PROVIDER" == copilot ]]; then
        local files
        files="$(copilot_cred_files)"
        if [[ -n "$files" ]]; then
            # shellcheck disable=SC2086
            tr '\n' '\0' <<<"$files" | xargs -0 sha256sum | sha256sum | awk '{print $1}'
        else
            printf 'missing'
        fi
        return
    fi
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
    # 2076-w7kd: the session ended, possibly by SIGKILL: copy a rotation made
    # since the last poll, or it is lost.
    current="$(auth_digest)"
    if [[ "$current" != "$last" && "$current" != missing ]]; then
        harvest_auth
    fi
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
