# macOS curl-install e2e — released v0.3.260626.5 — 2026-06-26 (session 2)

**discovered_by:** `/smoke-curl-install-and-test-e2e` on macOS
**Host:** Darwin arm64, Tillandsias.app installed from release
**Release under test:** `v0.3.260626.5` (published 2026-06-26T21:36:52Z)
**Agent:** `macos-smoke-20260626T1500Z`

## Gates

| Gate | Result |
|---|---|
| Release v0.3.260626.5 assets published (headless aarch64 musl) | PASS |
| `--github-login` control wire + Vault bootstrap start | PASS |
| Vault container pull | PASS — image pulled to completion |
| Vault API probe | **FAIL** — TLS cert `NotValidForName` for `10.0.42.2` |
| `--github-login` exit code | FAIL — `exit_code:1` |

## Error

```
Error: vault podman health is healthy but API probe failed: vault network error:
error sending request for url
(https://10.0.42.2:8200/v1/sys/health?sealedcode=200&uninitcode=200&standbyok=true):
error trying to connect: invalid peer certificate: NotValidForName
{"status":"login-finished","exit_code":1}
```

## Root Cause

The vault TLS certificate is issued for the DNS hostname `vault`, not for the
IP `10.0.42.2`. In v0.3.260626.5:

- `crates/tillandsias-vm-layer/src/vz.rs`: headless systemd service embeds
  `Environment=TILLANDSIAS_VAULT_API_BASE_URL=https://10.0.42.2:8200`
- `crates/tillandsias-macos-tray/src/diagnose.rs:github_login_main`: exec
  command injects `TILLANDSIAS_VAULT_API_BASE_URL=https://10.0.42.2:8200`
- The vault's TLS cert SAN contains `vault` (the Podman service DNS name), not
  `10.0.42.2`

Both must use `https://vault:8200` to match the cert.

## Resolution

**Already fixed on linux-next** (commit `f948defa feat(headless): route vault
by service DNS`):

- `vz.rs`: `Environment=TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200`
- `diagnose.rs`: `export TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200`

Both changes were merged to osx-next via ff-pull on 2026-06-27 and included
in the local macOS tray build.

## Additional Context: exec-guest PTY output not captured in background mode

Discovered during headless binary update attempt: the macOS tray's
`--exec-guest` bridges PTY output to the raw terminal (not to stdout/stderr),
so background Bash invocations cannot capture guest output lines. Only the
`[exec-guest]` prefix lines from the tray process itself appear. Interactive
use (`!` prefix in Claude Code) is required for any exec-guest command that
needs visible output.

## Work Packet: smoke-finding/vault-cert-ip-not-valid-for-name

- id: `smoke-finding/vault-cert-ip-not-valid-for-name`
- owner_host: any
- capability_tags: [rust, vault, macos, tls, networking]
- status: done
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260626.5`
- evidence:
  - `--github-login` output: `invalid peer certificate: NotValidForName` when
    probing `https://10.0.42.2:8200`
  - `crates/tillandsias-vm-layer/src/vz.rs` — `TILLANDSIAS_VAULT_API_BASE_URL=https://10.0.42.2:8200`
  - `crates/tillandsias-macos-tray/src/diagnose.rs` — same IP in exec command
- next_action: Already fixed. Use `https://vault:8200` (DNS name matching cert SAN).
- events:
  - type: discovered
    ts: "2026-06-26T22:05:00Z"
    agent_id: "macos-smoke-20260626T1500Z"
    host: macos
  - type: completed
    ts: "2026-06-27T00:00:00Z"
    agent_id: "macos-advance-20260627T0000Z"
    host: macos
    note: >
      Fixed on linux-next (f948defa). Fast-forwarded into osx-next
      on 2026-06-27 ff-pull. Local macOS tray build now uses vault DNS name.

## Work Packet: smoke-finding/exec-guest-pty-output-not-captured-in-background

- id: `smoke-finding/exec-guest-pty-output-not-captured-in-background`
- owner_host: macos
- capability_tags: [rust, macos, ux, diagnose]
- status: ready
- discovered_by: macOS operator session 2026-06-26
- evidence:
  - Multiple exec-guest background task outputs show only 3 lines:
    `[exec-guest] starting VM…`, `[exec-guest] waiting for control wire…`,
    `[exec-guest] running: [...]` — guest PTY output never appears.
  - Workaround: `! tillandsias-tray --exec-guest "cmd"` in interactive terminal.
- repro:
  - Run `tillandsias-tray --exec-guest "echo hello"` as a non-interactive
    subprocess; observe no guest output in captured stdout.
- next_action: >
    In `exec_guest_main` (crates/tillandsias-macos-tray/src/diagnose.rs),
    collect the PTY output into a buffer and print it to stdout after the
    command completes, rather than bridging the raw PTY to the terminal.
    The `ExecOutput { exit, stdout }` from `exec_over_stream_with_input`
    already accumulates output — ensure it is written to stdout (not /dev/tty)
    before the function returns.
- events:
  - type: discovered
    ts: "2026-06-26T22:30:00Z"
    agent_id: "macos-smoke-20260626T1500Z"
    host: macos

## Work Packet: smoke-finding/install-sh-rejects-aarch64-linux

- id: `smoke-finding/install-sh-rejects-aarch64-linux`
- owner_host: linux
- capability_tags: [rust, release, install, aarch64]
- status: ready
- discovered_by: macOS exec-guest session 2026-06-27
- evidence:
  - Running `curl -fsSL .../install.sh | bash` inside the aarch64 Fedora VM
    (Apple Silicon host, VZ native arm64 guest) printed:
    `ERROR: unsupported architecture: aarch64. This installer ships x86_64 Linux only.`
  - The `tillandsias-headless-aarch64-unknown-linux-musl` asset IS published
    in every release; only `install.sh` hard-gates on x86_64.
- repro:
  - On any aarch64 Linux host (or inside the macOS VZ Fedora guest):
    `curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash`
- next_action: >
    In `scripts/install.sh`, detect `uname -m` == aarch64 and download
    `tillandsias-headless-aarch64-unknown-linux-musl` instead of
    the x86_64 variant. The fetch-headless.sh cloud-init script already
    has the right pattern (`ARCH=$(uname -m)`).
- events:
  - type: discovered
    ts: "2026-06-27T22:40:00Z"
    agent_id: "macos-advance-20260627T2200Z"
    host: macos

---

## Session Progress: 2026-06-28 (phase-check + enclave init)

**Agent:** `macos-advance-20260628T0000Z`
**Headless in VM:** `v0.3.260628.1` (aarch64-unknown-linux-musl, from cloud-init fetch)

### Completed this session

1. **wait_phase_ready implemented** (`osx-next eced3b6f`):
   - Added `probe_vm_phase()` to `vsock_exec.rs`: Hello/HelloAck +
     `VmStatusRequest` round-trip returning `VmPhase` from in-VM headless.
   - Added `wait_phase_ready(timeout)` to `VzRuntime` (macOS-only impl block):
     stage 1 waits for VZ Running; stage 2 loops `probe_vm_phase` until
     `VmPhase::Ready` (podman up) or `Failed`.
   - Replaced all three `wait_ready(90s)` calls in `diagnose.rs` with
     `wait_phase_ready(300s)`. The 300s is a safety cutoff; primary signal is
     the phase.
   - **Verified:** `--exec-guest 'echo hello'` passes wait_phase_ready cleanly
     on fresh VM. `[exec-guest] waiting for VM phase Ready…` displayed.

2. **Fresh re-provision** after binary corruption from prior session.
   Cloud-init `fetch-headless.sh` (uses `uname -m` → aarch64) downloads
   correct binary. Headless v0.3.260628.1 confirmed running.

3. **Enclave init running** (`--exec-guest 'tillandsias-headless --debug --init'`):
   All images building: proxy ✓, git ✓, inference ✓, router ✓,
   chromium-core ✓, chromium-framework (in progress), forge-base (in progress).
   After init completes, proxy image will be in rootfs.img for subsequent boots.

4. **proxy-not-started already fixed** in v0.3.260628.1:
   `ensure_proxy_running()` was added in `plan/issues/proxy-not-started-standalone-flows-2026-06-27.md`.
   After init, `--github-login` should call `ensure_proxy_running` on next boot.

### In Progress

- `tillandsias-headless --debug --init` background exec-guest: building forge-base
  (package 163/547 at last check). Will proceed to `--github-login` on completion.

---

## Session Progress: 2026-06-28 (proxy CA cert fix + github-login flow)

**Agent:** `macos-advance-20260628T0800Z`
**Headless in VM:** `v0.3.260628.1` (unchanged — bugs fixed on tray side and linux-next)

### Root causes identified and fixed

1. **CA cert key permissions (0o600 → squid uid 1000 can't read):**
   - `ensure_ca_bundle` in headless set the private key to 0o600 (root-only).
   - Squid (uid 1000 inside `tillandsias-proxy` container) reads the mounted key
     at `/etc/squid/certs/intermediate.key` and fails:
     `FATAL: No valid signing certificate configured`.
   - **Fix (linux-next):** Changed `set_permissions` to `0o640`.
   - **Workaround (osx-next, diagnose.rs):** `github_login_main` pre-creates
     certs with `chmod 644` via guest bash before running headless, so the
     released headless binary finds the key already present and fresh
     (`ca_bundle_needs_refresh` returns false) and doesn't regenerate it.

2. **Exited proxy container blocks `podman run --name tillandsias-proxy`:**
   - After a failed proxy start, the container remains in Exited state.
   - `ensure_proxy_running` checks `container_running` (Running state only),
     sees false, calls `podman run --name tillandsias-proxy` → error: "name
     already in use".
   - **Fix (linux-next):** Added `podman rm --ignore tillandsias-proxy` before
     `podman run` in `ensure_proxy_running`.
   - **Workaround (osx-next, diagnose.rs):** `github_login_main` bash script
     runs `podman rm tillandsias-proxy 2>/dev/null || true` before headless.

3. **rustfmt drift in vz.rs blocked linux-next integration:**
   - `cargo fmt -p tillandsias-vm-layer` applied; two line-wrap changes in
     `wait_phase_ready`.

### Verified this session

- Exec-guest workaround run (single VM session) confirmed:
  - CA cert pre-created with 0o644 key
  - `tillandsias-proxy` started and stayed running (container_launch state=running)
  - Vault bootstrapped successfully
  - `tillandsias-gh-login-1098` container (git image) launched
  - Auth preflight: vault=Healthy, proxy=Starting (not yet healthy, but running)
  - Flow reached `prompt_and_store_git_identity()` — correct interactive prompt

### Commits this session

- osx-next: `diagnose.rs` CA cert workaround + proxy rm + vz.rs rustfmt fix
- linux-next: headless 0o640 key + `podman rm --ignore` in ensure_proxy_running

### Next: Run `--github-login` interactively

Full tray build installed. Run in terminal:

```bash
! /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray --github-login
```

Enter git author name, email, then paste a GitHub PAT with `repo` scope.
On success: `{"status":"login-finished","exit_code":0}` and the tray menu
should reveal project submenus.
