## Why

Developers need a single `./build.sh` entry point that handles the full local development lifecycle — build, install, clean, remove, wipe — without knowing about toolbox internals, Tauri CLI setup, or system dependency installation. The script must auto-create the tillandsias toolbox if it doesn't exist, so a fresh checkout on any Fedora Silverblue machine works immediately.

## What Changes

- New `build.sh` at project root with flags: `--clean`, `--install`, `--remove`, `--wipe`, `--test`, `--release`
- Auto-creates `tillandsias` toolbox with all build dependencies if missing
- Installs `tauri-cli` inside the toolbox if needed
- Copies built binary to `~/.local/bin/` on `--install`
- All cargo/tauri commands run inside the toolbox transparently

## Capabilities

### New Capabilities
- `dev-build`: Development build script with toolbox lifecycle management

### Modified Capabilities

## Impact

- New file: `build.sh` (executable)
- Documents the canonical dev workflow in CLAUDE.md
- No Rust code changes
