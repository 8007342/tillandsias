# Vault Credential Host-Exposure Audit + Remediation

**Status:** `ready`
**Owner:** linux
**Date:** 2026-06-27
**Trace:** `spec:tillandsias-vault`, `spec:forge-as-only-runtime`

## Problem Statement

The headless/tray process should never hold raw credential values (tokens, API
keys). It should only see derived data: booleans ("logged in?"), lists (project
names), container status. Any operation that needs a credential should run inside
a fully-controlled `--rm` container, and only the result crosses the boundary to
the tray — not the credential itself.

Two violations exist today plus one vestigial legacy path:

## Audit Table

| Location | What is read | Current use | Status |
|---|---|---|---|
| `vault_bootstrap.rs:520` `is_github_logged_in` | Full `secret/github/token` via Vault HTTP from HOST | Boolean gate: token present? | **VIOLATION** — reads value to null-check it |
| `main.rs:6722` `build_forge_agent_run_args` | `secret/<provider>/api-key` via Vault HTTP from HOST | Injects as `--env` into forge container at launch | **VIOLATION** — host reads credential to pass into container |
| `tillandsias-core/src/secrets.rs:101` `read_github_token` | Host `gh auth token` (OS keyring, not Vault) | Startup health check / refresh | **LEGACY** — pre-Vault path; should be removed or containerized |
| `remote_projects.rs:329` `fetch_github_projects` | AppRole Vault token (scoped, not the gh token) | Container reads gh token internally via vault-cli | **CORRECT** — credential never surfaces to host |

## What's Already Correct

`fetch_github_projects` already follows the right pattern:
1. Host mints an AppRole lease (a scoped, short-TTL Vault access token, not the GitHub token)
2. Lease is mounted as a podman secret into `tillandsias-git --rm` container
3. Container runs: `vault-cli read -field=token secret/github/token | gh auth login --with-token`
4. Container runs `gh api user/repos` and returns JSON on stdout
5. Host receives the project list — no credential ever surfaces

This is the model everything else should follow.

## Fix 1: `is_github_logged_in` — presence-only check

**Current**: reads full token value from `secret/github/token`, checks if non-empty.

**Fix**: Replace with a Vault metadata/existence check that does not return the token value.
Option A — `podman exec tillandsias-vault vault kv get -field=token secret/github/token 2>/dev/null | wc -c` (non-zero = present)
Option B — Add a `vault_key_exists(path)` helper that uses the Vault `metadata/read` API endpoint and only checks the HTTP status code (200 vs 404).

Option B is cleaner: the KV v2 metadata endpoint is `GET /v1/secret/metadata/github/token` and returns 200 if the key exists, 404 if not. No secret data is transmitted. Implement as `vault_bootstrap::vault_key_exists(path: &str, debug: bool) -> bool` using the existing `VaultClient`.

## Fix 2: Provider API key injection — delegate to AppRole container startup

**Current**: `build_forge_agent_run_args` calls `read_provider_api_key(provider, debug)` from the host Vault HTTP client, then passes the raw key as `--env ANTHROPIC_API_KEY=<key>` to the forge container.

**Fix** (two options — pick one):

**Option A: podman-exec at container startup** — instead of injecting via `--env`, pass a scoped AppRole secret into the forge container (as already done for the git container), and have the forge container's entrypoint read the key internally:
```bash
export ANTHROPIC_API_KEY=$(vault-cli read -field=key secret/anthropic/api-key)
```
Advantage: key never crosses the podman API surface as a plaintext env var. Disadvantage: requires vault-cli in the forge image.

**Option B: `podman exec` approach** — use `PodmanClient::vault_kv_get(secret_path, field)` which runs:
```
podman exec tillandsias-vault vault kv get -field=<field> <secret_path>
```
This replaces the HTTP vault client call on the host with a subprocess into the already-running vault container. The key appears only as a subprocess stdout capture in the host process and is zeroized after injection. This keeps the forge image vault-cli-free.

**Recommended**: Option A (AppRole in forge container), because it eliminates the host from the credential data path entirely. The key is only ever in vault container memory → forge container memory; the host tray process never touches it.

## Fix 3: Remove `check_github_token_health` legacy path

`tillandsias-core/src/secrets.rs::check_and_refresh_github_token` is a pre-Vault path that:
1. Runs `gh auth token` on the host to read from OS keyring
2. Calls GitHub API to check token validity
3. Attempts to refresh via `attempt_token_refresh()`

With the Vault flow, the GitHub token lives at `secret/github/token` in Vault, not in the host `gh` CLI keyring. This health check is checking the wrong store and is vestigial. It should be removed or replaced with a containerized probe that checks `secret/github/token` exists (same as Fix 1 above).

## Fix 4: `PodmanClient::vault_kv_get` idiomatic helper

Add to the `tillandsias-podman` crate:
```rust
impl PodmanClient {
    /// Read a single field from a Vault KV secret by exec-ing into the
    /// running vault container. Returns Err if the container is not running
    /// or the field is absent.
    pub fn vault_kv_get(
        &self,
        secret_path: &str,
        field: &str,
    ) -> Result<String, String>;
}
```
Implementation: `podman exec tillandsias-vault vault kv get -field=<field> <path>` with stdout capture. This makes the `remove-port-publish` blocker moot for key-read operations: the host never needs an HTTP port to Vault to read secrets; it just execs into the already-running vault container.

This also enables the macOS/Windows call chain the user described:
```
macOS tray → vsock → tillandsias headless (Linux/WSL) → PodmanClient::vault_kv_get → podman exec tillandsias-vault vault kv get
```
No port publish needed. No Vault HTTP client on the host.

## Exit Criteria

- `vault_bootstrap::vault_key_exists` implemented; `is_github_logged_in` uses it — no token value read from Vault at host level
- `build_forge_agent_run_args` no longer calls `read_provider_api_key`; forge container gets an AppRole scoped secret OR uses `PodmanClient::vault_kv_get` to inject key without it transiting the host Vault HTTP client
- `check_github_token_health` removed or replaced with a presence-only containerized probe
- `PodmanClient::vault_kv_get` added to `tillandsias-podman` crate with tests
- `./build.sh --check` passes, no new credential value reads from Vault at host level
- `hardcoded-ip/remove-port-publish` can be unblocked for key-read operations (port publish only needed for Vault initialization, not steady-state reads)

## Dependency

- Vault container must already be running (same as today)
- `tillandsias-podman` crate must expose the `vault_kv_get` helper before headless uses it

## Related

- `plan/issues/forge-harness-auth-vault-proxy-2026-06-27.md` — provider key storage (order 112 slice 1)
- `plan/issues/enclave-transparent-proxy-feasibility-2026-06-26.md` — proxy feasibility
- `hardcoded-ip/remove-port-publish` — blocked; `vault_kv_get` via podman exec unblocks key reads
