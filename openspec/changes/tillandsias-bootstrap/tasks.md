## 1. Workspace Scaffolding

- [x] 1.1 Initialize Rust workspace with `Cargo.toml` (resolver 2024, edition 2024) and four crate directories: `crates/tillandsias-core/`, `crates/tillandsias-scanner/`, `crates/tillandsias-podman/`, `crates/tillandsias-tray/`
- [x] 1.2 Set up `tillandsias-core` crate with shared types: `AppEvent` enum, `Project` struct, `ContainerState` enum, `TrayState` struct, config types with serde derives
- [x] 1.3 Set up `tillandsias-tray` as the binary crate with Tauri v2 dependencies (`tauri` with `tray-icon` feature, `tauri-plugin-shell`, `tokio`, `serde`)
- [x] 1.4 Create `src-tauri/` Tauri build context with `tauri.conf.json` (tray-only, `windows: []`, identifier `com.tillandsias.tray`), `build.rs`, and minimal `icons/` directory
- [x] 1.5 Add workspace-level dependencies in root `Cargo.toml`: `tokio`, `serde`, `postcard`, `notify`, `toml`, `tracing`
- [x] 1.6 Verify the workspace builds and `cargo test --workspace` passes with zero tests

## 2. Core Types and Configuration

- [x] 2.1 Define the `AppEvent` enum in `tillandsias-core`: `FilesystemChange`, `ContainerStateChange`, `MenuAction`, `Shutdown`
- [x] 2.2 Define `Project` struct: name, path, detected type (Node/Rust/Python/Go/Unknown), artifact status (has Containerfile, has runtime config), assigned genus
- [x] 2.3 Define `ContainerInfo` struct: name, project, genus, state (Creating/Running/Stopping/Stopped), assigned port range
- [x] 2.4 Define `TrayState` struct: `Vec<Project>`, `Vec<ContainerInfo>`, `PlatformInfo`
- [x] 2.5 Implement two-level config loading: global `~/.config/tillandsias/config.toml` (platform-aware path via `dirs` crate) merged with per-project `.tillandsias/config.toml`, falling back to built-in defaults
- [x] 2.6 Define config structs with serde: `GlobalConfig` (scanner watch paths, default image, port range, security flags), `ProjectConfig` (image override, port range override, custom mounts)
- [x] 2.7 Add `postcard` serialization for internal state snapshots (serialize/deserialize round-trip tests)
- [x] 2.8 Write unit tests for config merging (global-only, per-project override, no config defaults, security flags cannot be weakened)

## 3. Tillandsia Genus System

- [x] 3.1 Define `TillandsiaGenus` enum with 8 MVP variants: Aeranthos, Ionantha, Xerographica, CaputMedusae, Bulbosa, Tectorum, Stricta, Usneoides
- [x] 3.2 Define `PlantLifecycle` enum: Bud, Bloom, Dried, Pup — mapped to container states (Creating→Bud, Running→Bloom, Stopping→Dried, Rebuilding→Pup)
- [x] 3.3 Implement genus pool allocator: round-robin assignment, tracks which genera are in use per project, returns different genus for concurrent environments of the same project
- [x] 3.4 Create `assets/icons/` directory structure: `<genus>/<state>.svg` (8 genera × 4 states = 32 SVG files)
- [x] 3.5 Generate initial abstract SVG icons: simple geometric tillandsia silhouettes with distinct shapes per genus and color variants per lifecycle state (bud=green, bloom=colorful, dried=brown, pup=light green)
- [x] 3.6 Implement icon loader that maps `(TillandsiaGenus, PlantLifecycle)` → SVG bytes, embedded as compile-time assets via `include_bytes!`
- [x] 3.7 Write unit tests for genus allocation (round-robin, no duplicate genera for same project, pool exhaustion behavior)

## 4. Filesystem Scanner

- [x] 4.1 Create `tillandsias-scanner` crate with `notify` dependency and `tokio` channels
- [x] 4.2 Implement `ScannerConfig`: watch paths (default `~/src`), debounce duration (default 2000ms), max depth (2)
- [x] 4.3 Implement async watcher setup using `notify::RecommendedWatcher` with `tokio::sync::mpsc` bridge — OS-native events (inotify/kqueue/ReadDirectoryChangesW), zero CPU when idle
- [x] 4.4 Implement debounce layer: accumulate filesystem events over the configurable window, batch into a single `ProjectChange` event per affected project
- [x] 4.5 Implement project detection heuristics (priority order): `.tillandsias/config.toml` → `Containerfile`/`Dockerfile` → `package.json`/`Cargo.toml`/`pyproject.toml`/`go.mod`/`flake.nix` → generic non-empty directory
- [x] 4.6 Implement artifact presence detection: scan for `Containerfile`, `Dockerfile`, `flake.nix`, `.tillandsias/config.toml` with `[runtime]` section
- [x] 4.7 Ensure scanner runs as a low-priority tokio task that emits `AppEvent::FilesystemChange` without blocking the main loop
- [x] 4.8 Write unit tests for project detection heuristics (each marker type, priority ordering, empty directories)
- [x] 4.9 Write integration test: create temp directory, add/remove project markers, verify events are emitted after debounce

## 5. Podman Orchestration

- [x] 5.1 Create `tillandsias-podman` crate with `tokio::process` for async command execution
- [x] 5.2 Implement `PodmanClient` struct with async methods: `start_container`, `stop_container`, `destroy_container`, `inspect_container`, `list_containers`, `image_exists`, `pull_image`
- [x] 5.3 All podman CLI calls MUST use `--format json` for output parsing and `tokio::process::Command` for non-blocking execution
- [x] 5.4 Implement security-hardened container launch: assemble podman run arguments with non-negotiable flags (`--rm`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--security-opt=label=disable`)
- [x] 5.5 Implement GPU passthrough detection: scan for NVIDIA devices (`/dev/nvidia*`) and AMD ROCm devices (`/dev/kfd`, `/dev/dri/renderD*`), append `--device=` flags when found, silent when absent
- [x] 5.6 Implement volume mount assembly: project dir → container workspace (rw), cache dir → container cache, shared Nix cache, plus any per-project custom mounts
- [x] 5.7 Implement container naming with tillandsia namespace: `tillandsias-<project>-<genus>`
- [x] 5.8 Implement port range allocation: default 3000-3099, auto-increment for concurrent environments (3100-3199, etc.), per-project override support
- [x] 5.9 Implement event-driven container status via `podman events --format json` as long-running async subprocess feeding `AppEvent::ContainerStateChange`
- [x] 5.10 Implement exponential backoff fallback for when `podman events` is unavailable (Podman Machine on macOS/Windows): start at 1s, double to 30s max, reconnect on recovery, NEVER fixed-interval polling
- [x] 5.11 Implement Podman Machine detection for macOS/Windows: check `podman machine list`, surface non-technical message if not running
- [x] 5.12 Implement graceful stop: SIGTERM → 10s grace period → SIGKILL, wrapped in async timeout
- [x] 5.13 Implement container discovery on startup: list running containers with `tillandsias-` prefix, parse genus from name suffix, reconstruct state
- [x] 5.14 Write unit tests for: argument assembly (security flags always present, GPU flags conditional), container naming, port allocation
- [x] 5.15 Write integration test (requires podman): start/stop/inspect cycle with a minimal alpine container

## 6. Tray Application

- [x] 6.1 Implement Tauri v2 app setup in `tillandsias-tray`: `tauri::Builder` with tray-only config, no windows
- [x] 6.2 Implement `TrayIconBuilder` setup with tooltip "Tillandsias" and initial idle icon
- [x] 6.3 Implement dynamic menu builder: takes `TrayState`, produces hierarchical menu with project tree (watch path → projects → Attach Here/Start/Stop) and running environments section with genus icons
- [x] 6.4 Implement menu event handler dispatching `AppEvent::MenuAction` for: Attach Here, Start, Stop, Destroy, Settings, Quit
- [x] 6.5 Implement main event loop using `tokio::select!` over: scanner events channel, podman events channel, menu action channel, shutdown signal (SIGTERM/SIGINT)
- [x] 6.6 Wire scanner → event loop → tray state update → menu rebuild pipeline
- [x] 6.7 Wire podman events → event loop → tray state update → menu rebuild pipeline
- [x] 6.8 Implement "Attach Here" handler: allocate genus, create container via podman client, update tray state with bud icon, transition to bloom on container healthy
- [x] 6.9 Implement Stop handler: send graceful stop, update icon to dried bloom during shutdown, remove from running on complete
- [x] 6.10 Implement Destroy handler with 5-second safety hold (confirmation delay before cache deletion, project source in `~/src` is never touched)
- [x] 6.11 Implement main tray icon state transitions: idle (no projects) → subtle bloom (projects detected) → colorful (running) → multiple blooms (multiple running)
- [x] 6.12 Implement graceful application shutdown: stop all managed containers on Quit, clean up event watchers

## 7. Cross-Platform and Polish

- [x] 7.1 Implement platform-aware config paths: Linux `~/.config/tillandsias/`, macOS `~/Library/Application Support/tillandsias/`, Windows `%APPDATA%/tillandsias/`
- [x] 7.2 Implement platform-aware cache paths: Linux `~/.cache/tillandsias/`, macOS `~/Library/Caches/tillandsias/`, Windows `%LOCALAPPDATA%/tillandsias/`
- [x] 7.3 Add Podman Machine awareness: detect platform, check `podman machine list` on macOS/Windows, surface clear user-facing message with installation link when unavailable
- [x] 7.4 Verify `notify` watcher works correctly on all three platforms (inotify/kqueue/ReadDirectoryChangesW) — document any platform-specific quirks
- [x] 7.5 Implement image pull with non-technical progress: tray shows "Preparing environment..." while pulling, genus icon in bud state
- [x] 7.6 Implement WASM-isolated timeout wrapper for container operations: 60s timeout for start operations, terminable on non-response, exponential backoff on reconnection
- [x] 7.7 Add `tracing` instrumentation throughout all crates for structured logging (debug builds only, no user-visible logs)
- [x] 7.8 Verify cross-compilation targets: `x86_64-unknown-linux-gnu`, `aarch64-apple-darwin`, `x86_64-pc-windows-msvc`

## 8. Documentation and First Run

- [x] 8.1 Create `CLAUDE.md` with build commands, workspace structure, architecture overview, and test commands
- [x] 8.2 Add platform-specific installation docs: Linux (podman from package manager), macOS (Podman Desktop / `brew install podman` + `podman machine init`), Windows (Podman Desktop)
- [x] 8.3 Write self-documenting default `config.toml` template generated on first run (with comments explaining each setting)
- [x] 8.4 Verify end-to-end flow: launch tray → detect project in `~/src` → click "Attach Here" → container starts with forge image → genus icon blooms → Stop → icon dries → container destroyed (requires manual verification with running podman)
