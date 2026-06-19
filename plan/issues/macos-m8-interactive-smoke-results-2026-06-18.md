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

## Action items

1. **Re-provision the macOS VM** (destroy `rootfs.img`, cold boot → fetch the
   v0.3.260618.2 in-VM headless with the egress fix), then operator re-runs the
   GitHub Login step. This settles whether F4 is now fixed in-VM or is a residual
   host-side PTY-bridge bug.
2. Investigate F4 residual cause if it persists after (1): does the forge
   container actually start? Check in-VM state via vsock after Ready is reported;
   ensure the PTY bridge FAILS VISIBLY (print the error, keep the terminal open).
3. F3 implementation: the shared host-shell `menu_state.rs` needs the collapsed
   github-gated contract implemented (cross-host coordination: Linux + Windows).
   This is the top remaining macOS-visible defect and is independent of the VM.
4. The `local-projects action=Inert` (F5) is a symptom of the F3 wrong menu model
   plus the stale agent; retest after (1) + (3).
