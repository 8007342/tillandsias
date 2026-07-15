#!/usr/bin/env bash
# @trace spec:tillandsias-vault
set -euo pipefail

AUTH_FILE="${TILLANDSIAS_CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"
CODEX_BIN="${TILLANDSIAS_CODEX_BIN:-}"

if [[ -z "$CODEX_BIN" ]]; then
    # The forge installs harnesses lazily, so a standalone login container must
    # establish the same command before probing provider capabilities.
    # shellcheck source=lib-common.sh
    source /usr/local/lib/tillandsias/lib-common.sh
    ensure_forge_harnesses
    require_codex
    CODEX_BIN="$CX_BIN"
fi

if ! "$CODEX_BIN" login --help 2>&1 | grep -Fq -- '--device-auth'; then
    echo "ERROR: installed Codex does not support 'codex login --device-auth'; refusing browser or paste-token fallback." >&2
    exit 2
fi

"$CODEX_BIN" login --device-auth

if [[ ! -s "$AUTH_FILE" ]]; then
    echo "ERROR: Codex device login completed without creating $AUTH_FILE" >&2
    exit 3
fi

# Preserve the complete opaque document: refresh and identity tokens are part
# of the provider contract, so extracting only access_token would break the
# next launch. The value flows on stdin and never appears in argv or env.
base64 -w0 <"$AUTH_FILE" | \
    vault-cli.sh write-stdin secret/codex/oauth credentials_b64 >/dev/null

vault-cli.sh read -field=credentials_b64 secret/codex/oauth >/dev/null
echo "Codex device credentials stored in Vault."
