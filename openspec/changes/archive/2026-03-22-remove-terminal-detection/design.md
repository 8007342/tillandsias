## Context

The current handler detects terminal emulators and spawns them with terminal-specific argument conventions. This broke on Silverblue (ptyxis wasn't in the list) and will break on every new platform/terminal combination. It's unnecessary complexity.

## Goals / Non-Goals

**Goals:**
- `podman run -it --rm` is the only interface — podman handles TTY allocation
- Works on any OS where podman runs
- Zero host dependencies beyond podman

**Non-Goals:**
- Terminal emulator compatibility
- GUI terminal windows
- Custom terminal themes or configurations

## Decisions

### D1: Spawn podman directly

Replace the terminal detection + spawn with a direct `std::process::Command::new("podman").args(run_args).spawn()`. The process inherits the parent's stdio when run from a terminal. When run from the tray (no parent terminal), podman allocates a PTY via `-it`.

For the tray case (no parent terminal), we spawn `podman run -it` detached — it gets its own TTY. The user interacts via the container's bash/opencode. On macOS/Windows, Podman Desktop provides the terminal interface.
