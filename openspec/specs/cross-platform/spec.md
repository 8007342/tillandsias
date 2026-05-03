<!-- @trace spec:cross-platform -->
# Spec: Cross-Platform Windows Support (Delta)

## Status

status: suspended

## Requirements

### REQ-WIN-INSTALL: One-line Windows installer
The install script MUST force TLS 1.2, download the correct NSIS setup asset, run it silently, detect missing Podman CLI and install via winget, and initialize + start the podman machine.

### REQ-WIN-CRLF: CRLF-safe embedded scripts
All embedded scripts written to disk MUST have `\r` stripped before writing, so they execute correctly inside Linux containers when compiled on Windows with `core.autocrlf=true`.

### REQ-WIN-BASH: Shell script dispatch
All `.sh` script invocations via `Command::new()` MUST be dispatched through `bash` on Windows. Terminal launches for `.sh` files MUST use `bash` instead of `cmd /k`.

### REQ-WIN-MACHINE: Podman machine lifecycle
Both the tray app and CLI runner MUST check for an existing podman machine before starting one. If no machine exists, they MUST run `podman machine init` first, then `podman machine start`, with exponential backoff for readiness.

### REQ-WIN-MENU: Focus-safe menu rebuilds
Menu rebuilds MUST be skipped when menu-relevant state has not changed, to prevent window focus stealing on Windows and AppImage.

### REQ-WIN-I18N: Live language switching
Changing the language in the tray menu MUST reload the i18n string table immediately without requiring an app restart.

### REQ-WIN-OS: Host OS detection
`detect_host_os()` MUST return a meaningful string on Windows (e.g., "Microsoft Windows [Version 10.0.26200]") instead of "Unknown OS".

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:cross-platform" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
