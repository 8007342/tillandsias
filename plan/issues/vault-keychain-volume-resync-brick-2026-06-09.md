# Vault keychain↔volume re-sync brick — 2026-06-09

trace: crates/tillandsias-headless/src/vault_bootstrap.rs (read_and_handover_root_token,
       ensure_unseal_key), images/vault/entrypoint.sh, plan/steps/32-vault-hardening-true-rekey.md

- **Host / branch**: linux (`linux-next`)
- **Severity**: high — unrecoverable Vault brick blocking `--github-login` / `--init`.
- **Reported**: operator, fresh install + `--init` + `--github-login`, 2026-06-09 ~02:10Z.

## Symptom

Every boot looped on `health probe error: ... connection error / Connection refused`. The
container came up, answered one health probe (`initialized=true sealed=true`), then died. The
entrypoint's unseal POST returned **HTTP 400 `error decrypting using seal shamir: cipher:
message authentication failed`** and `curl -f` aborted under `set -euo pipefail`, killing vault.

## Root cause (verified on the operator host with the real binary)

The keychain `vault-shamir-share-v1` did not match the data volume — the share could not unseal
it. `read_and_handover_root_token` captured the freshly-generated Shamir share **only when the
keychain had no root token**: it returned early on any existing `vault-root-token-v1`. So if the
data volume was re-initialized (Silverblue userns drift, `podman volume rm`, a reset) while stale
keychain entries survived, the **new** volume's share was never captured — the keychain stayed
pinned to the **old** share and every later boot failed to unseal the new volume. Permanent brick.

The step-32 isolated e2e missed this because it exercised the **entrypoint** with a hand-fed
matching share, bypassing the Rust `ensure_unseal_key` → keychain → `create_unseal_secret` path.

## Fix (commit 738059bc)

Capture **handover-first**: the container tmpfs handover (`/run/vault-handover/`) is written ONLY
on a fresh `operator init`, so whenever those artifacts are present, capture the root token +
Shamir share and **OVERWRITE** the keychain (re-pairing it with the live volume) before falling
back to the keychain on subsequent boots. Also: delete the handover *files* (not the root-owned
tmpfs mount dir) to drop the cosmetic `rm: ... Permission denied`; and return a clear remediation
error on the inconsistent state (initialized volume + no handover + no keychain token).

Reproduced the brick (delete volume, keep stale keychain share): old path bricked; new path
self-heals — fresh init overwrites the keychain, and the subsequent-boot recreate unseals
(sealed=false, no 400).

## Operator recovery (already applied on the reporting host)

```bash
podman rm -f tillandsias-vault
podman volume rm tillandsias-vault-data
podman secret rm tillandsias-vault-unseal
secret-tool clear service tillandsias username vault-shamir-share-v1
secret-tool clear service tillandsias username vault-root-token-v1
tillandsias --init   # fresh first boot re-pairs keychain↔volume
```

## Cross-host impact (step 36)

macOS/Windows keychain/vsock parity (step 36) MUST mirror the capture-on-every-fresh-init
contract (capture the Vault-generated share → platform keychain, overwriting stale entries), not
gate capture on a stale root-token presence.
