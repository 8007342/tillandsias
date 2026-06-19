# macOS GitHub Login — full root-cause deep-dive (2026-06-18)

The macOS tray's "GitHub Login" opens a Terminal that goes **full gray**. This
file traces the failure all the way down, empirically, by SSHing into the running
guest (the cloud-init installs the operator's own SSH key into the VM's `root` +
`fedora`, so `ssh root@<vm-ip>` works) and running the in-VM
`/usr/local/bin/tillandsias-headless` directly with `--github-login --debug`.

Build under test: tray `8f3d87c1`; in-VM headless **v0.3.260618.2** (the egress-fix
release). VM provisioned fresh this session; enclave reaches
`phase=Ready podman_ready=true` ~9–17s.

## TL;DR — five stacked layers

| # | Layer | Status | Owner |
|---|-------|--------|-------|
| 1 | Menu wasn't login-gated (F3) | ✅ FIXED `8f3d87c1` | macОS/host-shell (done) |
| 2 | Tray runs **bare `gh auth login`** on the VM; `gh` isn't on the bare VM | ❌ | macOS/host-shell (`launch_spec`) |
| 3 | Correct `--github-login` flow is gated by `require_desktop_user_session` (needs `XDG_RUNTIME_DIR`); a service-spawned PTY child lacks it | ❌ | macOS cloud-init + host-shell env |
| 4 | `--github-login` prompts for git identity (name/email) | ⚠️ works interactively | n/a (user types it) |
| 5 | **Vault health probe to published `127.0.0.1:8201` times out** even though Vault is healthy *inside* the container → "vault did not become healthy within 60s" | ❌ **current blocker** | in-VM enclave/vault/podman-net (headless/recipe, cross-host) |

Net: even with layers 2–3 fixed, GitHub Login cannot complete until layer 5
(in-VM Vault reachability) is fixed. Layer 5 is the real wall.

## Evidence per layer

### Layer 2 — bare `gh` on a VM without `gh`
`host-shell/src/pty/mod.rs:138-162`: `launch_spec(GithubLogin, project=None)` →
argv `["gh","auth","login"]`, run on the **bare VM**. In the guest:
```
# command -v gh  → GH NOT FOUND on bare VM
```
Cloud-init (`vm-layer/src/vz.rs:382-385`) installs **only** podman. `gh` lives in
the enclave/git image, not on the bare rootfs. So the in-VM headless execs `gh` →
ENOENT → instant exit → PTY EOF → **gray Terminal**. (Host log: `PTY attached at
/dev/ttysNNN` then nothing — host side is healthy; the in-VM command is wrong.)

The Linux tray does NOT do this — it runs `tillandsias --github-login`
(`headless/src/tray/mod.rs:1910`), the orchestrated flow.

### Layer 3 — desktop-lane guard needs XDG_RUNTIME_DIR
`run_github_login` (`headless/src/main.rs:3834`) starts with
`require_desktop_user_session` (`tillandsias-podman/src/lib.rs:161`). In the guest:
```
# env -i PATH=... HOME=/root TERM=... tillandsias-headless --github-login
  → Error: requires a real desktop user session with a writable XDG_RUNTIME_DIR
# env -i ... XDG_RUNTIME_DIR=/run/user/0 tillandsias-headless --github-login
  → runtime lane: desktop-user-session   (guard PASSES)
```
The headless **service** sets no `TILLANDSIAS_*` env (so the lane resolves to
`DesktopUserSession`), but a service-spawned child has no `XDG_RUNTIME_DIR` and no
`/run/user/0` unless a logind session exists. `/run/user/0` is present only while
a session is active (e.g. our SSH).

### Layer 4 — git identity prompt
`prompt_and_store_git_identity` reads defaults from `gitconfig_default_paths()`
(managed path + `$HOME/.gitconfig`) and prompts for name/email; empty input takes
the default. `git` is also absent on the bare VM, so `git config --global` no-ops;
seeding `/root/.gitconfig` directly lets it proceed. Over a real interactive PTY
the user simply types their identity — not a true blocker.

### Layer 5 — Vault launches healthy but the host-side probe can't reach it
With layers 2–4 satisfied, the orchestrated flow runs end-to-end up to Vault:
- ✅ builds the `tillandsias-vault` image (alpine pkgs, 17 steps) — **egress +
  image build work in the VM**
- ✅ creates `tillandsias-enclave` + `tillandsias-egress` networks, derives the
  unseal key (note: keyring/DBus secret service is **absent** in the VM →
  falls back to a file-derived "first-boot dummy key K"), launches
  `tillandsias-vault` publishing `127.0.0.1:8201->8200/tcp`
- ✅ **Vault is healthy INSIDE the container** — logs: `vault is unsealed` /
  `vault is fully configured (policies loaded, approle+kv2+audit enabled)`
- ❌ host-side probe fails: `vault did not become healthy within 60s`

Why the probe fails (decisive tests from the VM host):
```
# /dev/tcp/127.0.0.1/8201            → TCP 8201 OPEN     (port publish accepts SYN)
# curl -k https://127.0.0.1:8201/... → (28) Connection timed out after 8s
# openssl s_client -connect 127.0.0.1:8201 → (no response, times out)
# podman port tillandsias-vault      → 8200/tcp -> 127.0.0.1:8201
```
TCP connects but **no data flows** even with TLS verification disabled (`-k`).
The published port accepts the connection but never delivers bytes to Vault's API
backend inside the container — a podman port-publish-vs-backend problem in the
aarch64 Fedora guest (e.g. Vault's API listener binding / rootlessport / netns
forwarding). Vault itself is fine; the **mapping** is the fault.

(Separate probe bug spotted: the host-side health probe references
`--cacert /run/secrets/tillandsias-vault-tls-ca`, which is the *in-container*
secret mount path and does not exist on the VM host — the host CA is at
`/tmp/tillandsias-ca/intermediate.crt`. Even once layer-5 connectivity is fixed,
the probe's CA path looks wrong for host-side execution.)

## Fix plan (land together; do NOT ship 2–3 alone — login still dies at 5)

- **Layer 5 (BLOCKER, cross-host — headless/enclave/recipe, `linux-next`):**
  make the in-VM Vault API reachable through the published port on aarch64
  (check Vault's `tcp` API `address` binds `0.0.0.0:8200` not `127.0.0.1`, and/or
  the podman publish/netns path), and fix the host-side health-probe CA path to a
  host-resident CA (`/tmp/tillandsias-ca/intermediate.crt`) instead of the
  in-container `/run/secrets/...`. Verify `curl --cacert <host-ca>
  https://127.0.0.1:8201/v1/sys/health` returns 200 from the VM host.
- **Layer 2/3 (macOS + shared host-shell, `osx-next`):** point
  `launch_spec(GithubLogin)` at `["tillandsias-headless","--github-login"]` with
  `XDG_RUNTIME_DIR` (+ `TERM`) in the PTY env; add `loginctl enable-linger root`
  to the cloud-init (`vz.rs`) so `/run/user/0` persists for the service-spawned
  PTY child. Mirror on Windows tray per parity.
- Re-run m8 GitHub Login after 5 + 2/3 land; only then is F4 green.

## How to reproduce / continue (operator notes)

```
# launch tray (auto-boots VM), grab IP:
/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray > /tmp/t.log 2>&1 &
grep -oE 'enp0s1: [0-9.]+' /tmp/t.log | tail -1
# SSH in (operator key is provisioned into the guest):
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<vm-ip>
# drive the real flow with debug:
printf '[user]\n\tname = You\n\temail = you@x.com\n' > /root/.gitconfig
printf '\n\n' | /usr/local/bin/tillandsias-headless --github-login --debug 2>&1 | tail -80
podman logs tillandsias-vault 2>&1 | tail -40
```

@trace plan/issues/macos-m8-interactive-smoke-results-2026-06-18.md (F4),
plan/steps/49-macos-in-vm-enclave.md, macos-tray/github-login-pty-hangs-gray
</content>
