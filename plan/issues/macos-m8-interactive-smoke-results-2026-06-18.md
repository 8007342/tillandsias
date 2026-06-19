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

## Action items

1. Investigate F4 independent cause: does the forge container actually start? Check in-VM state via vsock after Ready is reported
2. F3 implementation: the shared host-shell `menu_state.rs` needs the collapsed github-gated contract implemented
