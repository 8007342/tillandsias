# Vault Service DNS Missing From no_proxy — GitHub Login + Remote Projects Broken

**Status:** `completed`
**Owner:** linux
**Date:** 2026-06-27
**Severity:** CRITICAL — GitHub login can't store token; remote projects can't list
**Trace:** `spec:proxy-container`, `spec:remote-projects`, `spec:tillandsias-vault`

## Symptom

Linux GitHub login fails to store the token in Vault, and the tray cannot list
remote projects with the saved token. The `--list-cloud-projects` diagnostic
reproduces it deterministically:

```
gh: run_git_image_shell FAILED status=exit status: 1
  stderr="vault-cli: HTTP error reading secret/data/github/token:
          curl: (5) Could not resolve proxy: proxy"
```

## Root Cause

Containers reach Vault by its **service DNS name** `https://vault:8200` since the
move off the locally-bound `127.0.0.1` listener (the "migration to vsock / off
the locally-bound network"). The enclave proxy env injected into every container
(`http_proxy=http://proxy:3128`) sends all egress through the squid proxy unless
the destination is in `no_proxy`.

`ENCLAVE_NO_PROXY_BASE` listed `localhost,127.0.0.1,0.0.0.0,::1,inference,proxy,
git-service,tillandsias-git` — but **not `vault`**. When Vault was on `127.0.0.1`
it was covered by the `127.0.0.1` entry; after the move to the `vault` service DNS
name, nothing in `no_proxy` matched it, so vault-cli's curl tried to route the
Vault request through `proxy:3128` and failed with "Could not resolve proxy:
proxy".

This broke every containerized Vault access:
- `--github-login` in-container `vault-cli.sh write secret/github/token` → token never stored
- `run_git_image_shell` (`probe_github_username`, `fetch_github_projects`) `vault-cli read` → remote projects never list

## Fix

1. Add `vault` and `tillandsias-vault` to `ENCLAVE_NO_PROXY_BASE` so the canonical
   `no_proxy` bypasses the proxy for the Vault service DNS name (and container name).
2. Pass the proxy env **explicitly** on the two git-container launches so the fix
   also reaches **already-initialized hosts**, whose global `containers.conf`
   `[engine] env` carries the stale `no_proxy` (written before the DNS move and
   not rewritten — the write is idempotent). The per-container `--env` overrides
   the stale global value:
   - `run_git_image_shell` (remote_projects.rs) — full 6 proxy vars via `crate::enclave_no_proxy()`
   - `--github-login` helper container (main.rs) — `proxy_env_args()`

## Verification

A/B at the podman level (proxy env present, Vault by service DNS):

```
# no_proxy WITHOUT vault:
curl ... https://vault:8200/... → curl: (5) Could not resolve proxy: proxy   (exit 5)
# no_proxy WITH vault,tillandsias-vault:
curl ... https://vault:8200/... → connects directly (no proxy error)
```

Real binary `--list-cloud-projects --debug`: the `Could not resolve proxy: proxy`
error is gone from `run_git_image_shell` stderr; the Vault read succeeds and the
flow proceeds to `gh` (which only fails here because a placeholder token was
stored for the test — a real token via `--github-login` completes the chain).

Pinned by unit test `enclave_no_proxy_includes_vault_service_dns`.

## Why earlier fixes didn't catch it

The HTTP→exec read fix (order 118) addressed the *host*-side `podman exec` read
path. This is the *container*-side path (vault-cli inside the git/login
containers reaching Vault over the enclave network) — a different transport that
the `no_proxy` list governs. The build-time proxy poisoning (order 116) was the
same class of bug (proxy env where it shouldn't apply) in a third place. Common
root theme: the enclave proxy env is broad and every "talk directly to an
in-enclave service" path must be explicitly exempted.

Bar-raise candidate: an e2e gate that runs `--github-login` + `--list-cloud-projects`
against a live Vault with a real token, so the full store→read→list chain is
exercised in CI rather than only at the unit level.

## Related

- `plan/issues/vault-exec-env-regression-2026-06-27.md` — order 118 (host exec read path)
- `plan/issues/init-proxy-poisons-build-2026-06-27.md` — order 116 (build-time proxy poisoning)
