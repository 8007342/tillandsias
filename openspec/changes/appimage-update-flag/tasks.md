## 1. CLI Changes

- [x] 1.1 Add `Update` variant to `CliMode` enum in `src-tauri/src/cli.rs`
- [x] 1.2 Parse `--update` flag before the positional-arg loop in `cli::parse()`
- [x] 1.3 Add `tillandsias --update` line to the USAGE help text

## 2. Update CLI Module

- [x] 2.1 Create `src-tauri/src/update_cli.rs` with `run()` function
- [x] 2.2 Print current version from `env!("CARGO_PKG_VERSION")`
- [x] 2.3 Fetch latest.json from the configured endpoint (read from tauri.conf.json at compile time or hardcoded constant)
- [x] 2.4 Parse `version` field from latest.json response
- [x] 2.5 Compare fetched version with current version; print "Already up to date." or "Update available: vX.Y.Z"
- [x] 2.6 If update available: download update artifact, log download progress (bytes received), apply update
- [x] 2.7 Print "Restart the application to use the new version." after successful apply
- [x] 2.8 Return `bool` (true = success) for `main.rs` exit-code dispatch

## 3. Main Dispatch

- [x] 3.1 Handle `CliMode::Update` in `main.rs` before any Tauri builder code
- [x] 3.2 Exit with code 0 on success, 1 on error

## 4. Verification

- [x] 4.1 `cargo check --workspace` passes
- [ ] 4.2 Run `tillandsias --update` manually against live endpoint — verify "Already up to date." path
- [ ] 4.3 Confirm `tillandsias --help` shows `--update` flag
