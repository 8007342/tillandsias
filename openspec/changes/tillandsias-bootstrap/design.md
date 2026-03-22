## Context

The Macuahuitl forge project already has a working Tauri v2 tray app (`forge/tray/`) that manages a single container with hardcoded image references, 1-second polling loops, and synchronous podman CLI calls. The thinking-service project demonstrates a mature Rust event loop pattern using `tokio::select!` with multiple event sources, filesystem-backed state, and graceful shutdown.

Tillandsias builds on both as a clean-slate, config-driven orchestration layer that is **independent** of any specific container image. The forge image is just the default. The app must be cross-platform from day one (Linux native, macOS/Windows via Podman Machine), extremely low resource when idle (~0% CPU, <100MB RAM), and never expose container semantics to users.

**Constraints:**
- Ephemeral, idempotent, throw-away — no hidden persistent state beyond caches
- All user code treated as hostile — isolation enforced at container level
- No new file formats — build on existing Containerfiles, standard tooling
- No JSON in hot paths — Rust-native binary serialization for internal IPC

## Goals / Non-Goals

**Goals:**
- Tray-only Tauri v2 app with dynamic menu showing projects and running apps
- Event-driven filesystem scanning of `~/src` with near-zero idle overhead
- Configuration-driven container lifecycle (image, mounts, security flags all configurable)
- Cross-platform podman orchestration with GPU passthrough detection
- User-facing "app" semantics hiding all container machinery
- Modular crate architecture enabling independent testing and future extension

**Non-Goals:**
- Building or maintaining container images (external project responsibility)
- Kubernetes, cloud orchestration, or multi-user systems
- Main application window, webview, or rich GUI (tray-only MVP)
- Embedded AI/LLM inference (handled inside the container by OpenCode/Ollama)
- Advanced debugging, log viewing, or terminal emulation in the tray app
- Custom file formats, custom protocols, or custom package managers

## Decisions

### D1: Rust Workspace with Modular Crates

**Choice:** Multi-crate Rust workspace, not a single monolithic binary.

```
tillandsias/
├── Cargo.toml                  # Workspace root
├── crates/
│   ├── tillandsias-core/       # Shared types, config, serialization
│   ├── tillandsias-scanner/    # Filesystem watcher (notify + tokio)
│   ├── tillandsias-podman/     # Podman CLI abstraction
│   └── tillandsias-tray/      # Tauri v2 tray app (binary crate)
├── src-tauri/                  # Tauri build context (thin, delegates to crates)
└── assets/                     # Icons, visual identity
```

**Why over monolith:** Each concern (scanning, podman, tray UI) is independently testable, and the `podman` and `scanner` crates can be reused by future CLI tools or daemons without pulling in Tauri.

**Alternatives considered:**
- Single crate with modules — simpler initially, but entangles Tauri dependencies with pure logic, making unit testing harder and blocking reuse.
- Separate repositories — too much coordination overhead for tightly coupled components.

### D2: Event-Driven Architecture with tokio::select!

**Choice:** Central event loop using `tokio::select!` with typed event channels, modeled after thinking-service's proven pattern.

```rust
enum AppEvent {
    FilesystemChange(ProjectChange),
    ContainerStateChange(ContainerId, ContainerState),
    MenuAction(MenuCommand),
    Shutdown,
}
```

All components (scanner, podman status, menu) emit events into an `mpsc` channel. The main loop dispatches. No polling loops.

**Why over polling:** The forge tray app polls container status every 1 second — wasteful and architecturally wrong for a ~0% idle CPU target. Event-driven means the app does literally nothing when nothing changes.

**Alternatives considered:**
- Timer-based polling with long intervals — simpler but still wastes cycles and introduces latency. Events from `notify` and podman events are available; use them.
- Callback spaghetti (each component updates tray directly) — violates single-owner-of-state principle, race conditions.

### D3: Filesystem Scanning via `notify` Crate

**Choice:** The [`notify`](https://docs.rs/notify) crate with its async watcher, debounced through a tokio channel with configurable delay (default: 2-3 seconds).

**Behavior:**
- Watches `~/src` (configurable) at depth 2 (project directories, not deep recursion)
- Detects: directory creation/deletion, presence of `Containerfile`/`Dockerfile`/`tillandsias/` markers
- Debounces rapid filesystem events into batched project state updates
- Runs on a low-priority tokio task — never blocks the main event loop

**Why `notify` over manual polling:** `notify` wraps OS-native watchers (inotify on Linux, kqueue on macOS, ReadDirectoryChangesW on Windows) — kernel delivers events, zero CPU when idle. Cross-platform out of the box.

**Alternatives considered:**
- Raw `inotify` crate — Linux-only, would need separate implementations per platform.
- Periodic `fs::read_dir` — explicit NOOP polling, violates the resource constraint.
- `watchman` (Facebook) — external daemon dependency, heavyweight for our needs.

### D4: Podman CLI via tokio::process::Command

**Choice:** Shell out to the `podman` CLI using `tokio::process::Command` for all container operations. No Rust podman library binding.

**Why over library binding:**
- `podman` CLI is the stable, documented, cross-platform interface
- No Rust podman library has reached maturity or stability guarantees
- The forge project already validates this pattern works
- CLI output parsing is simple (JSON format via `--format json`)
- Cross-platform: same CLI works on Linux, macOS (Podman Machine), Windows (Podman Machine)

**Container status monitoring:** Use `podman events --format json` as a long-running subprocess feeding the event loop — no polling. Falls back to periodic `podman inspect` if events aren't available (Podman Machine on macOS/Windows may have limitations).

**Alternatives considered:**
- `bollard` crate (Docker API) — Docker-compatible but misses podman-specific features (rootless, userns, pods).
- `podman-api` crate — immature, incomplete, likely to break.
- gRPC to podman socket — complex, platform-dependent socket paths.

### D5: Configuration System (TOML + postcard)

**Choice:** Two-layer configuration:

1. **User-facing config:** TOML files at `~/.config/tillandsias/config.toml` and per-project `.tillandsias/config.toml`
2. **Internal state/IPC:** `postcard` (Rust-native, compact, serde-compatible) for serialized state snapshots and inter-crate communication

**TOML for user config because:** Human-readable, standard, well-supported in Rust (`toml` crate), familiar to power users. Not JSON (slow to parse, verbose, no comments).

**postcard for internals because:** Serde-native, zero-copy capable, extremely compact, ~10x faster than JSON serialization. Preferred over protobuf because it's pure Rust with no code generation step, no `.proto` files, and derives directly from Rust structs.

**Global config (`~/.config/tillandsias/config.toml`):**
```toml
[scanner]
watch_paths = ["~/src"]
debounce_ms = 2000

[defaults]
image = "ghcr.io/8007342/macuahuitl:latest"
port_range = "3000-3099"

[security]
cap_drop_all = true
no_new_privileges = true
userns_keep_id = true
```

**Per-project override (`.tillandsias/config.toml`):**
```toml
image = "custom-forge:latest"
port_range = "8080-8089"
mounts = [
    { host = "~/data", container = "/data", mode = "ro" }
]
```

**Alternatives considered:**
- JSON config — verbose, no comments, slower parsing, user explicitly rejected.
- bincode — faster than postcard for large payloads but less compact for small messages, no human-debug option.
- rkyv (zero-copy) — maximum performance but unsafe API surface, overkill for our data sizes.
- protobuf — requires `.proto` schema files and codegen step, non-Rust-native toolchain dependency.

### D6: Security-Hardened Container Defaults

**Choice:** Mirror the forge's proven security flags as non-negotiable defaults, configurable only to add further restrictions:

```
--rm                              # Ephemeral by default
--cap-drop=ALL                    # No Linux capabilities
--security-opt=no-new-privileges  # No privilege escalation
--userns=keep-id                  # UID mapping for volume access
--security-opt=label=disable      # Skip SELinux relabeling overhead
```

**Volume mount strategy:**
- `~/src/<project>` → `/var/home/forge/src` (project code, read-write)
- `~/.cache/tillandsias/` → configurable cache mount (models, settings)
- No additional mounts unless explicitly configured per-project

**GPU passthrough:** Auto-detect NVIDIA (`/dev/nvidia*`) and AMD ROCm (`/dev/kfd`, `/dev/dri/renderD*`) devices, pass through via `--device=`. Silent when no GPU present.

**Why non-negotiable:** These are safety invariants, not preferences. A user should never accidentally run untrusted code with elevated privileges. Power users can add restrictions (e.g., `--read-only`, network isolation) but cannot remove the baseline.

### D7: Cross-Platform Strategy

**Choice:** Single codebase, platform-aware at specific decision points:

| Concern | Linux | macOS | Windows |
|---------|-------|-------|---------|
| Podman | Native rootless | Podman Machine (VM) | Podman Machine (VM) |
| FS watcher | inotify (via notify) | kqueue (via notify) | ReadDirectoryChangesW (via notify) |
| GPU passthrough | Device files | Not available (VM) | Not available (VM) |
| Tray icon | libappindicator / StatusNotifier | NSStatusItem (Tauri) | Shell_NotifyIcon (Tauri) |
| Config path | `~/.config/tillandsias/` | `~/Library/Application Support/tillandsias/` | `%APPDATA%/tillandsias/` |

**Podman Machine awareness:** On macOS/Windows, detect if Podman Machine is running. If not, surface a clear, non-technical message: "Tillandsias needs Podman to run apps. [Install instructions]". No attempt to auto-install — that's a hostile UX pattern.

**Why not Linux-only MVP:** The architecture is inherently cross-platform (Tauri, notify, podman CLI). Deferring cross-platform adds tech debt that compounds. Better to handle platform conditionals now while the codebase is small.

### D8: Tray Menu Architecture

**Choice:** Dynamic menu rebuilt on every state change, driven by a `TrayState` struct:

```rust
struct TrayState {
    projects: Vec<Project>,       // from scanner
    running: Vec<RunningApp>,     // from podman events
    platform: PlatformInfo,       // detected at startup
}
```

Menu structure:
```
Tillandsias
  ├─ ~/src/
  │    ├─ project-a/ 🌿 Aeranthos     (tillandsia assigned on attach)
  │    │     ├─ Attach Here
  │    │     ├─ Start (if artifacts)
  │    │     └─ Stop
  │    └─ project-b/
  ├─ ─────────
  │  🌿 Aeranthos  project-a          (matching icon links to tree)
  │  🌸 Caput      project-b          (different tillandsia, different env)
  ├─ ─────────
  ├─ Settings
  └─ Quit
```

**"Attach Here"**: Launches the configured container image with the project directory mounted, OpenCode started inside. The name hides "container" and "ephemeral runtime" while keeping the concept of isolation — the user knows this directory is visible to "whatever this thing is doing." A tillandsia genus is assigned and its icon appears in both the filesystem tree entry and the running container chip, linking them visually.

**Why rebuild-on-change over incremental updates:** Tray menus are small (tens of items). Full rebuild is <1ms and eliminates state synchronization bugs. The forge tray already uses this pattern successfully.

### D10: Tillandsia Iconography and Visual Namespace System

**Choice:** Each running environment is assigned a unique tillandsia genus from a curated pool. The genus determines:
1. The **container name suffix**: `tillandsias-<project>-<genus>` (e.g., `tillandsias-my-app-aeranthos`)
2. The **icon** shown next to the project in the filesystem tree
3. The **icon** shown in the running container chip in the tray menu

This creates an intuitive visual link — users see the same little plant in both places and know they're related. Average users see one tillandsia per project. Power users launching multiple concurrent environments for the same project get different tillandsia genera, each visually distinct.

**Lifecycle states mapped to plant lifecycle:**

| Container State | Plant State | Visual |
|----------------|-------------|--------|
| Creating/Booting | Seedling/bud | Small green plant, no bloom |
| Running (healthy) | Full bloom | Colorful flower in bloom |
| Stopping/Winding down | Dried bloom | Faded/brown flower |
| Spawning rebuild/new process | Pup (offset) | Small plant growing from parent |

Users develop intuitive vocabulary: *"the little flower takes about two minutes to bloom"* = the container takes two minutes to boot and be ready. The abstraction is hidden behind a living metaphor.

**Future icon families by container type:**

| Container Role | Tillandsia Family | Visual Character |
|---------------|-------------------|-----------------|
| Forge/dev environment | Aeranthos, Ionantha | Compact, vibrant |
| Web runtime | Xerographica, Tectorum | Flowing, airy |
| Build container | Caput-Medusae, Bulbosa | Structured, tentacled |
| Database/service | Usneoides (Spanish Moss) | Persistent, cascading |

**SVG abstract iconography:** Icons are generated as abstract SVG at design time — simple geometric tillandsia silhouettes with color variants for each genus. Each icon has 4 state variants (bud, bloom, dried, pup). These are embedded in the binary as compile-time assets and can be refined later without code changes.

**Curated genus pool (MVP — 8 genera, expandable):**
- Aeranthos, Ionantha, Xerographica, Caput-Medusae
- Bulbosa, Tectorum, Stricta, Usneoides

Assignment is round-robin from the pool for each new environment. Same project re-attaching gets the same genus (stored in the project's `.tillandsias/` directory).

**Why over generic numbered icons:** A tillandsia genus is memorable, pronounceable, and creates emotional attachment ("my little Aeranthos is building"). Numbered containers ("container-3") are sterile and expose the abstraction we're hiding.

### D9: Artifact Detection Strategy

**Choice:** Convention-based detection reading existing standard files, no proprietary format:

**Project detection heuristics (checked in order):**
1. `.tillandsias/config.toml` — explicit project config (power users)
2. `Containerfile` or `Dockerfile` — buildable artifact present
3. `package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod` — known project types
4. Any non-empty directory in `~/src/` — default: offer "Open Environment"

**Runnable artifact detection:**
- Presence of `Containerfile` / `Dockerfile` → can build and run
- Presence of `.tillandsias/config.toml` with `[runtime]` section → configured runtime
- Container image already built (check `podman images`) → can start directly

**Why no new format:** The spec is clear — transparent over existing infrastructure. A `Containerfile` is already a reproducible, correct, secure artifact definition. Adding a `tillandsias.yaml` or custom manifest would duplicate what container definitions already express and create a maintenance burden.

## Risks / Trade-offs

**[Podman CLI parsing brittleness]** → Mitigation: Use `--format json` for all podman commands. Pin minimum podman version in docs. Integration tests against podman output format.

**[Podman Machine latency on macOS/Windows]** → Mitigation: Container operations go through a VM, adding ~1-2s latency. Communicate state clearly in tray ("Starting..." states). Pre-warm Podman Machine on app startup if not already running.

**[notify crate watch depth]** → Mitigation: Only watch depth 2 from `~/src` (the project directory level). Deep recursion into `node_modules` or `.git` would overwhelm the watcher. Project-internal changes aren't our concern — the container handles those.

**[GPU passthrough unavailable on macOS/Windows]** → Mitigation: GPU passthrough is Linux-only (direct device access). On macOS/Windows, containers run CPU-only through Podman Machine's VM layer. Document this clearly. Local models (0.3b-7b) are selected to run adequately on CPU.

**[Tauri v2 tray API stability]** → Mitigation: Tauri v2 is stable and released. The forge tray already validates the tray-only pattern works. Pin Tauri version in workspace Cargo.toml.

**[Configuration drift between global and per-project]** → Mitigation: Per-project config merges on top of global with explicit precedence rules. Validation at load time catches conflicts. Defaults are always safe (security flags cannot be weakened, only strengthened).

## Resolved Questions

- **"Attach Here" naming:** Resolved. "Attach Here" hides the container and ephemeral runtime concepts while keeping isolation visible. The user intuits that "this directory is visible to whatever this thing is doing."
- **Container events on Podman Machine:** Resolved. Use optimistic non-blocking event-driven approach with exponential backoff (1s → 30s max). Never polling. Best-effort status updates, UX updates to latest state once detected correctly.
- **Multiple running environments:** Resolved. Yes, fully supported. Namespaced as `tillandsias-<project>-<genus>`. Each environment gets a unique tillandsia genus with matching iconography linking the filesystem tree, running chip, and container name. Average users see one; power users can have multiple with distinct visual identities. Forge provides concurrent git worktree support with shared Nix cache.

## Open Questions

- **SVG generation pipeline:** Should icons be hand-designed SVGs committed to the repo, or generated programmatically from a template system at build time? Programmatic allows easy expansion of the genus pool but may look less polished.
- **Genus persistence:** When a project re-attaches, should it always get the same genus (stored in `.tillandsias/state.toml`) or get a fresh one? Same genus creates familiarity; fresh genus avoids stale state files.
