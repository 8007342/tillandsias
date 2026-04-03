# Tasks: Windows Runtime Fixes

All tasks completed. Implementation verified on Windows 11 with Podman 5.8.1 WSL2.

## Tasks

- [x] Remove `#![windows_subsystem = "windows"]` attribute from main.rs
- [x] Add `FreeConsole()` call gated on no-args check in main.rs
- [x] Add `windows-sys` dependency for Win32 Console API
- [x] Change `write_image_sources()` to use `image-sources-{pid}` directory in embedded.rs
- [x] Change `cleanup_image_sources()` to use matching `image-sources-{pid}` directory
- [x] Add `cfg!(target_os = "windows")` branch to `shell_quote_join()` using double quotes in launch.rs
- [x] Handle empty-string quoting for Windows in `shell_quote_join()`
- [x] Add `wt.exe` as preferred terminal in `open_terminal()` Windows branch in handlers.rs
- [x] Add `cmd /c start` fallback when `wt.exe` is not available
- [x] Add WSL2 detection to install.ps1 (`Get-Command wsl`)
- [x] Add `wsl --install --no-distribution` when WSL is missing
- [x] Add `wsl --set-default-version 2` to ensure WSL2 is default
- [x] Add `tillandsias.exe` alias copy from `tillandsias-tray.exe` in install.ps1
- [x] Add `CREATE_NO_WINDOW` flag to `podman_cmd()` (async) in tillandsias-podman/src/lib.rs
- [x] Add `CREATE_NO_WINDOW` flag to `podman_cmd_sync()` in tillandsias-podman/src/lib.rs
- [x] Add `CREATE_NO_WINDOW` flag to build-image bash dispatch in handlers.rs
- [x] Verify CLI output works in PowerShell, cmd.exe, and Windows Terminal
- [x] Verify tray launch hides console window
- [x] Verify concurrent tray + CLI invocations don't corrupt image sources
