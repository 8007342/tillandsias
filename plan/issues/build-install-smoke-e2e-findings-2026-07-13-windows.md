# Windows build-install-smoke e2e findings — 2026-07-13

- discovered_by: `/build-install-and-smoke-test-e2e` (windows) + operator-goal
  forge-lane extension (agent `windows-yolanda-fable5-20260713T2105Z`)
- evidence: `target/build-install-smoke-e2e/20260713T214101Z/*`,
  `/tmp/guest-login.log`, `/tmp/guest-lane.log` (session-local), guest journal
- host: **brand-new Windows 11 Home 10.0.26200 ("yolanda")** — zero prior
  WSL/toolchain state; this run includes the true first-user provisioning path
- tree: windows-next `fd2e11c6` (merge of origin/linux-next 66d8b134),
  VERSION 0.3.260713.1

# Run 1 — 20260713T214101Z series — from-scratch host bootstrap + cold e2e

## New-host bootstrap findings (before any gate)

- **WSL platform absent on fresh Win11** (S1) and **reboot-pending after
  VirtualMachinePlatform enable** (S2, DISM 3010): filed as orders **323/324**
  with detection recipes —
  `plan/issues/wsl2-reboot-pending-first-install-ux-2026-07-13.md`
  (operator directive: tray must say "WSL2 requires a restart", installer must
  own the restart instruction).
- The pending reboot also blocks VS Build Tools (bootstrapper error **5008**)
  — dev-host provisioning must sequence: enable VMP → reboot → toolchain.
- `wsl --install --no-distribution` from the inbox stub failed with the
  "not installed" banner even elevated; the working sequence was
  `dism /enable-feature VirtualMachinePlatform` + `winget install
  Microsoft.WSL` + reboot.

## Gates

| Gate | Result |
|---|---|
| 1 build (`scripts/build-windows-tray.ps1`, EMPTY guest embed — no `target-guest/` on fresh host) | PASS — `tillandsias-tray 0.3.260713.1 (fd2e11c6)`, embedded SHA == HEAD, 7.2 MB, 2m43s |
| 1 install (direct-copy convention + `--version` probe) | PASS — `%LOCALAPPDATA%\Programs\Tillandsias`, ver_exit=0 |
| 2 destroy (`wsl --shutdown` + `--unregister` + cache/logs/wsl dirs) | PASS — `WSL_E_DISTRO_NOT_FOUND` tolerated (pristine host), all data dirs absent → truly cold |
| 3 cold re-provision (`--provision-once`) | PASS — `RESULT: VM Ready — control wire up ✓` in ~4 min (66 MB Fedora rootfs → import → recipe dnf 111 pkgs → systemd units → handshake) |
| 3 diagnose (`--diagnose --json`) | PASS (exit 2 degraded = expected idle-VM state post-provision without live tray); distro_registered=true, elevated=true, wsl 2.7.10.0 |
| 4 forge lane (operator-goal extension, not in the Windows skill table) | see Run 1 lane section below |

## Findings (product)

1. **Absent-embed fallback engaged correctly but ships version skew**: fresh
   build had no staged guest binary → guest ran
   `tillandsias-headless-fetch.service` and fetched **release v0.3.260712.1**
   while the tray is **0.3.260713.1 (fd2e11c6)**. WIRE_VERSION=2 on both sides
   (verified pre-run) so the wire works, but the guest-side enclave images
   (`localhost/tillandsias-{vault,proxy,git}:v0.3.260712.1`) are one release
   behind the tree under test. Consequence: a Windows e2e without staged
   guest binaries validates the HEAD tray against the *previous release's*
   guest stack. Existing mitigation: stage `target-guest/` per order 282
   (needs a Linux builder or in-guest cargo). Not filing a new packet —
   order 282's transport options already cover it; recording the skew so
   the PASS is honestly scoped.
2. **Proxy teardown SIGSEGV (exit 139) reproduces on Windows/WSL**: when the
   10-min host timeout SIGTERMed the first `--github-login` attempt,
   `tillandsias-proxy` exited **139** while vault exited 143 (clean SIGTERM).
   This corroborates the Linux finding filed this morning in
   `plan/issues/smoke-e2e-findings-v0.3.260712.1-2026-07-13.md` (proxy
   teardown SIGSEGV) — cross-platform, so the bug is in the proxy binary's
   signal path, not host-specific plumbing. Appended as evidence, no new packet.
3. **Guest minimal-env tool gaps**: `pgrep` absent in the provisioned guest
   (procps-ng not installed). Sibling of the forge-env gaps (diff/file) noted
   in the 2026-07-12 forge cycle. Low priority; affects diagnostics ergonomics
   only.
4. **First `--github-login` on a cold guest is a multi-minute operation**: it
   transparently builds the entire enclave (vault 497 MB image + proxy + git
   images, Phase 6.5 vault bootstrap with 8 policies) before the token write.
   Operator-facing surfaces should message this (first-login progress), else
   it reads as a hang. (Candidate enhancement; see lane section for whether
   this recurs on the attach path.)
5. **`--github-login` token read hangs FOREVER without a TTY** (filed as
   order **325**): the git identity prompts read stdin (piped input works —
   identity saved on attempt 1), but the token step runs
   `podman exec --interactive --tty tillandsias-github-login-<pid> /bin/bash -c
   'IFS= read -rs TOKEN < /dev/tty …'` — reading `/dev/tty`, which a
   non-interactive invocation can never satisfy. No timeout, no fail-loud, no
   `--with-token`-from-stdin mode (which `gh auth login` itself supports and
   the flow already uses internally). Two independent 10-minute hangs
   reproduced; process tree captured. Workaround used by this run:
   `script -qec` PTY allocation in-guest (needed `dnf install
   util-linux-script` — script(1) absent from the provisioned guest, see
   finding 3).

## Run 1 lane — BigPickle /meta-orchestration inside the forge (operator goal)

Operator goal for this cycle: OpenCode ("BigPickle") completes one
`/meta-orchestration` cycle inside a Tillandsias Forge on the full Windows
stack (tray → WSL2 guest → rootful podman → vault → git mirror → forge →
opencode → push relay). Lane invocation mirrors the tray attach launch_spec
(`vm_login_shell_argv` wrapper + `tillandsias-headless --cloud 'tillandsias'
--opencode --prompt "Use the /meta-orchestration skill"`) via the
`wsl.exe -d tillandsias` attach transport, as root (matches the vsock
pty_handler context; rootful podman owns the enclave).

Pre-lane seeding: `--github-login` (product surface) under in-guest
`script(1)` PTY → `GitHub authentication complete for 8007342`, exit 0
(vault write at secret/github/token). See finding 5 for the non-TTY hang
this required working around.

- **Attempt 1 — FAIL (order 326 filed)**: containerized `gh repo clone`
  died in seconds: `could not create work tree dir
  '/home/forge/src/tillandsias.tmp.18c1f90695d94a22': Permission denied`.
  Guest inspection: NO `forge` user exists and `/home/forge/src` is
  root:root 0755 — the WSL recipe writes wsl.conf `default user forge` but
  never creates the user or chowns the src root; with `--cap-drop=ALL` no
  container uid can write it. macOS VZ clones fine (order 273 capture), so
  this is Windows-recipe-specific. Workaround applied for goal progress:
  `chmod 0777 /home/forge/src` (recorded; NOT the fix).
- **Attempt 2 — FAIL (order 327 filed)**: clone completed (vault-token
  mirror auth works), lane lazily built vault/proxy/git/inference/
  forge-base/forge (3.1 GB, ~15 min), then stage 'router' ran `podman run
  localhost/tillandsias-router:v0.3.260712.1` WITHOUT ensuring the image →
  podman treated localhost as a registry → "dial tcp 127.0.0.1:443:
  connection refused" ×3 → exit 125, lane dead. Order-76 parity gap: the
  router stage was never added to ensure_image_exists. Workaround: ran
  `tillandsias-headless --init --debug` in the guest to build the full
  image ladder (router:v0.3.260712.1 confirmed present).
- **Attempt 3 — BigPickle cycle ran, verdict BLOCKED (contract-compliant)**:
  relaunched as an in-guest systemd unit (`till-lane3`, keepalive wsl.exe
  pinning the VM — the tray's own wsl_lifecycle pattern). Router started
  clean this time, forge container up, OpenCode launched with the
  /meta-orchestration prompt and executed the skill CORRECTLY: host
  classified `forge` (TILLANDSIAS_HOST_KIND=forge set ✓), credential guard
  run → `missing:no-credential-channel` → treated as the cycle-stopping
  blocker per the exit contract, matched to the existing issue
  forge-credential-guard-push-channel-gap-2026-07-08.md, no committable
  work attempted, clean worktree at exit, owner + smallest-next-action
  reported. BigPickle's own root-cause (verbatim): "Origin resolves to
  https://github.com/8007342/tillandsias.git (direct GitHub), not the
  enclave git mirror" — i.e. the forge gitconfig/mirror injection
  (write_forge_gitconfig insteadOf + GIT_CONFIG_GLOBAL) did not engage on
  the Windows guest CLI lane, and no tillandsias-git-<project> mirror
  relay was observable. NOTE the same release binary pushed through the
  mirror on the Linux curl-install e2e this morning, so the gap is
  Windows-guest-lane-specific wiring, not a v0.3.260712.1-wide break.
  De-dup: evidence appended to the 2026-07-08 issue (orders 173/177 +
  the 318-322 mirror ladder own the systemic fix); no duplicate packet.
  Full transcript: `$LOG_DIR/04-meta-orchestration.log`.
- **Attempt 4 — full-cycle retry with credential workaround**: seeded the
  repo-local store the guard checks first (`.git/.gh-credentials` +
  credential.helper in the clone's .git/config — BigPickle's own
  smallest-next-action), explicitly bypassing the broken mirror-relay leg
  (recorded as NOT exercised). Results below.
