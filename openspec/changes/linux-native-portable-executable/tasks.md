## 1. Setup & Build Configuration

- [x] 1.1 Create `src/main.rs` scaffolding (no Tauri)
- [x] 1.2 Add musl target to `Cargo.toml`: `[profile.release] lto = true`
- [x] 1.3 Verify musl dependencies: ensure signal-hook, tokio-util are available for musl
- [x] 1.4 Update build.sh to include `--target x86_64-unknown-linux-musl` flag
- [x] 1.5 Create `.cargo/config.toml` with musl optimization flags

## 2. Headless Core Implementation

- [x] 2.1 Refactor `src-tauri/src/main.rs` logic to `src/main.rs` (remove Tauri initialization)
- [x] 2.2 Implement `--headless` CLI flag parsing (clap or manual)
- [x] 2.3 Implement signal handler registration: SIGTERM, SIGINT → graceful_shutdown()
- [x] 2.4 Implement graceful_shutdown(): call handlers::stop_all_containers(30s timeout), cleanup secrets, teardown enclave network
- [x] 2.5 Implement JSON state output: `event: "app.started"` at launch, `event: "app.stopped"` at exit
- [x] 2.6 Test headless mode: `cargo run -- --headless /tmp/test-project` should start, receive SIGTERM, cleanup gracefully

## 3. Transparent Mode Detection

- [x] 3.1 Implement main() auto-detection: if `--headless` not set AND tray available, re-exec self with `--headless` + spawn tray UI
- [x] 3.2 Add `--tray` flag support (or separate binary `tillandsias-tray`)
- [x] 3.3 Test transparent mode: `cargo run -- /tmp/test-project` should auto-launch tray (if available) managing headless subprocess

## 4. GTK Tray Implementation

- [x] 4.1 Add gtk4-rs dependency to Cargo.toml (optional feature: `[features] tray = ["gtk4"]`)
- [x] 4.2 Create `src/tray/mod.rs`: spawn headless subprocess via Command::new()
- [x] 4.3 Implement tray subprocess lifecycle: forward SIGTERM/SIGINT to child, wait for exit
- [x] 4.4 Implement GTK window: show project status, container list, log viewer
- [x] 4.5 Implement tray icon: system tray integration (libadwaita or gtk4-native)
- [x] 4.6 Test tray: close window should SIGTERM headless, verify containers stop

## 5. Signal Handling & Container Lifecycle

- [x] 5.1 Update `handlers.rs`: ensure stop_all_containers() returns Result<()> for async shutdown
- [x] 5.2 Implement signal-hook integration: register handlers, set up channel for SIGTERM/SIGINT
- [x] 5.3 Test signal handling: send SIGTERM via `kill -TERM`, verify containers stop within 30s
- [x] 5.4 Test SIGKILL fallback: if container doesn't stop in 30s, send SIGKILL, verify exit

## 6. Secrets Cleanup

- [ ] 6.1 Update `handlers::cleanup_all_secrets()` to be called on app exit
- [ ] 6.2 Verify podman secrets tillandsias-* are deleted on SIGTERM
- [ ] 6.3 Add test: check `podman secret ls` after app exit is empty

## 7. musl Build & Testing

- [ ] 7.1 Build musl binary: `cargo build --release --target x86_64-unknown-linux-musl`
- [ ] 7.2 Verify binary is statically linked: `ldd ./target/x86_64-unknown-linux-musl/release/tillandsias` should show "not a dynamic executable"
- [ ] 7.3 Test on Ubuntu 22.04: copy binary, run `tillandsias --headless`, verify containers start
- [ ] 7.4 Test on Arch Linux: repeat with musl binary
- [ ] 7.5 Test on Fedora: repeat with musl binary
- [ ] 7.6 Test portability: run musl binary on system without glibc-devel

## 8. Cleanup & Dependency Removal

- [ ] 8.1 Remove `src-tauri/` directory (keep in git history, don't delete)
- [ ] 8.2 Remove `tauri`, `tauri-build`, `webkit2gtk` from Cargo.toml
- [ ] 8.3 Remove `build-appimage.sh`, `scripts/appimage/` directory
- [ ] 8.4 Remove embedded Ubuntu container references from build scripts
- [ ] 8.5 Update `build.sh`: remove Tauri bundle step, only build musl binary

## 9. Testing & Verification

- [ ] 9.1 Run `cargo test --workspace` with musl target
- [ ] 9.2 Run litmus test chain: `./build-git.sh && tillandsias --headless /tmp/test-project`
- [ ] 9.3 Verify all containers start and stop cleanly
- [ ] 9.4 Verify no orphaned containers remain after app exit
- [ ] 9.5 Test signal handling with `kill -TERM` and `kill -INT`

## 10. Documentation & Release

- [ ] 10.1 Update CLAUDE.md: remove Tauri references, document `--headless` mode
- [ ] 10.2 Update README: new build command (`cargo build --release --target x86_64-unknown-linux-musl`)
- [ ] 10.3 Create release notes: Tauri removal, musl portability, headless mode for wrappers
- [ ] 10.4 Tag version: `v0.1.X.Y` with musl build in releases

