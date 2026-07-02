# Keepalive wsl.exe shows as a blank closable terminal — hide it (or make it the debug console)

- **Date**: 2026-07-02
- **Host**: windows (windows-next)
- **Status**: research — feeds order 155
- **Trigger**: operator saw a blank `wsl.exe` terminal alongside the tray, and had previously
  killed it while closing dead terminals — silently severing the control wire.

## Problem

`WslLifecycle::spawn_keepalive` (tillandsias-vm-layer `WslRuntime::spawn_keepalive`) launches a
long-lived `wsl --exec` child to hold the WSL2 utility VM open; without it the VM idles down and
the HvSocket control wire drops. The tray is a GUI-subsystem process, but the spawned `wsl.exe`
allocates its own console window: a blank, unlabeled, fully closable terminal.

Consequences:
- Users reasonably treat it as a dead terminal and close it → VM idles → wire drops → tray
  degrades with no attribution to the user action. (Plausible contributor to historical
  "wire degraded/recovered" reports, order 139.)
- Even unclosed, an unexplained blank console next to a polished tray is broken UX.

## Options to research (operator suggested both)

1. **Hide it**: spawn with `CREATE_NO_WINDOW` (0x08000000) / `DETACHED_PROCESS` creation flags
   (`std::os::windows::process::CommandExt::creation_flags`, works through tokio::process too),
   or use `wsl.exe --exec` via a hidden-window Job. Simplest; matches how the tray already
   captures wsl output elsewhere. Must confirm WSL still counts a windowless session toward
   utility-VM liveness.
2. **Make it useful**: when `--debug` is active, keep (or create) the window as a live debug
   console — stream tray tracing + in-VM `journalctl -fu tillandsias-headless` into it, with a
   title ("Tillandsias debug console") so it is self-explanatory. Hidden by default, shown with
   `--debug` or a tray menu toggle ("Show debug console").
3. **Resilience regardless of 1/2**: the keepalive child must be supervised — if it dies (user
   closes the window, wsl.exe crashes), respawn it and log one WARN, instead of silently losing
   the VM. This is a race/robustness sibling of order 152 (host lifecycle safeguards).

## Recommendation

Do 1 + 3 now (hidden + supervised respawn); treat 2 as the debug-mode enhancement layered on
top. Title any visible window so no user ever has to guess what it is.

## Exit criteria (for the implementation slice)

- No visible console window in default (non-debug) tray operation.
- Killing the keepalive process externally: tray respawns it within one poll cycle, WARN logged,
  wire stays up.
- `--debug` (or menu toggle): a titled debug console shows live tray + headless logs.
- macOS check: confirm the VZ path has no analogous stray UI artifact.
