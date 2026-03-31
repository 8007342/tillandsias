## Why

Two bugs prevent normal CLI usage: (1) the OpenCode config file uses an invalid key name (`permissions` instead of `permission`) causing OpenCode to fail at startup with a settings error, and (2) the AppImage binary changes CWD to its FUSE mount point, so relative paths like `tillandsias .` resolve to the AppImage internals instead of the user's working directory.

## What Changes

- Fix `opencode.json` to use valid OpenCode config format (`permission` singular, tool-level controls)
- Resolve CLI path arguments against `$OWD` (Original Working Directory) when running as an AppImage, falling back to standard `canonicalize()` for non-AppImage contexts

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `cli-mode`: Path resolution must account for AppImage CWD override via `$OWD`
- `default-image`: OpenCode config must use valid `permission` key with tool-level format

## Impact

- `images/default/opencode.json` — config format change
- `src-tauri/src/cli.rs` or `src-tauri/src/runner.rs` — path resolution logic
- Embedded binary recompile (config is embedded via `include_str!`)
