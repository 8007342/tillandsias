## Context

Previous attempt removed terminal detection entirely, making tray "Attach Here" broken. The tray has no TTY so podman -it shows Bun help and exits. Detached mode leaves the user stranded.

## Decisions

### D1: Two-step launch from tray

1. `podman run -d --rm` — start container in background
2. Open platform terminal running `podman exec -it <name> /home/forge/entrypoint.sh`

The terminal provides the TTY. The entrypoint detects TTY → launches OpenCode.

### D2: Platform terminal (minimal, not a zoo)

Not trying to support every terminal. Just the platform default:
- Linux: try `ptyxis -- CMD`, then `gnome-terminal -- CMD`, then `xterm -e CMD`
- macOS: `open -a Terminal CMD` (always available)
- Windows: `cmd.exe /c start CMD` (always available)

One attempt per platform. If it fails, log the error.
