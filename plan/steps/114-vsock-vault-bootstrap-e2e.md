# Step 114 — vsock Vault Bootstrap + GitHub Login End-to-End

**Status**: in_progress  
**Branch**: windows-next  
**Order**: 114  
**Depends on**: 113 (vault-credential-host-exposure)

## Goal

The vsock listener (`--listen-vsock` mode, runs inside the Fedora WSL2 VM) must
automatically bootstrap Vault when the Windows tray delivers credentials. Once Vault
is running, `CloudRefreshRequest` and `GithubLoginStatusRequest` over vsock return
real data.

## Root Causes Found

### 1. Vault never starts in vsock mode

`run_headless_async` (the `--listen-vsock` path) never calls `ensure_vault_running`.
The `DeliverCredentials` vsock handler stored credentials but didn't trigger Vault.

**Fix** (`vsock_server.rs`): Added `VAULT_BOOTSTRAP_DONE: AtomicBool` guard and a
`spawn_blocking` call to `ensure_vault_running(false)` in the `DeliverCredentials` handler.

### 2. vault_api_base_url uses port-forwarded path that hangs on TLS

`127.0.0.1:8201` accepts TCP (conmon listens there) but the TLS handshake hangs
indefinitely. The correct path on Linux is `https://vault:8200` via aardvark-dns
(the enclave bridge gateway resolves `vault` to the container's bridge IP; the TLS
cert has `DNS:vault` as a SAN).

**Fix** (`vault_bootstrap.rs`): `vault_api_base_url()` on `target_os = "linux"` returns
`vault_service_base_url()` (`https://vault:8200`) unless overridden by env var.

### 3. Shamir share detection wipes vault on every run in WSL2

`has_shamir_share_in_keyring()` only checked the OS keyring. In WSL2 there is no D-Bus
session so this always returned `false`, making `is_partial_init = true` and causing
vault data to be wiped and re-initialized on every `ensure_vault_running` call.

`keychain_set_blocking()` already writes a file fallback at
`~/.cache/tillandsias/fallback_vault-shamir-share-v1` when the keyring is unavailable.

**Fix** (`vault_bootstrap.rs`): `has_shamir_share_in_keyring()` checks the file
fallback after the keychain attempt fails.

### 4. CloudRefreshRequest has no vault path for GitHub token

`fetch_cloud_projects()` in vsock_server.rs read from `/run/secrets/tillandsias-github-token`
which is only mounted inside containers. The vsock listener runs outside any container.

**Fix** (`vsock_server.rs`): `fetch_cloud_projects()` falls back to
`vault_kv_get_via_exec("secret/github/token", "token", false)` when the file is absent.

## Files Changed

- `crates/tillandsias-headless/src/vsock_server.rs`
- `crates/tillandsias-headless/src/vault_bootstrap.rs`

## Remaining Work

1. **CI build**: Push `windows-next` to origin so GitHub Actions builds new Linux musl binary.
2. **VM deploy**: Run `fetch-headless.sh` (or equivalent) in the Fedora WSL2 VM to update
   `/usr/local/bin/tillandsias-headless` to the new binary.
3. **GitHub login**: Run `--github-login` in the VM (with a TTY) to write the GitHub token
   to Vault at `secret/github/token`. The binary must have git identity configured
   (`/etc/gitconfig` or `~/.gitconfig` with `user.name` / `user.email`).
4. **E2E test**: Start Windows tray → vsock `DeliverCredentials` → vault bootstraps →
   `GithubLoginStatusRequest` (should return `logged_in: true`) →
   `CloudRefreshRequest` (should return real project list).
5. **`/etc/hosts` vault entry**: If aardvark-dns has timing issues after vault restart,
   adding `<bridge-ip> vault` to `/etc/hosts` in the VM makes resolution stable.
   Check with: `getent hosts vault`

## Probe Commands (run in VM as root)

```bash
# Check vault is running and unsealed
wsl -d tillandsias -u root -- bash -c '/usr/local/bin/tillandsias-headless --list-cloud-projects 2>&1 | head -20'

# Verify vault:8200 is reachable
wsl -d tillandsias -u root -- bash -c 'curl -sk https://vault:8200/v1/sys/health | python3 -m json.tool'

# Check shamir share file exists (no-wipe guard)
wsl -d tillandsias -u root -- bash -c 'ls -la ~/.cache/tillandsias/fallback_vault*'

# Check GitHub token in vault
wsl -d tillandsias -u root -- bash -c 'podman exec tillandsias-vault vault kv get -field=token secret/github/token | wc -c'
```

## Branch Notes

- **windows-next**: owns this change. Phases 3c/3d (SELinux) and Phase 2b (LIVE_CLIENT)
  already committed to windows-next at dbafa9c0 and 795e1fa1.
- **CI**: Linux musl build runs on linux-next merge path; windows-next feeds that via PR.
