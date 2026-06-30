# research: Vault Persistence Across Container Recreation

- class: research
- filed: 2026-06-23
- owner: linux
- status: completed
- closed: 2026-06-23T20:50Z
- closed_by: linux-big-pickle-20260623T2042Z

## Context
Whenever the forge or new environments are launched, the vault container might be recreated. If a previous vault container created an encrypted vault, that vault data should theoretically survive container recreation if it is stored on a persistent volume, as long as the unseal key remains in the host keyring.

## Problem
Previously suspected: losing vault state (like github tokens, and later auth tokens) when the vault container is recreated.

## Findings

### Verdict: Vault persistence is ALREADY correctly implemented end-to-end.

The vault data directory (`/vault/data`) is mounted as a **persistent named podman volume** (`tillandsias-vault-data:/vault/data:U`). Every component of the persistence chain is correctly designed:

### 1. Volume — Persistent Named Podman Volume
- **Mount**: `tillandsias-vault-data:/vault/data:U` in `launch_vault_container()` (`vault_bootstrap.rs:1101`)
- **`:U` flag**: Recursively chowns the volume to the container process's mapped uid/gid on every launch, handling userns mapping drift from OSTree updates or `podman system reset`.
- **No explicit `podman volume create`**: Podman auto-creates the named volume on first `--volume` use during `podman run`. This is standard behavior.
- **`--rm` only removes the container** — the named volume persists.
- **Volume existence check**: `vault_data_volume_exists()` (`vault_bootstrap.rs:524`) probes with `podman volume exists` — used by `is_github_logged_in()` as a cheap gate.

### 2. Unseal Key — Host Keychain + File Fallback
- **First boot**: `vault operator init` (1 share, 1 threshold) → Shamir key written to `/run/vault-handover/` tmpfs → host captures via `GetVaultHandover` → stored in host OS keychain (`vault-unseal-v1` service).
- **Subsequent boots**: `ensure_unseal_key()` (`vault_bootstrap.rs:710`) retrieves from keychain. Falls back to file at `<cache_dir>/fallback_vault-unseal-v1` if keychain unavailable/timed out.
- **VM guest path**: In-VM credentials delivered via control wire (`IN_VM_CREDENTIALS`) — recovered directly from host-delivered `unseal_share_b64`.
- **First-boot dummy key**: HKDF-derived from `machine-id` + installation UUID (anchor). Not used for actual unseal on subsequent boots — the real Shamir share is retrieved from keychain.

### 3. Entrypoint Handles Both Flows Correctly
- **First boot** (not initialized): `operator init` → capture → unseal → provision (policies, AppRole, KVv2, audit).
- **Subsequent boots** (initialized): read podman secret → unseal → skip provisioning (state persisted on volume). Line 150-153: `if [ -z "$ROOT_TOKEN" ]; then ... wait "$VAULT_PID"; exit 0`

### 4. Explicit Documentation Confirms Persistence
- Error message at `vault_bootstrap.rs:1357`: "Reset with `podman volume rm tillandsias-vault-data`"
- Cheatsheet at `cheatsheets/runtime/hashicorp-vault-tillandsias.md:82`: "Persistent volume"
- Spec at `openspec/specs/tillandsias-vault/spec.md:53`: mandates `tillandsias-vault-data:/vault/data`
- Shutdown at `vault_bootstrap.rs:612`: revokes AppRole tokens but "preserves the Vault container on disk"
- Main.rs:6920-6927 explicitly confirms "data lives on the `tillandsias-vault-data` named volume"

## Residual Observations (not actionable at current bar)

1. **No explicit `podman volume create`**: Implicit creation is fine for normal use but means no driver options (backup labels, size limits, encryption) can be set. Could add explicit volume creation in a future enhancement.
2. **Unseal key ↔ volume coupling**: If the host keychain loses the Shamir key but the volume survives (or vice versa), Vault is permanently sealed. Recovery requires `podman volume rm tillandsias-vault-data` and re-init. This is by design — there is no way to recover a sealed Vault without its unseal key.
3. **`podman system reset --force` destroys both**: The e2e smoke test precondition wipes both volume and keychain — expected and correct.

## Goals Closure
- [x] Goal 1: Vault data is mounted as a persistent named podman volume (`tillandsias-vault-data:/vault/data:U`)
- [x] Goal 2: Volume persists correctly across container recreation (explicit `podman rm -f` preceded by volume check, `--rm` on container but NOT on volume)
- [x] Goal 3: Unseal key from host keychain unseals preserved vault (verified by code analysis of entrypoint flow + `ensure_unseal_key()`)
- [x] Goal 4: Persistent volume mounting is already implemented — no changes needed
