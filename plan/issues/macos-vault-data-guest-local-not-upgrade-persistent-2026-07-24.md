# macOS forge vault-data is guest-local (rootfs) — Vault not persistent across reprovision/upgrade

- **Date:** 2026-07-24
- **Class:** bug (credential lifecycle) — the "between version upgrades" half of Vault persistence
- **Area:** macOS VZ Vault storage persistence
- **Severity:** P2 — normal restarts DO persist the Vault; a reprovision-based upgrade wipes it → operator must re-login. Matches the operator's "re-login on every re-run" report (the re-runs were reprovisions).
- **Owner:** builder / out-of-forge (per methodology/next-forge-better.yaml — the substrate can't be fixed from inside a running forge).

## Verified mechanism (persistence works for normal restarts)

- The real unseal key is a **Shamir share stored in the macOS Keychain** (`vault_bootstrap.rs:1445-1536`, `KEYCHAIN_SERVICE="tillandsias"`, `VAULT_SHAMIR_SHARE_V1`) — persistent across restarts and upgrades. The `/etc/machine-id` HKDF is only a first-boot DUMMY before that share exists (`:1489-1498`).
- The encrypted vault-data (file storage backend) lives at **`/root/.cache/tillandsias/vault-data` INSIDE THE GUEST ROOTFS** (confirmed live: the dir persists an image rmi, owned uid 100).
- **Normal restart:** guest rootfs (vault-data) + Keychain share both persist → Vault unseals → no re-login. Correct.

## The gap

- `--reset-guest` (`action_host.rs:1776-1779` `wipe_provisioned_artifacts` deletes rootfs.img "and with it the in-VM vault") — and any **version upgrade that reprovisions** — wipes the guest rootfs → wipes `vault-data`. The Vault re-inits EMPTY on next boot; the persisted Keychain share no longer matches the fresh store → the operator must re-login.
- So the Vault survives restarts but **NOT reprovision-based upgrades**, which contradicts the "preserve the encrypted vault between version upgrades" intent.

## Fix (builder, out-of-forge)

Make `vault-data` **host-persistent** — outside `rootfs.img`, on a path/volume the reprovision does NOT wipe (a macOS-host directory bind-mounted via virtiofs into the guest's Vault container, mirroring how Windows/Linux keep vault-data host-side). Then a reprovision/upgrade keeps both the Keychain share AND the encrypted store → the Vault unseals across upgrades with no re-login. Ensure `wipe_provisioned_artifacts` explicitly preserves it and the Vault container mounts the host path.

## Cross-references

- `plan/issues/vault-unseal-secret-regenerated-on-reensure-2026-07-17.md` — the prior related unseal regen fix.
- `methodology/next-forge-better.yaml` — this is an out-of-forge substrate builder-fix.
- `crates/tillandsias-headless/src/vault_bootstrap.rs:1445-1536` (unseal key), `main.rs:6194` (`cache_dir/vault-data`).
