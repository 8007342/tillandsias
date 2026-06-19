# macOS m8 user-attended smoke — round 2 — results 2026-06-18

Operator: user at macOS terminal
Build HEAD: `e4ef0db0` (osx-next)
Build: `scripts/build-macos-tray.sh && scripts/install-macos.sh`

## Results

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | Menu icon | **PASS** | Renders as crisp tinted glyph (F1 fixed by `1ada1f28`) |
| 2 | VM boots to Ready | **PASS** | Status chip showed `Ready tillandsias-in-vm` (F2 fixed by step 49b/c) |
| 3 | Collapsed/github-gated menu | **FAIL** | Menu showed "the old messy UX" — full always-shown item list instead of the collapsed short list (F3 still open) |
| 4 | GitHub Login PTY | **FAIL** | Clicking GitHub Login opens a terminal that goes full gray immediately (F4 — previously believed to be purely downstream of F2, but VM now reaches Ready and it still fails; F4 has an independent root cause) |
| 5 | Quit | **PASS** | Exits cleanly |

## Key finding: F4 is NOT resolved by step 49 alone

F4 (`github-login-pty-hangs-gray`) was previously marked as downstream of F2 (`vm-reports-failed-after-clean-boot`). Now that F2 is resolved (VM reaches Ready ~32s post-boot), F4 still fails: the terminal opens and immediately goes gray.

Hypotheses for the independent root cause:
- The in-VM forge container may not be running despite `podman_ready=true` (headless may report Ready as soon as podman socket is available, before the forge container is actually up)
- The PTY attach path (`pty_vsock_bridge.rs` / `terminal_attach.rs`) may have a wiring bug that is independent of VM state
- The terminal attach may be trying to connect to a port/container that doesn't exist yet

## F3 remains open

The menu not being collapsed (F3 / `macos-tray/menu-not-collapsed-github-gated`) is unchanged. It is not downstream of any remaining blocker — it is a shared host-shell change that needs cross-host coordination.

## Freshness gate (this run)

Installed `--version` = `git e4ef0db0` == `git rev-parse --short HEAD` at smoke
time (built 2026-06-18T23:19:22Z, clean build, no `-dirty`). Gate **PASS** — the
tray under test was the current HEAD, not a stale artifact. Host-side capture:
`/tmp/m8-smoke.log` (tray launched from terminal so stderr was captured live).

```
[tillandsias-tray] vm-status: phase=Ready podman_ready=true event=tillandsias-in-vm   # ~9s
[tillandsias-tray] click: id=github-login action=GithubLogin
[tillandsias-tray] GitHub login: spawning attach worker (project=None)
[tillandsias-tray] GitHub login: PTY attached at /dev/ttys002   # PTY opened host-side, but Terminal stayed gray
[tillandsias-tray] click: id=local-projects action=Inert        # F5: item inert, no enumeration
[tillandsias-tray] Quit: draining (timeout=60s) … VZ.requestStop  # clean exit
```

## CRITICAL CAVEAT: F4/F5 ran against a STALE in-VM headless agent

The VM re-used the **Jun-16-provisioned** `rootfs.img`. The `tillandsias-headless`
agent baked into that disk PREDATES the github-login egress fixes that landed
and shipped THIS day:
- `62e73c70 fix(headless): ensure enclave+egress networks before github-login helper launch`
- `777eb745 fix(github-login): harden gh-login egress`
- both shipped in release **v0.3.260618.2** (integrated into osx-next at `0025f419`).

So the F4 gray-terminal result does NOT yet test BigPickle's egress fix. Before
concluding F4 has a purely host-side root cause, the VM must be re-provisioned so
it fetches the v0.3.260618.2 headless. BigPickle's hypothesis (forge container
not up despite `podman_ready=true`) is exactly what `62e73c70` addresses on the
in-VM side — a re-provision is the discriminating test.

## Round 3 retest (post-fix, build `8f3d87c1`) — F3 FIXED; F4 root-caused

After landing the F3 login-gate fix (`8f3d87c1`) and re-provisioning the VM with
the v0.3.260618.2 headless, the operator re-ran the smoke:

| # | Item | Status | Notes |
|---|------|--------|-------|
| F3 | Collapsed/github-gated menu | ✅ **FIXED** | operator: "src and cloud menus correctly gated and not displayed, I can only see the Ready tillandsias-in-vm message" + GitHub Login. Login-gated collapse works. |
| F4 | GitHub Login PTY | ❌ **STILL GRAY** (root-caused) | even with the fresh headless + re-provision, the terminal still goes full gray. NOT the egress fix; independent host/in-VM path bug — see root cause below. |

### F4 root cause (definitive)

The macOS tray's GitHub Login does a generic PTY attach whose in-VM command is
`launch_spec(GithubLogin, project=None)` =
**`["gh", "auth", "login"]` run on the bare VM** (`host-shell/src/pty/mod.rs:142,161`).

Chain of failure:
1. The bare Fedora VM installs **only podman** (`vm-layer/src/vz.rs:382-385`); `gh`
   is **not** on the bare VM — it lives inside the enclave/git container.
2. The in-VM headless execs `gh` → not found → process exits immediately → PTY
   EOF → Terminal opens but stays gray (host log shows `PTY attached at
   /dev/ttysNNN` then nothing; vsock connect + handshake + PtyOpen all succeed,
   so the host side is healthy — the in-VM command is the problem).
3. The **correct** flow is the orchestrated `--github-login`
   (`headless/src/main.rs:301 → run_github_login`, main.rs:3834): it pulls the
   git image, ensures `tillandsias-enclave,tillandsias-egress`, brings Vault up,
   and runs `gh auth login` **inside** a properly-networked, Vault-leased
   container. The Linux tray invokes exactly this via `tillandsias --github-login`
   (`headless/src/tray/mod.rs:1910`).

Why it can't be a one-line macOS fix:
- Pointing `launch_spec(GithubLogin)` at `["tillandsias-headless","--github-login"]`
  would hit `require_desktop_user_session` (`tillandsias-podman/src/lib.rs:161`),
  which **rejects the headless service-account lane**. The in-VM headless runs as
  a systemd service (`tillandsias-headless.service`), so a PTY subprocess inherits
  that lane and the guard returns `Err` before any gh login starts.

### F4 fix (cross-host — headless/Linux-owned, macOS-coordinated)

Add an in-VM **interactive github-login entrypoint driven over vsock/PTY** that:
- runs the `run_github_login` orchestration (enclave+egress nets, Vault lease,
  gh device-code paste in the git container) **without** requiring the desktop
  user-session lane — the authenticated host tray IS the trusted desktop session,
  so the in-VM driver should treat a tray-initiated vsock PTY as authorized;
- surfaces the interactive device-code prompt + any error back through the PTY so
  the macOS Terminal shows progress instead of a silent gray window (also
  satisfies `macos-tray/github-login-pty-hangs-gray`'s "fail visibly" clause).
Then change the macOS (+ Windows) `launch_spec(GithubLogin)` to target that
entrypoint instead of bare `gh auth login`. Coordinate the control-wire/headless
contract on `linux-next`; wire the macOS `launch_spec` arg on `osx-next`.

## Action items

- [x] Re-provision the macOS VM with the v0.3.260618.2 headless — DONE this
      session; enclave reaches `phase=Ready podman_ready=true` ~9-17s.
- [x] F3 collapsed/login-gated menu in shared `host-shell/menu_state.rs` — DONE
      (`8f3d87c1`), operator-confirmed. Windows + macOS adapters + tests updated.
- [ ] **F4 (cross-host):** add the in-VM interactive github-login-over-PTY
      entrypoint (see "F4 fix" above) on `linux-next`/headless, then point the
      macOS+Windows `launch_spec(GithubLogin)` at it on `osx-next`. Until then the
      macOS GitHub Login is non-functional (gray terminal). Owns:
      `macos-tray/github-login-pty-hangs-gray` (re-scoped from "downstream of F2"
      to "bare-VM `gh` has no binary; needs orchestrated in-VM entrypoint").
- [ ] F5 projects: re-test once F4 lands (projects come from the in-VM forge that
      github-login authenticates against). Logged-out is correctly empty now (F3).

## m8 gate status

RED → **less red.** Keystone F2 ✅, icon F1 ✅, menu F3 ✅, Quit ✅. The single
remaining blocker is F4 (in-VM github-login entrypoint, cross-host). No projects
(F5) until a user can authenticate, which F4 gates. Do not mark the m8 release
gate GREEN until F4 lands and login → projects → attach works end-to-end.
