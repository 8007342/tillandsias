# Tasks — fix-macos-platform-defaults

- [x] 1. `build_lock.rs`: Add `#[cfg(target_os)]` split for `is_alive()` — use `ps` on macOS, `/proc` on Linux
- [x] 2. `cleanup.rs`: Replace `du -sb` with pure-Rust recursive `dir_size_bytes()`
- [x] 3. `cleanup.rs`: Use `tillandsias_core::config::cache_dir()` and platform-aware binary path
- [x] 4. `uninstall.sh`: Add Darwin detection for `LIB_DIR` and `DATA_DIR`
- [x] 5. `gh-auth-login.sh`: Add Darwin detection for `DATA_DIR`
- [x] 6. `claude-api-key-prompt.sh`: Use `$TMPDIR` on macOS for temp key file
- [x] 7. `handlers.rs`: Use `std::env::temp_dir()` instead of `XDG_RUNTIME_DIR` with `/tmp` fallback
- [x] 8. Run `cargo test --workspace` to verify no regressions
