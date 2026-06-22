# macOS `--github-login` blocked at Vault bootstrap (60s health timeout) — 2026-06-22

**Filed:** 2026-06-22 (operator-attended macOS `--github-login` finalize)
**Kind:** research / bug (guest-side, shared with Linux/forge)
**Status:** ready
**Host:** macOS (`osx-next`), but root cause is in the **released guest**
`tillandsias-headless` (shared by Linux native + forge + WSL2)
**Trace:** `spec:tillandsias-vault`, `spec:gh-auth-script`,
[[github-login-token-at-rest-audit-2026-06-22]],
[[optimization-macos-vz-idiomatic-exec-layer-2026-06-21]]

## Where it stops

The headless macOS `tillandsias-tray --github-login` now drives the released
guest `tillandsias-headless --github-login` successfully through git identity →
networks → Vault image pull, then fails:

```
Git identity saved: /root/.cache/tillandsias/secrets/git/.gitconfig
tillandsias-egress
tillandsias-enclave
[tillandsias-vault] bootstrap starting (Phase 6.5 hardened)
Pulling image vault [██████████] 100%
Error: vault did not become healthy within 60s
{"status":"login-finished","exit_code":1}
```

## Analysis

- `ensure_vault_running` → `wait_for_vault_ready`
  (`crates/tillandsias-headless/src/vault_bootstrap.rs:1169-1198`) polls
  `client.health()` for `initialized && !sealed` against a **hard 60s deadline**
  (line 1174), 2s between probes.
- Unseal is **self-sufficient** — `ensure_unseal_key` derives the key via HKDF
  from `/etc/machine-id` and pushes it as a podman secret (`vault_bootstrap.rs:10,387`).
  So this is **NOT** a host→guest credential-handover gap (the tray's
  `deliver_credentials_and_check_handover` is not required for unseal).
- Therefore Vault either (a) is too slow to init+unseal+serve within 60s on the
  macOS VM (cold first run, single 4 GiB VM running the vault + git containers),
  or (b) fails outright (TLS leaf, machine-id instability across boots, container
  crash, resource pressure).

## Diagnostic attempted (inconclusive)

Ran `--exec-guest /bin/bash -lc '… tillandsias-headless --init --debug'` to
capture `wait_for_vault_ready`'s per-probe `initialized=/sealed=` debug states.
**`--init` produced no output and hung early** (the full-stack init builds many
images — likely the same heavy image-build paths the Linux curl-smoke flagged,
e.g. forge-base pip). Not a clean Vault probe. Need a narrower probe.

## Next steps (need guest-side vault logs)

1. **Narrow probe**: add a guest path / `--exec-guest` script that runs JUST the
   vault bootstrap with `--debug` and then `podman logs <vault-container>` +
   `vault status`, in ONE exec (the VM is stopped after each headless run, so
   the probe must capture logs before exit). This shows sealed-vs-connrefused.
2. **machine-id stability**: confirm `/etc/machine-id` is persisted in
   `rootfs.img` and identical across VM boots — a changing machine-id would make
   the HKDF unseal key differ from the one Vault was initialized with → Vault
   stays sealed → 60s timeout. (High-suspicion on a boot/run/stop loop.)
3. **Timeout adequacy**: if it's genuinely slow cold-start, the 60s in
   `wait_for_vault_ready` may be too tight for a single-VM first init; consider a
   longer/retried deadline (released-guest change → needs a release + VM refetch,
   so coordinate with Linux workers).
4. **Resource**: the macOS VM is 4 GiB (`vz.rs` start). Vault + git container +
   image build may pressure it; check for OOM.

## Cross-host note

`wait_for_vault_ready` + machine-id unseal are **shared guest code**. Whatever
the cause, it affects Linux native / forge / WSL2 Vault bring-up too — coordinate
the fix with the Linux workers rather than patching macOS-only. The macOS-side
driving (`--github-login` over the proven exec/expect path) is correct up to this
boundary; the blocker is in the guest Vault bootstrap.
