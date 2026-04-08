## Why

An audit of `#[allow(dead_code)]` annotations across `src-tauri/src/` found a mix of genuinely orphaned code, incorrectly suppressed warnings on used items, and planned-feature code that should remain. Left unchecked, dead code suppression masks real warnings and makes the codebase harder to audit.

Additionally, `log_format.rs` contains a placeholder `@trace spec:name https://...` in a comment that is not a valid trace — it should reference the actual spec governing that code (`logging-accountability`).

## What Changes

- **Remove genuinely dead code**: the `url` field in `GhRepoEntry` (deserialized but never read — serde ignores unknown fields by default) and the `version_full()` function in `cli.rs` (superseded by direct `VERSION_FULL.trim()` usage).
- **Remove incorrect suppression**: the `#[allow(dead_code)]` on `UpdateState` in `updater.rs` — the struct is actively used in `main.rs`.
- **Fix placeholder trace**: replace `@trace spec:name https://...` with `@trace spec:logging-accountability` pointing to the real spec.

## What Stays (and Why)

- `updater.rs::install_update` — Part of the active auto-updater feature, wired into Tauri's updater plugin. The tray menu item to trigger it is not yet connected but the infrastructure is real.
- `token_files.rs::read_token` and `is_tmpfs_available` — Part of the `fine-grained-pat-rotation` OpenSpec change. Will be used when token rotation is implemented.
- `update_cli.rs::PlatformEntry.signature` — Documents the expected JSON manifest shape. Removing it would hide the API contract.
- `embedded.rs::write_temp_script` — The `direct-podman-calls` OpenSpec change explicitly plans to address this function.

## Capabilities

### Modified Capabilities
- `logging-accountability`: Fix placeholder trace annotation in log formatter

## Impact

- **Modified files**: `github.rs`, `cli.rs`, `updater.rs`, `log_format.rs`
- **Risk**: Minimal — removing unused code and fixing a comment
- **User-visible change**: None
