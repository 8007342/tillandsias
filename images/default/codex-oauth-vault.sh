#!/usr/bin/env bash
# @trace spec:tillandsias-vault
set -euo pipefail

AUTH_FILE="${TILLANDSIAS_CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"

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

case "${1:-}" in
    restore) restore_auth ;;
    *) echo "Usage: codex-oauth-vault restore" >&2; exit 64 ;;
esac
