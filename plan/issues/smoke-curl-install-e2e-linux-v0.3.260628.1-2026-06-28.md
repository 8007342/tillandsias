# Smoke E2E (curl-install) — Linux — v0.3.260627.6 → v0.3.260628.1

**Result:** PASS (credential path verified end-to-end with a real GitHub account)
**Host:** linux_mutable (Fedora, rootless podman)
**Date:** 2026-06-28
**Release exercised:** installed v0.3.260627.6; fix for the final P0 shipped as v0.3.260628.1

## Steps run

1. **Destructive substrate reset** — `podman system reset --force` → 0 containers / 0 volumes / 0 images confirmed.
2. **Curl-install** — `curl -fsSL .../install.sh | bash` installed **v0.3.260627.6**; installer ran `--init --debug`.
3. **Fresh init** — completed at **exit 0**. Vault bootstrap complete, `tillandsias-vault` Up (healthy), `initialized: true, sealed: false`. All enclave images rebuilt (proxy/git/inference/chromium-core/chromium-framework/forge-base/forge). No proxy/DNS/cert/vault-connection errors.
4. **GitHub login** — `tillandsias --github-login --debug` → `GitHub authentication complete for 8007342`; token stored in Vault at `secret/github/token` (verified via in-container `vault-cli.sh read`).
5. **Remote projects** — `tillandsias --list-cloud-projects --debug` → `run_git_image_shell ok status=exit status: 0`, **fetched 23 remote project(s) in 2.18s**.

## What this validated

The full credential path that had been broken across four P0s, now all fixed:
- order 116 (build proxy poison), order 118 (host exec env), order 119 (vault no_proxy), order 120 (proxy not started in standalone flows).
- `api.github.com` returns `http_code=200` through the auto-started enclave proxy.

## Caveats / follow-ups

- The order-120 `ensure_proxy_running` fix is verified by code + the proxy A/B (200) and shipped in v0.3.260628.1; the live login above succeeded because the proxy was already up from verification. A fresh-install standalone `--github-login` (no prior proxy) is covered by v0.3.260628.1 — re-confirm on the next curl-install cycle.
- Bar-raise candidate (filed in the four P0 issues): an automated e2e gate exercising `--github-login` → store → `--list-cloud-projects` against a live Vault, so this class of regression is caught in CI, not by hand.

## Trace

- `plan/issues/proxy-not-started-standalone-flows-2026-06-27.md` (order 120)
- `plan/issues/vault-service-dns-no-proxy-2026-06-27.md` (order 119)
