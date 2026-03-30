## Why

When `--update` runs or the background auto-updater applies a patch, there is no record of what happened. Users and developers have no way to confirm whether an update succeeded, what version was installed, or when the last check occurred. After the process exits, all context is gone. A persistent audit log closes this gap — it's a plain text file that accumulates entries over time so anyone can verify the update history without relying on memory or running the app again.

## What Changes

- **Update log file** at `~/.cache/tillandsias/update.log` (cross-platform via `cache_dir()`). Append-only, human-readable, timestamped entries with RFC 3339 timestamps.
- **`update_cli.rs`** — log check result (available or up-to-date), download size + URL, apply with old→new version + binary path + SHA256, and errors.
- **`updater.rs`** — log when the background auto-updater detects an available version and when it successfully installs.
- **`cleanup.rs`** — `--stats` output gains a "Last update" line read from the tail of `update.log`.
- **Log rotation** — if `update.log` exceeds 1 MB, it is truncated to the last 100 lines before writing the next entry, keeping history bounded.

## Capabilities

### New Capabilities
- `update-audit-logging`: Persistent log of all update check and apply events at `~/.cache/tillandsias/update.log`

### Modified Capabilities
- `update-system`: `--update` flow and background auto-updater both write to the audit log
- `cli-mode`: `--stats` shows the last update entry from `update.log`

## Impact

- **New file**: `src-tauri/src/update_log.rs` — shared module for log path, append, rotate, and read-last-entry helpers
- **Modified files**: `src-tauri/src/update_cli.rs`, `src-tauri/src/updater.rs`, `src-tauri/src/cleanup.rs`, `src-tauri/Cargo.toml` (add `sha2`, `hex`)
- **New runtime artifact**: `~/.cache/tillandsias/update.log` (created on first update event, never by install)
- **User-visible change**: `--stats` shows "Last update: [timestamp] APPLIED v0.1.90 → v0.1.97" (or "never" if no log exists)
