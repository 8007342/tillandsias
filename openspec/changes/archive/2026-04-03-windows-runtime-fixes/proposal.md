# Proposal: Windows Runtime Fixes

## Problem

After the initial `windows-full-support` change shipped, seven runtime issues surfaced during real-world testing on Windows 11:

1. **Console subsystem conflict** — Using `#![windows_subsystem = "windows"]` suppressed all CLI output. Users running `tillandsias --version` or `tillandsias --bash` from PowerShell/cmd saw nothing. But the default console subsystem created a visible console window flash when launching the tray app from the Start Menu.

2. **Temp dir collision** — Both the tray app and CLI invocations wrote embedded image sources to the same `image-sources/` directory. Concurrent runs (e.g., tray background build + `tillandsias --init`) corrupted each other's files.

3. **Shell quoting broken on Windows** — `shell_quote_join()` used Unix single quotes on all platforms. Windows `cmd.exe` does not recognize single quotes, causing `podman run` failures like `parsing reference 'Windows'` when arguments contained spaces.

4. **Windows Terminal not preferred** — `open_terminal()` used `cmd /c start` which mangles arguments containing quotes and special characters. Windows Terminal (`wt.exe`) is present on all modern Windows 11 systems and handles quoting correctly.

5. **WSL2 not checked during install** — `install.ps1` installed Podman via winget but didn't verify WSL2 was present. Podman's WSL2 backend fails silently without it.

6. **No `tillandsias.exe` alias** — The NSIS installer produces `tillandsias-tray.exe`. Users expect to type `tillandsias` at a prompt, not `tillandsias-tray`.

7. **Console window flashes from background subprocesses** — Every `podman` or `bash` subprocess spawned from the tray app briefly flashed a console window, creating a jarring visual experience.

## Solution

Fix all seven issues with targeted, low-risk changes. Each fix is independently testable and does not alter the happy-path architecture.

## Scope

- `src-tauri/src/main.rs` — Remove `windows_subsystem` attribute, add `FreeConsole()` for tray mode
- `src-tauri/src/embedded.rs` — Per-PID temp directories (`image-sources-{pid}`)
- `src-tauri/src/launch.rs` — Platform-aware `shell_quote_join()` using double quotes on Windows
- `src-tauri/src/handlers.rs` — `open_terminal()` prefers `wt.exe`, `CREATE_NO_WINDOW` on background spawns
- `crates/tillandsias-podman/src/lib.rs` — `CREATE_NO_WINDOW` on `podman_cmd()` and `podman_cmd_sync()`
- `scripts/install.ps1` — WSL2 detection + install, `tillandsias.exe` alias copy

## Non-goals

- Windows code signing (still unsigned)
- Native Windows notifications (still no-op)
- Windows ARM64 support
