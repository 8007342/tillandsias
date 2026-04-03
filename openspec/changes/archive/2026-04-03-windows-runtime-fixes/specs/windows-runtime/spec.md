# Spec: Windows Runtime (Delta)

## Requirements

### REQ-WIN-CONSOLE: Console subsystem with FreeConsole

- **GIVEN** the app is compiled with the default console subsystem (no `windows_subsystem` attribute)
- **WHEN** launched with no CLI arguments (tray-only mode)
- **THEN** `FreeConsole()` MUST be called before any heavy initialization, hiding the console window
- **WHEN** launched with CLI arguments (`--version`, `--bash`, `--init`, etc.)
- **THEN** the console MUST remain attached so stdout/stderr are visible in the user's terminal

### REQ-WIN-TEMPDIR: Per-PID image source directories

- **GIVEN** embedded image sources need to be extracted to disk
- **WHEN** `write_image_sources()` is called
- **THEN** the extraction directory MUST include the process ID (`image-sources-{pid}`) to prevent collisions between concurrent tray and CLI invocations
- **AND** `cleanup_image_sources()` MUST only remove the calling process's directory

### REQ-WIN-QUOTING: Platform-aware shell quoting

- **GIVEN** arguments are being quoted for shell consumption via `shell_quote_join()`
- **WHEN** the target platform is Windows
- **THEN** arguments with special characters MUST be wrapped in double quotes (not single quotes)
- **AND** interior double quotes MUST be escaped by doubling them
- **WHEN** the target platform is Unix
- **THEN** arguments MUST be wrapped in single quotes with the standard `'\''` escape for interior single quotes

### REQ-WIN-TERMINAL: Prefer Windows Terminal for open_terminal

- **GIVEN** a terminal needs to be opened on Windows
- **WHEN** `open_terminal()` is called
- **THEN** it MUST try `wt.exe` first (Windows Terminal handles quoting correctly)
- **AND** fall back to `cmd /c start` only if `wt.exe` is not available

### REQ-WIN-WSL: WSL2 check in install script

- **GIVEN** the Windows install script is running
- **WHEN** WSL is not detected on the system
- **THEN** the script MUST attempt to install WSL2 via `wsl --install --no-distribution`
- **AND** set WSL2 as the default version via `wsl --set-default-version 2`
- **AND** warn the user that a reboot may be required

### REQ-WIN-ALIAS: tillandsias.exe alias

- **GIVEN** the NSIS installer writes `tillandsias-tray.exe` to the install directory
- **WHEN** `tillandsias.exe` does not exist in the install directory
- **THEN** the install script MUST copy `tillandsias-tray.exe` to `tillandsias.exe`
- **AND** use a file copy (not symlink) to avoid UAC/permission issues

### REQ-WIN-NOFLASH: CREATE_NO_WINDOW on background subprocesses

- **GIVEN** the tray app spawns background subprocesses (podman, bash)
- **WHEN** `Command::new()` is used for a subprocess that should not be user-visible
- **THEN** `creation_flags(0x08000000)` (CREATE_NO_WINDOW) MUST be set on Windows
- **AND** this MUST apply to `podman_cmd()`, `podman_cmd_sync()`, and build-image bash dispatch in handlers.rs
