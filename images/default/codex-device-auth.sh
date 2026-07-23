#!/usr/bin/env bash
# @trace spec:tillandsias-vault
set -euo pipefail

# CODEX_HOME-aware (order 428): when a worker is given its own CODEX_HOME for
# concurrency isolation, the vault restore MUST write where codex actually
# reads. Hardcoding $HOME/.codex here would silently place the credential in a
# directory codex never consults — the same class of defect as order 430.
AUTH_FILE="${TILLANDSIAS_CODEX_AUTH_FILE:-${CODEX_HOME:-$HOME/.codex}/auth.json}"
CODEX_BIN="${TILLANDSIAS_CODEX_BIN:-}"
LIB_COMMON="${TILLANDSIAS_LIB_COMMON:-/usr/local/lib/tillandsias/lib-common.sh}"

# The login one-shot needs exactly one provider binary. Running the all-provider
# updater here reinstalled unrelated tools and delayed the device code by about
# 50 seconds. The provider-specific tool-cache volume mounted by
# run_provider_login lets require_codex reuse the npm prefix on later logins.
# shellcheck source=lib-common.sh
source "$LIB_COMMON"
if [[ -z "$CODEX_BIN" ]]; then
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
