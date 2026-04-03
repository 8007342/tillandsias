# Design: Windows Runtime Fixes

## Architecture Decisions

### Console Subsystem — FreeConsole() Instead of windows_subsystem Attribute

The `#![windows_subsystem = "windows"]` attribute is a compile-time, all-or-nothing choice. It suppresses the console for the entire process, making CLI mode useless. The fix uses the default console subsystem (so CLI output works in any terminal) and calls `FreeConsole()` at startup when no CLI arguments are present (tray-only mode). This detaches the process from its console window, hiding it without affecting child processes.

```rust
if std::env::args().len() <= 1 {
    unsafe { windows_sys::Win32::System::Console::FreeConsole(); }
}
```

Trade-off: a console window briefly appears before `FreeConsole()` runs (~1ms). In practice this is invisible because the tray app is launched from a shortcut, not a terminal.

### Per-PID Temp Directories

The tray app and CLI can run concurrently (tray doing a background image build while user runs `tillandsias --init`). Both call `write_image_sources()` which extracts embedded flake/script files to disk. Using a fixed directory name caused file corruption.

Fix: append the process ID to the directory name (`image-sources-{pid}`). Each process gets an isolated extraction directory. Cleanup is scoped to the caller's own directory.

### Platform-Aware Shell Quoting

`shell_quote_join()` wraps arguments for shell consumption. On Unix, single quotes are correct (`'arg with spaces'`). On Windows, `cmd.exe` and PowerShell do not recognize single quotes as argument delimiters — only double quotes work.

The function now branches on `cfg!(target_os = "windows")`:
- **Windows**: wraps in double quotes, escapes interior double quotes by doubling them
- **Unix**: wraps in single quotes, escapes interior single quotes with `'\''`

This fixed the `parsing reference 'Windows'` error where Podman received literal single-quote characters as part of the image reference string.

### Windows Terminal Preference

`open_terminal()` on Windows now tries `wt.exe` first, falling back to `cmd /c start` only if Windows Terminal is not installed. Windows Terminal correctly preserves argument quoting through its `cmd /k` dispatch, whereas `cmd /c start` has well-known quoting fragility with nested quotes.

### WSL2 Check in Installer

Podman on Windows uses the WSL2 backend. Without WSL2, `podman machine init` fails with an opaque error. The install script now:
1. Checks if `wsl` command exists
2. If missing, runs `wsl --install --no-distribution` (installs the WSL2 kernel without a distro)
3. Sets WSL2 as the default version (`wsl --set-default-version 2`)

### tillandsias.exe Alias

The NSIS installer writes `tillandsias-tray.exe` (matching the Cargo binary name). Users expect `tillandsias` at the command line. The install script copies `tillandsias-tray.exe` to `tillandsias.exe` in the same directory. A copy (not symlink) avoids UAC and filesystem permission issues on Windows.

### CREATE_NO_WINDOW Flag

All `Command::new()` calls for background subprocesses (`podman`, `bash`) from the tray app now set `creation_flags(0x08000000)` (the Windows `CREATE_NO_WINDOW` constant). This prevents console window flashes for every podman operation. Applied in three locations:
- `podman_cmd()` (async Tokio command)
- `podman_cmd_sync()` (sync std command)
- `handlers.rs` build-image bash dispatch

The flag is gated behind `#[cfg(target_os = "windows")]` and requires `use std::os::windows::process::CommandExt`.

## Data Flow

```
Tray launch (no args) → FreeConsole() → no visible console
CLI launch (with args) → console retained → stdout/stderr visible

write_image_sources() → image-sources-{pid}/ → isolated per process
cleanup_image_sources() → removes only own PID's directory

shell_quote_join(args) → cfg!(windows) → double-quoted → cmd.exe parses correctly
open_terminal(cmd) → try wt.exe → fallback cmd /c start

install.ps1 → check wsl → install if missing → check podman → copy alias
```
