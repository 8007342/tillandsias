## Why

Tillandsias now needs to build and run on macOS (Apple Silicon). The existing `build.sh` uses Fedora toolbox which doesn't exist on macOS, and `build-windows.sh` cross-compiles from Linux. There's no native macOS build path. Additionally, `install.sh` downloads a `.dmg` on macOS but never mounts/extracts it — it prints "Installed to ~/.local/bin/tillandsias" but the binary doesn't exist, and then tries to `cp` from that nonexistent path to create a `.app` bundle.

## What Changes

- New `build-osx.sh` at project root — native macOS build script (debug, release, test, check, install, remove, wipe)
- Fix `scripts/install.sh` — mount .dmg, extract .app to ~/Applications/, create CLI symlink
- Update CLAUDE.md with build-osx.sh usage

## Capabilities

### New Capabilities
- `macos-build`: Native macOS build script with release .dmg bundling and ~/Applications/ install

### Modified Capabilities
- `installer`: Fixed macOS .dmg extraction — properly mounts, copies .app, creates CLI symlink

## Impact

- New file: `build-osx.sh` (executable)
- Modified file: `scripts/install.sh` (macOS section rewritten)
- Modified file: `CLAUDE.md` (build commands section)
- No Rust code changes
