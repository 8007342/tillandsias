## Context

Tillandsias currently uses Tauri (cross-platform WebKit + Rust) to provide the tray UI and manage the application lifecycle. This adds complexity for:
- Multi-platform build pipeline (macOS/Windows/Linux)
- WebKit dependency chain
- Auto-update mechanism (broken)
- Deployment (AppImage on Linux with embedded Ubuntu)

With the decision to use dedicated thin platform wrappers (macOS Virtualization.framework, Windows WSL2), the Linux tillandsias binary becomes the source of truth. The binary must:
1. Work in both headless (for wrappers) and tray (for native Linux) modes
2. Use portable musl-static linking (runs on any distro)
3. Have explicit app-lifecycle semantics (not daemon-like background service)
4. Handle container cleanup on exit via signal handling

## Goals / Non-Goals

**Goals:**
- Ship portable Linux binary (musl-static, works on Ubuntu/Arch/Fedora)
- Support `--headless` mode (app-lifecycle, no UI, controlled by wrapper or CLI)
- Optional GTK tray on Linux (separate subprocess, managed by main app)
- Clean exit semantics: SIGTERM → graceful container shutdown → cleanup → exit
- Same binary, transparent mode selection (tray vs headless)
- Remove Tauri, AppImage, embedded Ubuntu

**Non-Goals:**
- Cross-platform UI unification (separate native wrappers for macOS/Windows)
- Auto-update mechanism (handled by thin wrappers or package managers)
- Support for older distros (glibc < 2.31, kernel < 5.x) — musl-static but assume modern systems

## Decisions

### 1. Build Target: musl-static (x86_64-unknown-linux-musl)
**Rationale**: Maximum portability. glibc-linked binary has version mismatches across distros. musl-static has no libc dependency, runs anywhere.
**Alternative**: glibc-linked with min version detection. Rejected: adds version checking complexity, still breaks on older systems.
**Implementation**: `cargo build --release --target x86_64-unknown-linux-musl`, ensure all dependencies support musl (most do; FFI crates may need flags).

### 2. Headless App-Lifecycle (not daemon)
**Rationale**: User/wrapper launches tillandsias → containers start → user/wrapper closes tillandsias → containers stop + cleanup. This differs from daemon (start → background forever → kill). App-lifecycle is cleaner for resource management.
**Alternative**: True daemon mode with systemd service. Rejected: adds complexity, contradicts "thin wrapper" design (wrapper controls lifetime).
**Implementation**: `main.rs` exits normally after container cleanup; no detach-from-terminal. Systemd/wrapper can restart if needed.

### 3. Tray as Subprocess Manager
**Rationale**: Tray is a UI that manages the headless app lifecycle. When tray exits, headless exits. This is simpler than Tauri's integrated model.
**Alternative**: Single binary with UI via feature flag. Rejected: adds compile-time complexity, harder to test separately.
**Implementation**: Two binaries (or one with `--tray` flag):
- `tillandsias --headless` → headless, controlled by wrapper
- `tillandsias --tray` OR separate `tillandsias-tray` binary → spawns `tillandsias --headless`, forwards signals, renders GTK UI

### 4. Signal Handling: SIGTERM/SIGINT → Graceful Shutdown
**Rationale**: Containers need time to shut down cleanly (flush logs, wait for pending operations). 30-second timeout before SIGKILL.
**Implementation**: `signal-hook` crate, register SIGTERM/SIGINT handler, call `handlers::stop_all_containers()` (existing), wait for completion, exit. Tray subprocess relays signal to headless child.

### 5. Transparent Mode Selection
**Rationale**: User doesn't think about "headless vs tray" — they just run `tillandsias /path`. If tray is available, it auto-launches headless subprocess. On wrapper, just use `--headless`.
**Implementation**: `main()` detects `--headless` flag or env var; if not set and tray is available, re-exec self with `--headless` and spawn tray UI. If headless and no tray available, run as headless directly.

## Risks / Trade-offs

| Risk | Mitigation |
|------|-----------|
| **GTK not available on headless system** | Headless mode doesn't depend on GTK; tray is optional. If tray lib not found, log warning and continue headless. |
| **musl libc incompatibility with native libs** | Test with libseccomp, libssl. If FFI crate fails on musl, use native feature flags or glibc variant. |
| **30s shutdown timeout too short for large container** | Monitor actual shutdown times; increase to 60s if needed. Configurable via env var. |
| **Tray subprocess crash doesn't restart headless** | Headless is independent; if tray crashes, user can re-launch tray. Document this. |
| **Signal cascade: tray receives SIGTERM, must forward to headless** | Explicit signal forwarding in tray code; test with `kill -TERM` and verify containers stop. |

## Migration Plan

1. **Phase 1**: Branch off from current `src-tauri/` tree; keep Tauri build working during dev
2. **Phase 2**: Create new `src/main.rs` (no Tauri), headless + signal handling
3. **Phase 3**: Add GTK tray as separate binary or feature
4. **Phase 4**: Test musl-static build on Ubuntu/Arch/Fedora
5. **Phase 5**: Remove `src-tauri/`, `build-appimage.sh`, Tauri deps from `Cargo.toml`
6. **Release**: Linux binary ships as musl-static tarball; macOS/Windows thin wrappers follow (separate design)

**Rollback**: Keep `src-tauri/` branch for N releases; users can downgrade if needed.

## Open Questions

1. **GTK framework choice**: Use gtk4-rs (gtk4) or iced (cross-platform)? GTK4 is more native on Linux; iced is Rust-idiomatic. Recommend GTK4 for now, defer to future refactor.
2. **Tray protocol**: If tray and headless are separate processes, how do they communicate? (stdio, Unix socket, shared state file?) Recommend Unix socket for robustness.
3. **Versioning**: Should headless and tray be version-matched, or independent? Recommend matched (same binary version) for now.
4. **Minimal libc**: Can we use even smaller libc (uclibc, dietlibc)? Probably not worth it; musl is the sweet spot.

