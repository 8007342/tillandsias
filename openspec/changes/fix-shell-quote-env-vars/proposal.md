## Why

Container launches from the tray fail on macOS 26+ because the `TILLANDSIAS_HOST_OS` env var value contains a space (`macOS 26.4`). When podman args are joined into a shell command string for `open_terminal()`, the space splits the value — podman interprets `26.4` as a separate image name argument and tries to pull `docker.io/library/26.4:latest`.

This only manifests when the OS version string contains a space, which is always the case on macOS (e.g., "macOS 26.4") and common on Linux (e.g., "Fedora Silverblue 43").

## What Changes

- Add `shell_quote()` and `join_shell_args()` helpers in `handlers.rs` that single-quote any argument containing whitespace
- Replace all three `podman_parts.join(" ")` calls with `join_shell_args(&podman_parts)`
- Fix debug display in `runner.rs` to also quote args with spaces

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- Container launch: env var values with spaces are now correctly shell-quoted when building terminal commands

## Impact

- `src-tauri/src/handlers.rs` — shell quoting helpers + 3 join sites fixed
- `src-tauri/src/runner.rs` — debug display quoting
