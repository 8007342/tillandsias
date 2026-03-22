## Why

Tillandsias currently only works as a system tray application. Users who prefer the terminal or want to script container launches have no way to attach to a project from the command line. Adding a CLI mode lets users run `tillandsias ~/src/my-project` to launch an interactive container directly, with user-friendly output instead of raw tracing logs.

This also enables CI/CD pipelines, shell aliases, and integration with editor "run in container" workflows.

## What Changes

- **New `cli` module** in `src-tauri/src/cli.rs` — parses CLI args and returns either `Tray` or `Attach` mode
- **New `runner` module** in `src-tauri/src/runner.rs` — the CLI container runner with pretty `println!` output (image check, build progress, container details, Ctrl+C hint)
- **Updated `main.rs`** — branches on CLI mode at startup: `Tray` proceeds to tray app, `Attach` calls the runner and exits
- **New `run-tillandsia.sh`** dev helper script at project root

## Capabilities

### New Capabilities
- `cli-mode`: CLI interface for launching containers from the terminal

### Modified Capabilities
- `environment-runtime`: Alternate entry point via CLI in addition to tray menu

## Impact

- New files: `src-tauri/src/cli.rs`, `src-tauri/src/runner.rs`, `run-tillandsia.sh`
- Modified: `src-tauri/src/main.rs` (add CLI dispatch at top of main)
- No changes to existing tray logic — CLI mode bypasses the entire tray/Tauri stack
