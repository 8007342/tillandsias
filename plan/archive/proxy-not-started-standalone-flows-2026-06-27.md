# Standalone Flows Don't Start the Enclave Proxy — github-login + remote-projects fail

**Status:** `completed`
**Owner:** linux
**Date:** 2026-06-27
**Severity:** CRITICAL — GitHub login and remote-project listing fail outside a tray session
**Trace:** `spec:proxy-container`, `spec:remote-projects`

## Symptom

`tillandsias --github-login` reaches the token prompt, then fails:

```
Paste your GitHub authentication token (input hidden), then press Enter:
error connecting to proxy
check your internet connection or https://githubstatus.com
Error: Command exited with status exit status: 1
```

`--list-cloud-projects` fails the same way (the `gh` fetch can't egress).

## Root Cause

The enclave network (`tillandsias-enclave`) is `--internal` — no external route.
The squid proxy container (`tillandsias-proxy`, hostname `proxy`) is the ONLY
egress path: it performs DNS resolution and the outbound fetch for everything
leaving a container. Confirmed: from a git container with no proxy, even DNS
fails (`curl https://api.github.com → exit 5, could not resolve host`).

The standalone CLI flows (`run_github_login`, `run_list_cloud_projects`) bring up
Vault and the networks but **never start the proxy**. After a fresh `--init` only
`tillandsias-vault` is running. So the moment a containerized `gh` (which has
`http_proxy=http://proxy:3128`) tries to reach api.github.com, nothing answers at
`proxy:3128` → "error connecting to proxy".

This is masked in normal use because launching the tray/enclave starts the full
stack including the proxy; it only bites the standalone CLI flows (and any flow
run before the tray's enclave is up).

## Fix

New `ensure_proxy_running(debug)` (mirrors `ensure_vault_running`): idempotently
starts `tillandsias-proxy` via `build_proxy_run_args` + `run_container_observed`
if not already running. Called in `run_github_login` and `run_list_cloud_projects`
after Vault is ensured; both now also assert `tillandsias-proxy` in the auth
preflight.

## Verification

```
$ tillandsias --list-cloud-projects --debug
[tillandsias] enclave proxy started
... (no "error connecting to proxy"; proceeds to gh)

$ podman ps | grep proxy
tillandsias-proxy  Up (healthy)

# GitHub egress through the now-running proxy:
$ podman run --rm --network tillandsias-enclave,tillandsias-egress \
    --env http_proxy=http://proxy:3128 ... curl -w '%{http_code}' https://api.github.com/zen
api.github.com via proxy: http_code=200 exit=0
```

With the proxy up, the Vault read (order 119) and GitHub egress both work; a real
token via `--github-login` completes the store→list chain.

## Deeper Problem (filed separately)

This is the 4th bug in a row rooted in an **implicit, runtime-discovered container
dependency** (build proxy 116, host exec env 118, no_proxy 119, proxy-not-running
119→this). "Launching the gh-login/git container requires the proxy container
running" is invisible until it fails at runtime. The operator has asked for a
**compile-time container dependency model** so a launch whose dependencies aren't
satisfied fails to compile. Filed as:
- `plan/issues/container-dependency-graph-research-2026-06-27.md` (research)
- `plan/issues/container-dependency-graph-impl-2026-06-27.md` (implementation)

## Related

- `plan/issues/vault-service-dns-no-proxy-2026-06-27.md` — order 119 (no_proxy)
- `plan/issues/vault-exec-env-regression-2026-06-27.md` — order 118
- `plan/issues/init-proxy-poisons-build-2026-06-27.md` — order 116
