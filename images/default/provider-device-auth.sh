#!/usr/bin/env bash
# @trace spec:tillandsias-vault
# provider-device-auth — generic DEVICE-flow login for Claude / Antigravity
# (Codex has its own verified script: codex-device-auth). Runs inside the
# ephemeral login container; the container dies right after the vault write,
# so no credential survives outside Vault. Never falls back to a browser
# launch or a paste-token prompt (operator directive 2026-07-12: clickable
# URLs / pasted tokens spill escape garbage in forge terminals).
#
# Usage: provider-device-auth {claude|antigravity}
set -euo pipefail

PROVIDER="${1:-}"

# shellcheck source=lib-common.sh
source /usr/local/lib/tillandsias/lib-common.sh

case "$PROVIDER" in
    claude)
        AUTH_FILE="${TILLANDSIAS_CLAUDE_AUTH_FILE:-$HOME/.claude/.credentials.json}"
        VAULT_PATH="secret/claude/oauth"
        ensure_forge_harnesses
        require_claude
        BIN="$CC_BIN"
        # Operator-prescribed command (2026-07-15): claude auth login --claudeai
        # Probe the capability first; refuse any fallback (no browser, no paste).
        if ! "$BIN" auth login --help 2>&1 | grep -Fq -- '--claudeai'; then
            echo "ERROR: installed Claude CLI does not support 'claude auth login --claudeai';" >&2
            echo "refusing browser or paste-token fallback. 'claude auth login --help' says:" >&2
            "$BIN" auth login --help >&2 || true
            exit 2
        fi
        "$BIN" auth login --claudeai
        ;;
    antigravity)
        # agy auto-detects headless sessions and prints a device URL + code
        # (no browser). Linux-container credential file per upstream:
        # ~/.gemini/antigravity-cli/antigravity-oauth-token. Upstream issue
        # #479: the FILE store is effectively write-only for fresh processes
        # in headless containers — the forge injection therefore prefers the
        # ANTIGRAVITY_TOKEN env channel (see provider-oauth-vault restore).
        AUTH_FILE="${TILLANDSIAS_AGY_AUTH_FILE:-$HOME/.gemini/antigravity-cli/antigravity-oauth-token}"
        VAULT_PATH="secret/antigravity/oauth"
        if ! command -v agy >/dev/null 2>&1; then
            echo "ERROR: agy is not installed in the login container (install runs at forge launch)." >&2
            exit 2
        fi
        BIN="$(command -v agy)"
        # Investigation posture (order pending live verify): capture the auth
        # surface before running, so a failed login leaves evidence.
        "$BIN" auth --help >/tmp/agy-auth-help.txt 2>&1 || \
            "$BIN" login --help >/tmp/agy-auth-help.txt 2>&1 || true
        if "$BIN" auth login --help >/dev/null 2>&1; then
            "$BIN" auth login
        elif "$BIN" login --help >/dev/null 2>&1; then
            "$BIN" login
        else
            echo "ERROR: could not find an agy login subcommand. Captured help output:" >&2
            cat /tmp/agy-auth-help.txt >&2 || true
            exit 2
        fi
        ;;
    *)
        echo "Usage: provider-device-auth {claude|antigravity}" >&2
        exit 64
        ;;
esac

if [[ ! -s "$AUTH_FILE" ]]; then
    echo "ERROR: $PROVIDER login completed without creating $AUTH_FILE" >&2
    if [[ "$PROVIDER" == antigravity ]]; then
        echo "Candidate credential locations found under \$HOME:" >&2
        find "$HOME/.gemini" "$HOME/.antigravity" "$HOME/.config/antigravity" \
            -maxdepth 3 -type f -newer /tmp/agy-auth-help.txt 2>/dev/null >&2 || true
        echo "File this output into the agy-login live-verify packet." >&2
    fi
    exit 3
fi

# Preserve the complete opaque credential document (refresh/identity tokens
# are part of the provider contract). Flows on stdin; never argv or env.
base64 -w0 <"$AUTH_FILE" | \
    vault-cli.sh write-stdin "$VAULT_PATH" credentials_b64 >/dev/null

vault-cli.sh read -field=credentials_b64 "$VAULT_PATH" >/dev/null
echo "$PROVIDER device credentials stored in Vault."
