# Vault Credential Persistence Across Container Rebuilds

**Status:** `completed`
**Owner:** linux
**Date:** 2026-06-26
**Completed:** 2026-06-27T02:20Z
**Trace:** `spec:tillandsias-vault`, `spec:podman-secrets-integration`

## Problem Statement

The operator had to re-authenticate (GitHub login) on every Tillandsias launch,
even when credentials were entered in a prior session. Three related issues:

1. Vault's encrypted secret store was wiped on every non-running container launch.
2. This caused `is_github_logged_in` to always return false after a restart.
3. The tray showed the "GitHub Login" prompt even with credentials stored.

## Root Cause

**`launch_vault_container` unconditionally wiped the data volume** on every
launch where the Vault container was not already running:

```rust
// line 1105 (before fix) — WRONG:
let _ = podman_cmd_sync()
    .args(["volume", "rm", "-f", VAULT_VOLUME])
    ...
```

The intent was to handle the *partial-init* scenario: if `tillandsias --init`
started Vault's `operator init` but the process crashed before the host captured
the handover files, the data volume would hold a Vault initialized with an
unknown unseal key. Wiping and re-initializing is the correct recovery for that
case.

**But the wipe was unconditional.** On every subsequent launch (e.g., after a
reboot), the Vault container was not running, so `launch_vault_container` was
called, which wiped the volume, destroying the stored GitHub token and all other
secrets.

## Architecture (existing, correct design)

The existing code already had all the pieces for correct persistence — they were
just not being used to guard the volume wipe:

- `VAULT_VOLUME = "tillandsias-vault-data"` — named Podman volume (survives
  `podman rm` of the container).
- `VAULT_SHAMIR_SHARE_V1` — keyring entry (`keyring::Entry`) storing the
  base64-encoded Shamir unseal share after a successful first-boot handover.
- `INSTALL_ANCHOR_V1` — keyring entry for the installation UUID.
- The Vault entrypoint (`images/vault/entrypoint.sh`) detects `INITIALIZED=true`
  on subsequent boots and uses the Shamir share from the Podman secret
  (`/run/secrets/tillandsias-vault-unseal`) to auto-unseal without prompting.

## Fix Applied

Added `has_shamir_share_in_keyring()` helper in
`crates/tillandsias-headless/src/vault_bootstrap.rs`:

```rust
#[cfg(feature = "vault")]
fn has_shamir_share_in_keyring() -> bool {
    use base64::Engine;
    let Ok(entry) = Entry::new(KEYCHAIN_SERVICE, VAULT_SHAMIR_SHARE_V1) else {
        return false;
    };
    let Ok(encoded) = with_keyring_timeout(move || entry.get_password()) else {
        return false;
    };
    !encoded.is_empty()
        && base64::engine::general_purpose::STANDARD
            .decode(&encoded)
            .map(|v| v.len() == 32)
            .unwrap_or(false)
}
```

Changed the volume wipe in `launch_vault_container` to be conditional:

```rust
let is_partial_init = vault_data_volume_exists() && !has_shamir_share_in_keyring();
if is_partial_init {
    // wipe — partial-init scenario only
}
```

## Subsequent-Boot Flow (after fix)

1. Vault container not running (e.g., after reboot)
2. `ensure_vault_running` → `launch_vault_container`
3. `vault_data_volume_exists()` → true; `has_shamir_share_in_keyring()` → true
4. Volume **not wiped** — existing secrets preserved
5. `ensure_unseal_key` reads Shamir share from keyring
6. `create_unseal_secret` pushes it as Podman secret `tillandsias-vault-unseal`
7. Vault container starts, reads secret, auto-unseals (already initialized)
8. `wait_for_vault_ready` → success
9. `read_and_handover_root_token` → reads root token from keyring
10. `is_github_logged_in` → reads `secret/github/token` → non-empty → `true`
11. Tray: `is_authenticated = true` → "GitHub Login" menu item hidden

## GitHub Login Race

The tray already handles this correctly via the async probe (`spawn_task` in
`tray/mod.rs`): defaults to `is_authenticated = false` at startup, runs
`is_github_logged_in` in the background. The "login persists" symptom was
entirely caused by the volume wipe making the probe return false — fixing
the wipe fixes the menu.

## Verification

- `cargo check -p tillandsias-headless` — PASS
- `cargo test -p tillandsias-headless vault` — PASS (1/1)
- `./build.sh --check` — PASS (Clippy clean)

## Files Changed

- `crates/tillandsias-headless/src/vault_bootstrap.rs` —
  `has_shamir_share_in_keyring()` helper + conditional volume wipe guard in
  `launch_vault_container`
