## Why

A thorough audit of all user-facing strings across the Rust tray app, CLI commands, shell scripts, and installer reveals multiple bugs and inconsistencies. The most severe is a word-doubling bug where tray menu build chips display "Building Building Forge..." because `build_chip_label()` prepends "Building" to image names that already contain the word "Building". There are also formatting inconsistencies (mixed checkmark styles), duplicated error message strings copy-pasted across 15+ locations, and shell script status messages that lack any progress indicator.

## What Changes

- **Fix "Building Building" bug** in `build_chip_label()` / the chip image names sent by `main.rs`
- **Normalize checkmark/cross-mark styles** across `init.rs`, `runner.rs`, `cleanup.rs`, `update_cli.rs`
- **Extract repeated error strings** into named constants (the "Tillandsias is setting up..." message appears in 15+ locations)
- **Fix entrypoint.sh "done" prefix inconsistency** where install status messages use bare "done" instead of a checkmark
- **Fix cleanup.rs alignment bug** where "Installed binary:" has a missing space before the path
- **Normalize the reinstall URL** string that is duplicated across `handlers.rs`, `runner.rs`, `init.rs`

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `tray-app`: Build chip labels display correctly without word doubling
- `cli-mode`: Consistent formatting for checkmarks, error messages, and status indicators
- `environment-runtime`: Entrypoint messages use consistent formatting

## Impact

- **Modified files**: `src-tauri/src/menu.rs`, `src-tauri/src/main.rs`, `src-tauri/src/handlers.rs`, `src-tauri/src/init.rs`, `src-tauri/src/runner.rs`, `src-tauri/src/cleanup.rs`, `src-tauri/src/update_cli.rs`, `images/default/entrypoint.sh`
- **New files**: Possibly a `src-tauri/src/strings.rs` module for shared constants
- **Risk**: Low -- string-only changes, no logic changes
