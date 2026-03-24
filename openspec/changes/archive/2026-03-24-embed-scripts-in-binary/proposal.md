## Why

Currently `gh-auth-login.sh`, `build-image.sh`, `ensure-builder.sh`, and image source files (entrypoint, configs, flake) are copied to `~/.local/share/tillandsias/` at install time and executed from there. This is a supply chain risk: any process or user with write access to `~/.local/share/` can tamper with these scripts, and the signed Tillandsias binary will happily execute the modified versions. Scripts that touch credentials (`gh-auth-login.sh`) or build container images (`build-image.sh`) are especially sensitive.

## What Changes

- **Embed `gh-auth-login.sh`** in the Rust binary via `include_str!`. At runtime, write to a temp file in `$XDG_RUNTIME_DIR` (RAM-backed, per-session), execute, then delete. No persistent userspace script.
- **Embed image source files** (entrypoint.sh, shell configs, skill files, flake.nix, flake.lock) in the binary. Write them to temp at image build time, clean up after.
- **Remove userspace script installation** from `build.sh --install`. The binary is self-contained.
- **Remove userspace script lookup** from `handlers.rs` and `runner.rs`. Scripts come from the binary, not the filesystem.

## Capabilities

### New Capabilities
- `embedded-scripts`: All executable scripts and image sources embedded in the signed binary via `include_str!`/`include_bytes!`, written to temp at runtime

### Modified Capabilities
- `dev-build`: `build.sh --install` no longer copies scripts/images to `~/.local/share/`
- `tray-app`: GitHub Login and image build use embedded scripts from the binary

## Impact

- **New file**: `src-tauri/src/embedded.rs` — module with embedded script content and temp-file write helpers
- **Modified files**: `handlers.rs` (use embedded gh-auth-login), `runner.rs` (use embedded build-image), `build.sh` (remove script installation)
- **Removed from install**: `~/.local/share/tillandsias/scripts/`, `~/.local/share/tillandsias/gh-auth-login.sh`, `~/.local/share/tillandsias/flake.nix`, `~/.local/share/tillandsias/flake.lock`, `~/.local/share/tillandsias/images/`
- **Kept in install**: icons (cosmetic, not executable), wrapper binary
