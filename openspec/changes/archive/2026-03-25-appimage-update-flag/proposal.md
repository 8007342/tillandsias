## Why

The tray app silently checks for updates in the background, but there is no way for a user or script to trigger an update check from the command line. Power users and automation scripts need a way to invoke `tillandsias --update` and get a clear, machine-readable report of what happened: current version, whether an update is available, and whether the update was applied.

The Tauri updater plugin is already wired into the tray app. However, it requires the full Tauri event loop to be running, which is expensive to spin up just for a version check. A CLI-only approach — fetching `latest.json` directly over HTTPS, comparing versions, and applying if needed — gives a fast, dependency-light update path that exits after completion.

## What Changes

- **`--update` CLI flag** — New `CliMode::Update` variant parsed in `src-tauri/src/cli.rs`
- **`src-tauri/src/update_cli.rs`** — New module implementing the CLI update flow: fetch latest.json, compare versions, download+install if newer, print human-readable status, exit
- **Help text** — `tillandsias --update` line added to the USAGE string in `cli.rs`
- **`main.rs` dispatch** — Handles `CliMode::Update` before the Tauri event loop starts

## Capabilities

### New Capabilities
- `appimage-update-flag`: CLI-driven update check and self-update — `tillandsias --update` prints current version, checks the configured update endpoint, downloads and applies any available update with human-readable progress output, exits with code 0 (up-to-date or updated) or 1 (error)

### Modified Capabilities
- `cli-mode`: New `Update` variant added alongside existing `Tray`, `Init`, `Stats`, `Clean`, `Attach`

## Impact

- **New file**: `src-tauri/src/update_cli.rs`
- **Modified files**: `src-tauri/src/cli.rs` (new variant + help text), `src-tauri/src/main.rs` (dispatch)
- **No Tauri event loop**: The `--update` path uses `reqwest` (already transitively available via tauri-plugin-updater) or stdlib HTTP to fetch `latest.json` directly — no `tauri::Builder` is constructed
- **Exit codes**: 0 = success (up-to-date or update applied), 1 = error (network failure, signature mismatch, etc.)
