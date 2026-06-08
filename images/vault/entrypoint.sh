#!/usr/bin/env bash
# @trace spec:tillandsias-vault
# @cheatsheet runtime/hashicorp-vault-tillandsias.md
#
# Tillandsias Vault entrypoint.
#
# Lifecycle:
#   1. Wait for /run/secrets/tillandsias-vault-unseal (32 bytes raw, no newline)
#      — the host (tray) creates this podman secret from a key derived via
#      HKDF over (machine-id || installation-uuid). The user NEVER sees a
#      passphrase prompt; this is the core property the spec litmus tests.
#   2. Start `vault server` in the background.
#   3. On first boot (no /vault/data/init.json), `vault operator init` with
#      key-shares=1, key-threshold=1. Stash root token + generated unseal
#      key in /vault/data/init.json (mode 0400, owner vault).
#   4. Unseal Vault using the generated unseal key from init.json.
#   5. Load the four policy templates (git-mirror, forge, tray, inference).
#   6. Enable the `approle` auth backend if not already enabled.
#   7. Enable the KV v2 secret engine at `secret/` if not already enabled.
#   8. Enable the file audit device at /vault/audit/audit.json.
#   9. Tail the server log (it is already streaming to stdout).
#
# IMPORTANT — PRODUCTION CAVEAT:
#   This POC uses the GENERATED Shamir unseal key (from `vault operator
#   init`) rather than the HKDF-derived key from
#   /run/secrets/tillandsias-vault-unseal directly. The HKDF key currently
#   acts as an ENVELOPE: the entrypoint XORs the init.json contents with
#   HKDF(machine-id || installation-uuid) so the at-rest copy is bound to
#   the host/VM identity, and the unseal key never lands on disk in
#   plaintext. Production must replace this with `vault operator rekey`
#   to install the derived key as the active share so loss of /vault/data
#   doesn't lock the user out indefinitely. See `RESEARCH ITEM` notes in
#   openspec/specs/tillandsias-vault/spec.md.
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
INIT_JSON="/vault/data/init.json"
INIT_ENVELOPE="/vault/data/init.envelope"
VAULT_CONFIG="/vault/config/vault.hcl"
POLICY_DIR="/vault/config/policies"
export VAULT_ADDR="http://127.0.0.1:8200"

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

# 32 raw bytes; convert to hex once for the XOR envelope.
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
# Step 3: Initialize on first boot, or recover from envelope on later boots.
# ---------------------------------------------------------------------------
xor_hex() {
    # XOR two equal-length hex strings, output hex.
    # Pure bash + printf; no python dependency in the vault image.
    local a="$1" b="$2"
    local len_a=${#a} len_b=${#b}
    local n=$len_a
    if [ "$len_b" -lt "$n" ]; then n=$len_b; fi
    # Process two hex chars (1 byte) at a time.
    local i=0 out=""
    while [ "$i" -lt "$n" ]; do
        local byte_a="0x${a:$i:2}"
        local byte_b="0x${b:$i:2}"
        local xored=$(( byte_a ^ byte_b ))
        out+=$(printf '%02x' "$xored")
        i=$((i + 2))
    done
    printf '%s' "$out"
}

# Detect initialized state from vault itself (more reliable than file probe).
INITIALIZED="$(curl -fsS "$VAULT_ADDR/v1/sys/init" | jq -r '.initialized')"

if [ "$INITIALIZED" != "true" ]; then
    log "first boot: running vault operator init"
    # With the default Shamir seal, only secret_shares/secret_threshold
    # are valid. recovery_* are reserved for auto-unseal seals (transit,
    # awskms, etc.) which would create a chicken-and-egg here.
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
    # Stash plaintext init.json (mode 0400). The host-bound HKDF key
    # envelopes the shamir key on disk so a stolen volume alone cannot
    # unseal; see PRODUCTION CAVEAT in the header.
    umask 077
    echo "$INIT_RESPONSE" > "$INIT_JSON"
    ENVELOPED_HEX="$(xor_hex "$SHAMIR_KEY_HEX" "$UNSEAL_KEY_HEX")"
    echo "$ENVELOPED_HEX" > "$INIT_ENVELOPE"
    echo "$ROOT_TOKEN" > /vault/data/root.token
    chmod 0400 "$INIT_ENVELOPE" /vault/data/root.token
    # @trace spec:tillandsias-vault — Secure Artifact Cleanup
    # Plaintext init.json MUST NOT survive first boot initialization.
    rm -f "$INIT_JSON"
    log "vault initialized (envelope persisted, init.json deleted, root token stashed for handover)"
    UNSEAL_HEX="$SHAMIR_KEY_HEX"
else
    log "subsequent boot: recovering shamir key from envelope"
    if [ ! -r "$INIT_ENVELOPE" ]; then
        log "FATAL: vault is initialized but $INIT_ENVELOPE is missing — re-bootstrap required"
        kill "$VAULT_PID" 2>/dev/null || true
        exit 1
    fi
    ENVELOPED_HEX="$(tr -d '\n' < "$INIT_ENVELOPE")"
    UNSEAL_HEX="$(xor_hex "$ENVELOPED_HEX" "$UNSEAL_KEY_HEX")"
    # The root token is a ONE-TIME handover: the host (`wait_for_vault_ready` ->
    # `read_and_handover_root_token`) reads /vault/data/root.token after first
    # boot, stashes it in the host keychain, and deletes the on-disk copy. So on
    # every subsequent boot this file is legitimately absent. Tolerate that
    # instead of dying under `set -e` — vault's policies/auth/kv/audit all live
    # in persistent storage, so a relaunch only needs to UNSEAL, not re-provision.
    if [ -r /vault/data/root.token ]; then
        ROOT_TOKEN="$(cat /vault/data/root.token)"
    else
        ROOT_TOKEN=""
        log "subsequent boot: root token already handed over to host; will unseal only"
    fi
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
        log "FATAL: unseal call returned sealed=$NOW_SEALED — wrong key or corrupt envelope"
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
