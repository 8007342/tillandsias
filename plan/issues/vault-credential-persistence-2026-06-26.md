# Vault Credential Persistence Across Container Rebuilds

**Status:** `pending`
**Owner:** linux
**Date:** 2026-06-26
**Trace:** `spec:tillandsias-vault`, `spec:podman-secrets-integration`

## Problem Statement

The operator currently has to re-authenticate (GitHub login + Vault unseal)
on every Tillandsias launch, even when credentials were already entered in a
prior session. This is wrong. The correct design is:

1. **Vault data volume** persists the encrypted secret store across container
   recreations. As long as the volume exists, secrets survive full image
   rebuilds.
2. **Unseal key** is stored in the host keyring (e.g. `secret-tool` /
   `libsecret` on Linux, `Keychain` on macOS) at first unseal. On subsequent
   launches, the tray reads the key from the keyring and unseals automatically.
3. **GitHub login state** — once a token is present in Vault, the tray should
   not show a "GitHub Login" prompt. The menu item should show status or be
   suppressed.

Additionally, there appears to be a race condition at launch: Vault unseal and
the GitHub login readiness check run concurrently, so the login menu sometimes
prompts before Vault has finished unsealing and the token is accessible.

## Research Questions

### Vault data volume

1. Is the Vault data directory mounted from a named Podman volume or from a
   bind-mount? Check `build_vault_run_args` in `main.rs`.
2. Is the volume named consistently (`tillandsias-vault-data` or similar), so
   it survives `podman rm` of the vault container?
3. Does a `tillandsias --init` or `tillandsias --reset` unconditionally wipe
   the volume, or only on explicit destructive reset?

### Unseal key in host keyring

4. Where is the unseal key currently stored between sessions? Is it stored at
   all, or is the user prompted every time?
5. Is there a call to `secret-tool store` (Linux) / `security add-generic-password`
   (macOS) / `cmdkey` (Windows) after the initial unseal?
6. At launch, does the tray attempt `secret-tool lookup` before prompting for
   unseal?

### GitHub login race

7. What is the sequence of events at launch for the GitHub login check? Is it:
   a) check Vault for existing token → if present, skip login prompt
   b) prompt for login, then store token in Vault
   OR is the Vault check happening before Vault is unsealed?
8. Is there a `wait_for_vault_ready()` guard before the token check, or does
   the login check race the unseal?

## Files to investigate

- `crates/tillandsias-headless/src/main.rs` — `build_vault_run_args`,
  vault lifecycle, unseal sequence
- `crates/tillandsias-core/` — tray state machine, login state transitions
- `images/vault/` — Vault container entrypoint, initialization scripts
- Vault policy files — what the git-mirror and forge AppRole tokens can access

## Expected Implementation

### Data volume persistence

```rust
// build_vault_run_args must include a named volume, not a tmpfs:
"--volume=tillandsias-vault-data:/vault/data:Z"
// Never wipe this volume on normal restart. Only on explicit --reset --wipe-secrets.
```

### Unseal key in host keyring (Linux)

```bash
# At first unseal (init path):
secret-tool store --label="Tillandsias Vault Unseal Key" \
    application tillandsias key vault-unseal-key <<< "$UNSEAL_KEY"

# At subsequent launches:
UNSEAL_KEY=$(secret-tool lookup application tillandsias key vault-unseal-key 2>/dev/null)
if [ -n "$UNSEAL_KEY" ]; then
    vault operator unseal "$UNSEAL_KEY"
fi
```

### GitHub login guard

The tray should call `check_github_token_in_vault()` after the Vault ready
signal, not concurrently. If a valid token is found, suppress the login prompt
and show "Authenticated as <user>" in the menu.

## Exit Criteria

- `tillandsias . --opencode` after a full `podman rm` of the Vault container
  (not the volume) unseals Vault automatically using the keyring and does not
  prompt the operator.
- `tillandsias . --opencode` with a valid GitHub token in Vault does not show
  a GitHub login prompt.
- `tillandsias --reset` without `--wipe-secrets` preserves the vault data
  volume and the keyring entry.
- `tillandsias --reset --wipe-secrets` (or equivalent destructive flag) clears
  both the volume and the keyring entry.
- Findings, Vault volume name, and keyring call sites documented in this file
  under `## Verdict`.

## Verdict

*(pending)*
