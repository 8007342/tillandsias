# macOS `--github-login` blocked at Vault bootstrap (60s health timeout) — 2026-06-22

**Filed:** 2026-06-22 (operator-attended macOS `--github-login` finalize)
**Kind:** research / bug (guest-side, shared with Linux/forge)
**Status:** ready
**Host:** macOS (`osx-next`), but root cause is in the **released guest**
`tillandsias-headless` (shared by Linux native + forge + WSL2)
**Trace:** `spec:tillandsias-vault`, `spec:gh-auth-script`,
[[github-login-token-at-rest-audit-2026-06-22]],
[[optimization-macos-vz-idiomatic-exec-layer-2026-06-21]]

## db616e06 NECESSARY BUT NOT SUFFICIENT — Vault unseal still fails on macOS (2026-06-23, released-binary e2e)

Validated against the **released** `v0.3.260622.4` headless (confirmed in the VM:
`--version` = `v0.3.260622.4`; the `mode=0400,uid=` strings are **gone** from the
binary, so db616e06 is present).

**db616e06 DID fix the original crash.** Foreground run of the real vault image
with the fixed args (no uid/gid on the secrets) — the container no longer
crash-loops on the secret; it gets much further:

```
[vault-entrypoint] starting Tillandsias Vault entrypoint
[vault-entrypoint] unseal key material loaded (32 bytes)   # secret READABLE now (db616e06 worked)
[vault-entrypoint] launching vault server
==> Vault server started! ... Listener 1: tcp 0.0.0.0:8200 tls: enabled
[vault-entrypoint] vault API responsive
[vault-entrypoint] subsequent boot: using unseal key from secret
[vault-entrypoint] unsealing vault
curl: (22) The requested URL returned error: 400           # UNSEAL API rejects the request
```

**But Vault still never becomes `initialized && !sealed`**, so the headless
`wait_for_vault_ready` times out:
- Volume with prior data ("subsequent boot"): unseal API call returns **HTTP 400**.
- **Fresh** volume (wiped `tillandsias-vault-data` + secrets, valid identity):
  still `Error: vault did not become healthy within 60s` — so it is NOT merely a
  dirty-volume artifact; a clean init also fails to reach unsealed.

### Net

Order 78 (`db616e06`) was **necessary** — it fixed the "secret unreadable →
container crash-loop" failure — but **not sufficient** on the macOS VZ guest. A
**remaining Vault init/unseal failure** (entrypoint unseal returns 400 / vault
stays sealed) still blocks `--github-login`. Likely in the auto-unseal flow /
the entrypoint's unseal API call under this rootful-podman + Vault 1.18.5 setup —
deep vault-entrypoint / `vault_bootstrap.rs` territory, shared guest code,
reproducible only on the macOS VZ guest. Tracked as order 81. Everything UPSTREAM
of Vault is validated end-to-end on the released build (curl-install → unattended
provision → boot → control wire → guest exec → identity → networks → vault image
+ container start + unseal-key load).

## FIX CONFIRMED + macOS VALIDATION PENDING A RELEASE (2026-06-22, later)

The Linux/guest team shipped order 78 (`db616e06 fix(vault): drop uid/gid from
podman secret mounts for rootful+keep-id compat`). Code-reviewed on macOS: it
**exactly matches the diagnosis below** — all four `--secret` args
(`secret_arg`/`tls_cert_arg`/`tls_key_arg`/`tls_ca_arg`) drop the
`,mode=0400,uid=100,gid=1000` suffix (now just `VAULT_UNSEAL_SECRET.to_string()`,
etc.), so the secrets mount with default ownership readable by the vault user
under the VZ guest's **rootful** podman. `VAULT_USER_UID`/`VAULT_GROUP_GID`
constants removed.

**BLOCKER for macOS end-to-end validation: the fix is not in any RELEASE yet.**
Latest release `v0.3.260622.3` (2026-06-21 21:26 PDT) predates the fix (committed
2026-06-22 01:21 PDT). The macOS VM fetches the guest headless from
`releases/latest`, so `--github-login` Vault will keep failing until a release
contains `db616e06`. A local cross-compile to inject the fixed headless is not
feasible on this host (Homebrew rust, no rustup → no aarch64-musl target std).

**Next action (Linux coordinator / release cadence):** cut a release that
includes `db616e06`; then the macOS team re-runs
`tillandsias-tray --github-login` and expects Vault to come up
(`bootstrap complete`) and the login to complete (token → Vault). machine-id
stability + all other blockers already verified, so this should close the macOS
`--github-login` loop.

## ROOT CAUSE FOUND (2026-06-22, macOS diagnostic) — NOT a timeout

**The 60s→120s fix (order 77) does NOT fix macOS.** The macOS Vault failure is a
**container crash-on-boot**, not slowness. Full diagnostic chain (via headless
`--exec-guest` on the VZ guest):

1. `--debug` health probe: `vault network error: error sending request for url
   (https://127.0.0.1:8201/...)` repeated for the **entire 60s** — connection
   refused, not `sealed`/`initialized` (so more time cannot help).
2. `podman ps -a` empty after 45s; `podman events` shows the `tillandsias-vault`
   container repeatedly **`died`** (image 0.3.260622.3, Vault 1.18.5). It runs
   `-d --rm` (`vault_bootstrap.rs:1120,1144`), so it crash-removes — hiding logs.
3. Foreground run of the vault image reveals the entrypoint:
   `[vault-entrypoint] FATAL: /run/secrets/tillandsias-vault-unseal not present
   after 30s` → the container waits 30s for the unseal secret, doesn't see it,
   FATALs, dies.
4. `podman secret ls` / `inspect`: the podman secret **`tillandsias-vault-unseal`
   EXISTS** on the guest. So the secret is created fine — but it is **not
   readable inside the container** at `/run/secrets/tillandsias-vault-unseal`.

**Root cause:** the launch mounts `--secret tillandsias-vault-unseal,mode=0400,
uid=100,gid=1000` together with `--userns keep-id` (`vault_bootstrap.rs:1091-1094,
1132-1133,1144,1153-1154`; `VAULT_USER_UID=100`, `VAULT_GROUP_GID=1000`). On the
macOS VZ guest the in-VM headless runs **as root (rootful podman)**, whereas
native Linux / the forge run **rootless** podman. Under rootful podman,
`--userns keep-id` + a secret owned `uid=100` does not map to a uid the vault
entrypoint (uid 100) can read, so the `mode=0400` secret file is effectively
unreadable → entrypoint reports "not present" → FATAL. This is why it works on
Linux (rootless) and fails on macOS (rootful).

**Recommended fix (shared guest code — coordinate with Linux/guest team):** make
the unseal-secret mount work under rootful podman — e.g. drop the `uid=/gid=`
secret options and chown inside the entrypoint, detect rootful and adjust the
mapping, or deliver the unseal key by a path that doesn't depend on
keep-id+secret-uid. Must be **verified on the macOS VZ guest** (the only place it
reproduces). `wait_for_vault_ready`'s 120s deadline (order 77) is unrelated.

## machine-id verification (macOS-team task from order 77) — PASS

`/etc/machine-id` is **stable across VM boots** (`b4057c44300542b29d0ca9194b5152a4`
on two fresh boots; persisted 33-byte file on rootfs.img). So the HKDF unseal key
is stable — Vault would NOT stay sealed across boots. Rules out that failure mode;
the crash above is the actual cause.

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
