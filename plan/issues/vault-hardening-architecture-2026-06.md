# Vault Hardening Architecture (Phase 6.5) - 2026-06

**Epic**: Vault Hardening & Legacy Removal
**Specs Affected**: `tillandsias-vault`, `secrets-management` (removed)
**Status**: Planned

## Context
Following the transition of the Vault POC to the default secrets backend on Linux (Phase 6), an audit revealed critical security gaps related to the persistent storage of bootstrap artifacts (`init.json`, `root.token`) and the reliance on a transitional XOR envelope for auto-unseal. Additionally, the fallback to the legacy podman-secret via host keyring is creating technical debt and split-brain scenarios. 

The `tillandsias-vault` spec has been hardened to mandate true native host keychain storage for the unseal key, versioning/sanitization of those keys, true `vault operator rekey` functionality, and the complete removal of the legacy fallback.

## Implementation Plan

### 1. Remove Legacy Keyring Fallback [COMPLETED]
- **Files**: `crates/tillandsias-headless/src/main.rs`, `crates/tillandsias-headless/src/vault_bootstrap.rs`
- **Action**: Completely removed support for `--legacy-keyring-secrets` and `--without-vault`. Vault is now initialized unconditionally on `--init` and used unconditionally on `--github-login`. Removed the `migrate_legacy_github_token` logic and the `create_github_podman_secret` helper.
- **Evidence**: Verified with `cargo check -p tillandsias-headless`. Legacy flags now trigger a fatal error.

### 2. Host OS Keychain Integration & Key Versioning
- **Files**: `crates/tillandsias-headless/src/vault_bootstrap.rs`, `crates/tillandsias-core/Cargo.toml`
- **Action**: Modify the `installation-uuid` logic. Instead of writing a static file to `~/.config/tillandsias/installation-uuid`, the host tray must store the generated anchor or the fully derived unseal key in the host OS's native secure keychain (e.g., using the `keyring` crate).
- **Action**: Implement versioning for the keychain entries (e.g., `tillandsias-vault-unseal-v1`).
- **Action**: Implement a sanitization routine on launch that scans the host keychain and deletes any stale, older-version keys or keys associated with non-existent container instances.

### 3. Implement True Vault Rekey
- **Files**: `images/vault/entrypoint.sh`
- **Action**: Remove the XOR envelope (`xor_hex`) logic.
- **Action**: On first boot initialization, after `vault operator init`, immediately invoke `vault operator rekey` to install the HKDF-derived unseal key (passed via the tmpfs secret) as the active Shamir share.

### 4. Secure Artifact Cleanup
- **Files**: `images/vault/entrypoint.sh`, `crates/tillandsias-headless/src/vault_bootstrap.rs`
- **Action**: Ensure `init.json` is permanently deleted (`rm -f`) immediately after the initialization and rekeying process completes.
- **Action**: Update how the host retrieves the `root.token`. Currently, it's read from the persistent volume. The entrypoint should pass it to the host securely (or the host intercepts it during init), and it must NOT be left at `/vault/data/root.token` permanently.

### 5. Update Litmus Tests
- **Files**: `openspec/litmus-tests/litmus-secrets-management-implementation-shape.yaml`, `openspec/litmus-tests/litmus-gh-auth-script-shape.yaml`
- **Action**: Remove tests that assert the presence and functionality of the `--legacy-keyring-secrets` flags and the old `tillandsias-github-token` podman secret flow.
- **Action**: Add new litmus steps in `litmus-vault-auto-unseal-no-prompt.yaml` to verify the absence of `init.json` and the XOR envelope, and verify the host keychain storage interaction.