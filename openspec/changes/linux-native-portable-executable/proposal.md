## Why

Tauri introduces cross-platform complexity (WebKit, multi-platform build, auto-update) that doesn't align with Tillandsias' multi-platform strategy. With dedicated thin wrappers for macOS (Virtualization.framework) and Windows (WSL2), the Linux tillandsias headless launcher should be the lifecycle source of truth: launch -> resources live -> exit -> full cleanup. Removing Tauri/AppImage simplifies the stack and enables clean signal handling for container lifecycle management.

## What Changes

- **Remove**: Tauri framework (WebKit UI, cross-platform build), AppImage bundling, embedded Ubuntu container dependency
- **Add**: musl-static Linux headless launcher (portable across distro while pure Rust), `--headless` mode (app-lifecycle, no UI), native GTK tray as separate platform-native subprocess
- **Modify**: Signal handling (SIGTERM/SIGINT → graceful container shutdown), process lifecycle (tray/headless are apps, not daemons, full cleanup on exit)
- **BREAKING**: macOS/Windows no longer run Tauri; they deploy dedicated thin wrappers that manage virtualized Fedora 44 and run headless tillandsias inside

## Capabilities

### New Capabilities
- `linux-headless-app-lifecycle`: Launch tillandsias with `--headless` flag; containers live while app runs; full cleanup (secrets, networks, containers) on exit. Not a daemon — has application lifecycle semantics.
- `linux-tray-subprocess-manager`: GTK tray application that spawns headless tillandsias subprocess; tray exit cascades to headless exit; transparent to user
- `portable-linux-executable`: musl-static headless launcher (x86_64-unknown-linux-musl target) runs on Ubuntu, Arch, Fedora, etc without system library dependencies while tray/native-library surfaces use platform-native builds
- `clean-app-exit-semantics`: SIGTERM/SIGINT → graceful container stop, enclave network teardown, podman secrets cleanup, no orphaned resources

### Modified Capabilities
- `podman-orchestration`: Signal handling now explicit — app receives SIGTERM, containers get 30s graceful shutdown, then SIGKILL if needed
- `secrets-management`: Secrets cleaned up on app exit (lifecycle-scoped, not persistent)
- `enclave-network`: Network cleanup triggered by app exit signal, not lingering

## Impact

**Code changes**:
- Remove: `src-tauri/` directory (Tauri app layer)
- Remove: `scripts/appimage/`, `build-appimage.sh`
- Modify: `src-tauri/src/main.rs` → `src/main.rs` (no Tauri, pure CLI + signal handler)
- Add: `src/tray/` (optional GTK tray subprocess)
- Add: `Cargo.toml` with musl target for the headless launcher, signal handling crates

**Dependencies removed**: tauri, tauri-build, webkit (indirect), wry (indirect)

**Dependencies added**: signal-hook, tokio-util (signal handling), gtk4 (optional for tray)

**Build changes**: `cargo build --release --target x86_64-unknown-linux-musl` replaces the default Tauri/AppImage path for the headless launcher

**Deliverables**: 
- Linux headless binary (primary)
- Linux tray binary (optional)
- macOS thin wrapper (pending design)
- Windows thin wrapper (pending design)
