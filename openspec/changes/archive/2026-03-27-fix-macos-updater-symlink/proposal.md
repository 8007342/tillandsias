## Why

The Tauri auto-updater fails on macOS when the app is launched via a symlink at `~/.local/bin/tillandsias` pointing to `~/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray`. Tauri's `StartingBinary` (from `tauri-utils`) uses a `#[ctor]` static that calls `std::env::current_exe()` and rejects any path containing a symlink on macOS, producing:

```
StartingBinary found current_exe() that contains a symlink on a non-allowed platform
```

This prevents the updater from initializing at all.

## What Changes

Enable the `process-relaunch-dangerous-allow-symlink-macos` feature flag on the `tauri` dependency. Despite the "dangerous" name, the `StartingBinary` code canonicalizes the path after the symlink check, so the updater will still resolve through to the real `.app` bundle path. The symlink itself is intentional (installed by `--install` mode for CLI access).

## Capabilities

### Modified Capabilities
- `auto-updater`: Works correctly when launched via symlink on macOS

## Impact

- **Modified files**: `src-tauri/Cargo.toml`
- **Risk**: Low. The feature flag only skips the symlink rejection check; path canonicalization still occurs, so the updater resolves to the real `.app` bundle.
