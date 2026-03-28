## 1. Enable symlink feature flag

- [x] 1.1 Add `process-relaunch-dangerous-allow-symlink-macos` feature to `tauri` dependency in `src-tauri/Cargo.toml`

## 2. Verification

- [x] 2.1 `cargo test --workspace` passes (96 tests, 0 failures)
- [x] 2.2 `cargo check` passes with the new feature
