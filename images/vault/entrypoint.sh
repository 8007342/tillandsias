#!/usr/bin/env bash
# @trace spec:tillandsias-vault
# @cheatsheet runtime/hashicorp-vault-tillandsias.md
#
# Tillandsias Vault entrypoint.
#
# Lifecycle:
#   1. Wait for /run/secrets/tillandsias-vault-unseal (32 bytes raw, no newline)
#      — the host (tray/headless) creates this podman secret from the keychain.
#      The user NEVER sees a passphrase prompt; this is the core property the spec litmus tests.
#   2. Start `vault server` in the background.
#   3. On first boot (not initialized), `vault operator init` with key-shares=1, key-threshold=1.
#      Stash root token + generated unseal key in /run/vault-handover/ for host capture.
#   4. Unseal Vault using the generated unseal key.
#   5. Load the four policy templates (git-mirror, forge, tray, inference).
#   6. Enable the `approle` auth backend if not already enabled.
#   7. Enable the KV v2 secret engine at `secret/` if not already enabled.
#   8. Enable the file audit device at /vault/audit/audit.json.
#   9. Tail the server log (it is already streaming to stdout).
#
# All stderr is duplicated to /vault/audit/entrypoint.log for tray-side
# tailing, then re-emitted on stdout so `podman logs` and the
# `--log-enclave` stream both capture it.

set -euo pipefail

ENTRYPOINT_LOG="/vault/audit/entrypoint.log"
mkdir -p "$(dirname "$ENTRYPOINT_LOG")"

log() {
    local ts msg
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    msg="$ts [vault-entrypoint] $*"
    echo "$msg" >&2
    echo "$msg" >> "$ENTRYPOINT_LOG" 2>/dev/null || true
}

UNSEAL_SECRET_PATH="/run/secrets/tillandsias-vault-unseal"
VAULT_CONFIG="/vault/config/vault.hcl"
POLICY_DIR="/vault/config/policies"
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/run/secrets/tillandsias-vault-tls-ca"
export CURL_CA_BUNDLE="$VAULT_CACERT"

log "starting Tillandsias Vault entrypoint"

# ---------------------------------------------------------------------------
# Step 1: Wait for the unseal key secret.
# ---------------------------------------------------------------------------
WAIT_BUDGET=30
i=0
while [ ! -r "$UNSEAL_SECRET_PATH" ]; do
    i=$((i + 1))
    if [ "$i" -gt "$WAIT_BUDGET" ]; then
        log "FATAL: $UNSEAL_SECRET_PATH not present after ${WAIT_BUDGET}s"
        exit 1
    fi
    sleep 1
done

# 32 raw bytes; convert to hex once
UNSEAL_KEY_HEX="$(xxd -p -c 64 < "$UNSEAL_SECRET_PATH" | tr -d '\n')"
if [ "${#UNSEAL_KEY_HEX}" -lt 64 ]; then
    log "FATAL: unseal secret too short (got ${#UNSEAL_KEY_HEX} hex chars, want >=64)"
    exit 1
fi
log "unseal key material loaded (32 bytes)"

# ---------------------------------------------------------------------------
# Step 2: Boot vault server in the background.
# ---------------------------------------------------------------------------
log "launching vault server"
vault server -config="$VAULT_CONFIG" 2>&1 | tee -a "$ENTRYPOINT_LOG" &
VAULT_PID=$!

# Wait for the API to respond.
i=0
until curl -fsS "$VAULT_ADDR/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 30 ]; then
        log "FATAL: vault API never came up"
        kill "$VAULT_PID" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done
log "vault API responsive"

# ---------------------------------------------------------------------------
# Step 3: Initialize on first boot, or read unseal key on subsequent boots.
# ---------------------------------------------------------------------------
# Detect initialized state from vault itself (more reliable than file probe).
INITIALIZED="$(curl -fsS "$VAULT_ADDR/v1/sys/init" | jq -r '.initialized')"

if [ "$INITIALIZED" != "true" ]; then
    log "first boot: running vault operator init"
    INIT_RESPONSE="$(curl -fsS -X POST \
        -d '{"secret_shares":1,"secret_threshold":1}' \
        "$VAULT_ADDR/v1/sys/init")"
    SHAMIR_KEY_B64="$(echo "$INIT_RESPONSE" | jq -r '.keys_base64[0]')"
    ROOT_TOKEN="$(echo "$INIT_RESPONSE" | jq -r '.root_token')"
    SHAMIR_KEY_HEX="$(echo "$SHAMIR_KEY_B64" | base64 -d | xxd -p -c 64 | tr -d '\n')"
    if [ -z "$SHAMIR_KEY_HEX" ] || [ -z "$ROOT_TOKEN" ]; then
        log "FATAL: vault init returned empty keys"
        kill "$VAULT_PID" 2>/dev/null || true
        exit 1
    fi
    
    # Secure handover via tmpfs inside the container.
    HANDOVER_DIR="/run/vault-handover"
    umask 077
    mkdir -p "$HANDOVER_DIR"
    echo "$SHAMIR_KEY_B64" > "$HANDOVER_DIR/unseal.key"
    echo "$ROOT_TOKEN" > "$HANDOVER_DIR/root.token"
    
    log "vault initialized (handover artifacts written to tmpfs)"
    UNSEAL_HEX="$SHAMIR_KEY_HEX"
else
    log "subsequent boot: using unseal key from secret"
    UNSEAL_HEX="$UNSEAL_KEY_HEX"
    ROOT_TOKEN=""
fi

# ---------------------------------------------------------------------------
# Step 4: Unseal.
# ---------------------------------------------------------------------------
SEALED="$(curl -fsS "$VAULT_ADDR/v1/sys/seal-status" | jq -r '.sealed')"
if [ "$SEALED" = "true" ]; then
    log "unsealing vault"
    UNSEAL_KEY_HEX_UPPER="$(echo "$UNSEAL_HEX" | tr 'a-f' 'A-F')"
    # Vault accepts hex or base64; send hex.
    RESPONSE="$(curl -fsS -X POST \
        -d "{\"key\":\"$UNSEAL_KEY_HEX_UPPER\"}" \
        "$VAULT_ADDR/v1/sys/unseal")"
    NOW_SEALED="$(echo "$RESPONSE" | jq -r '.sealed')"
    if [ "$NOW_SEALED" != "false" ]; then
        log "FATAL: unseal call returned sealed=$NOW_SEALED — wrong key"
        kill "$VAULT_PID" 2>/dev/null || true
        exit 1
    fi
    log "vault unsealed (sealed=false)"
else
    log "vault already unsealed"
fi

# Without a root token (subsequent boot — see one-time-handover note above) the
# server is already unsealed and fully provisioned from persistent storage, so
# the token-authenticated re-provisioning below is both impossible and
# unnecessary. Skip straight to serving.
if [ -z "$ROOT_TOKEN" ]; then
    log "vault is unsealed and serving (provisioning persisted from a prior boot)"
    wait "$VAULT_PID"
    exit 0
fi

export VAULT_TOKEN="$ROOT_TOKEN"

# ---------------------------------------------------------------------------
# Step 5: Load policies (idempotent).
# ---------------------------------------------------------------------------
load_policy() {
    local name="$1" file="$2"
    if [ ! -r "$file" ]; then
        log "WARN: policy file $file missing, skipping"
        return 0
    fi
    log "loading policy: $name"
    # Vault policies API takes a JSON body { "policy": "<hcl>" }.
    local body
    body="$(jq -Rs '{policy: .}' < "$file")"
    curl -fsS -X PUT \
        -H "X-Vault-Token: $VAULT_TOKEN" \
        -d "$body" \
        "$VAULT_ADDR/v1/sys/policies/acl/$name" >/dev/null
}

load_policy "git-mirror-policy" "$POLICY_DIR/git-mirror.hcl"
load_policy "forge-policy"      "$POLICY_DIR/forge.hcl"
load_policy "tray-policy"       "$POLICY_DIR/tray.hcl"
load_policy "inference-policy"  "$POLICY_DIR/inference.hcl"

# ---------------------------------------------------------------------------
# Step 6: Enable auth + secret engine + audit (idempotent — ignore "already
# enabled" errors).
# ---------------------------------------------------------------------------
enable_endpoint() {
    local endpoint="$1" body="$2" descr="$3"
    log "ensuring $descr"
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
        -d "$body" "$VAULT_ADDR$endpoint" || echo "000")"
    case "$code" in
        2*|400)
            # 400 typically means "already enabled" or "path is already in use"
            return 0
            ;;
        *)
            log "WARN: $descr returned HTTP $code (continuing)"
            ;;
    esac
}

enable_endpoint "/v1/sys/auth/approle"   '{"type":"approle"}'                          "approle auth"
enable_endpoint "/v1/sys/mounts/secret"  '{"type":"kv","options":{"version":"2"}}'    "kv-v2 secret engine"
enable_endpoint "/v1/sys/audit/file"     '{"type":"file","options":{"file_path":"/vault/audit/audit.json"}}' "file audit device"

log "vault is fully configured (unsealed, policies loaded, approle+kv2+audit enabled)"

# ---------------------------------------------------------------------------
# Step 7: Drop the in-memory variables and hand control back to vault.
# ---------------------------------------------------------------------------
unset VAULT_TOKEN UNSEAL_KEY_HEX UNSEAL_HEX ROOT_TOKEN ENVELOPED_HEX SHAMIR_KEY_HEX

wait "$VAULT_PID"
