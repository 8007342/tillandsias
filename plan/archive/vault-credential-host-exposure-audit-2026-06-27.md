# Vault Credential Host-Exposure Audit + Remediation

**Status:** `completed`
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

## Fix 1: `is_github_logged_in` — validate by attempting a project list read (DONE)

**Was**: reads full token value from `secret/github/token` via host HTTP Vault client, checks if non-empty.
A key-existence check is insufficient: the key could be expired or revoked.

**Implemented**:
- `vault_bootstrap::is_github_key_present()` (new, private to crate) — fast `podman exec`
  exit-code check (stdout discarded, no value read), used in the 120× 1s poll loop.
- `remote_projects::probe_github_username(debug)` (new, pub) — runs `tillandsias-git --rm`
  container, reads token via vault-cli inside the container (never in host process), calls
  `gh api user --jq .login`. Returns `Some(login)` only if GitHub accepts the credential.
- `remote_projects::is_github_logged_in(debug)` (new, pub) — `probe_github_username(debug).is_some()`.
  Proves the credential is present AND accepted by GitHub API.

Call site changes:
- Poll loop (`tray/mod.rs`) → `vault_bootstrap::is_github_key_present()` (fast, no container)
- Tray startup probe (`tray/mod.rs`) → `remote_projects::is_github_logged_in()`
- vsock `GithubLoginStatusRequest` — single call to `remote_projects::probe_github_username()`
  replaces the two-step `is_github_logged_in` + `read_github_token_from_vault` + host `gh api user`
- `--list-cloud-projects` pre-flight gate removed — `discover_github_projects_result_with_debug`
  already fails with a clear error if credentials are absent or invalid

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
