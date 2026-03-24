## Why

Running `tillandsias` multiple times (e.g. from desktop launcher, autostart, and terminal) spawns duplicate tray icons with independent state. Each instance starts its own scanner, podman event stream, and event loop — wasting resources and confusing the user with multiple identical menus.

## What Changes

- **Singleton enforcement**: On startup, check if another Tillandsias instance is already running. If alive, exit silently. If the previous instance is dead (stale lock), take over.
- **PID lock file**: Write a lock file with the current PID at startup, validate it on subsequent launches, clean it up on graceful exit.

## Capabilities

### New Capabilities
- `singleton-guard`: Process-level singleton enforcement using a PID lock file, preventing duplicate tray instances

### Modified Capabilities
- `tray-app`: Add requirement that only one tray instance may be active at a time

## Impact

- **Modified files**: `src-tauri/src/main.rs` (add singleton check before Tauri builder)
- **New file**: `src-tauri/src/singleton.rs` (lock file management)
- **Lock file location**: `$XDG_RUNTIME_DIR/tillandsias.lock` (Linux), platform-appropriate for macOS/Windows
- **No new dependencies**: Uses `std::fs` and `/proc` (Linux) or platform equivalents for PID validation
