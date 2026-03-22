## Why

Terminal emulator detection is brittle, platform-specific, and a non-goal. Supporting ptyxis, gnome-terminal, konsole, alacritty, kitty, foot, xterm, etc. across Linux/macOS/Windows is impossible to maintain. The container has bash. `podman run -it` provides a TTY. That's all we need.

## What Changes

- Remove `detect_terminal()` and `spawn_terminal()` from handlers.rs
- "Attach Here" runs `podman run -it --rm` directly as a spawned process — podman handles the TTY
- The container's entrypoint (bash → opencode) is the user's interface
- No host terminal emulator dependency at all

## Capabilities

### Modified Capabilities
- `environment-runtime`: Remove terminal emulator dependency, use podman run -it directly

## Impact

- Simplified handlers.rs (remove ~50 lines of terminal detection)
- Works on any platform where podman exists — no terminal algebra
- Container must have bash (already does — Fedora Minimal base)
