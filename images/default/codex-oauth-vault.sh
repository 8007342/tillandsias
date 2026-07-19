#!/usr/bin/env bash
# @trace spec:tillandsias-vault
set -euo pipefail

# CODEX_HOME-aware (order 428): when a worker is given its own CODEX_HOME for
# concurrency isolation, the vault restore MUST write where codex actually
# reads. Hardcoding $HOME/.codex here would silently place the credential in a
# directory codex never consults — the same class of defect as order 430.
AUTH_FILE="${TILLANDSIAS_CODEX_AUTH_FILE:-${CODEX_HOME:-$HOME/.codex}/auth.json}"

restore_auth() {
    local auth_dir tmp
    auth_dir="$(dirname "$AUTH_FILE")"
    mkdir -p "$auth_dir"
    chmod 700 "$auth_dir"
    umask 077
    tmp="$(mktemp "$auth_dir/.auth.json.XXXXXX")"
    trap 'rm -f "$tmp"' RETURN

    if ! vault-cli.sh read -field=credentials_b64 secret/codex/oauth | base64 -d >"$tmp"; then
        echo "ERROR: Codex credentials are unavailable or invalid; run 'tillandsias --codex-login' in a terminal." >&2
        return 2
    fi
    if [[ ! -s "$tmp" ]] || ! jq -e 'type == "object"' "$tmp" >/dev/null; then
        echo "ERROR: Vault returned an invalid Codex credential document; rerun 'tillandsias --codex-login'." >&2
        return 3
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$AUTH_FILE"
    trap - RETURN
}

harvest_auth() {
    if [[ ! -s "$AUTH_FILE" ]] || ! jq -e 'type == "object"' "$AUTH_FILE" >/dev/null; then
        return 0
    fi
    base64 -w0 <"$AUTH_FILE" | \
        vault-cli.sh write-stdin secret/codex/oauth credentials_b64 >/dev/null
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
        [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "Usage: codex-oauth-vault watch CHILD_PID" >&2; exit 64; }
        watch_auth "$2" "${3:-}"
        ;;
    *) echo "Usage: codex-oauth-vault {restore|harvest|digest|watch CHILD_PID [INITIAL_DIGEST]}" >&2; exit 64 ;;
esac
