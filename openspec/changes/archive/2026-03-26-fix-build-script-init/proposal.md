## Why

`./build.sh --appimage` uses `podman run --rm` (ephemeral container) so Rust, tauri-cli, and system deps are reinstalled from scratch every build (~10 min). Only the cargo registry was cached. Subsequent builds should be fast.

## What Changes

- Cache rustup, cargo bin, and apt packages across builds via additional volume mounts
- Skip Rust install if `~/.cargo/bin/rustup` exists in cache
- Skip tauri-cli install if `cargo-tauri` binary exists in cache
- First build: same ~10 min (installs everything, populates caches)
- Subsequent builds: ~1-2 min (all tools cached, only compiles)

## Capabilities

### New Capabilities
### Modified Capabilities

## Impact

- **Modified file**: `build.sh` — `build_appimage()` function, additional volume mounts and skip-if-cached guards
- **New cache dirs**: `~/.cache/tillandsias/appimage-builder/{cargo-registry,cargo-bin,rustup,apt}`
