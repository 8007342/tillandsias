## Why

`gh-auth-login.sh` hardcodes `CACHE_DIR="${HOME}/.cache/tillandsias"`. On macOS, the Rust code uses `~/Library/Caches/tillandsias` (via `dirs::cache_dir()`). This means auth credentials get written to the wrong directory and containers mount empty dirs, breaking GitHub authentication on macOS.

The same issue exists in `build-osx.sh` (macOS-only script using Linux path) and `scripts/uninstall.sh` (cross-platform script using only the Linux path).

## What Changes

- **`gh-auth-login.sh`** — Replace hardcoded `CACHE_DIR` with platform detection (`uname -s` check)
- **`build-osx.sh`** — Use macOS-native `~/Library/Caches/tillandsias` path (this script only runs on macOS)
- **`scripts/uninstall.sh`** — Add platform detection so `--wipe` cleans the correct cache directory

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- Shell scripts respect platform-specific cache directories, matching the Rust code's use of `dirs::cache_dir()`

## Risks

- Low risk. The fix is a simple conditional path assignment.
- `build.sh` and `build-windows.sh` are Linux-only (toolbox) so their `~/.cache` paths are correct and unchanged.
- `images/default/entrypoint.sh` runs inside a Linux container, so its path is correct and unchanged.
- `scripts/build-image.sh` already has platform detection.
