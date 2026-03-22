## Why

There is no lightweight, opinionated way for non-technical users to go from an idea to a running application without understanding containers, runtimes, git, or cloud infrastructure. Existing tools either expose too much complexity (Docker Desktop, VS Code Dev Containers) or lock users into proprietary platforms (Replit, GitHub Codespaces). Tillandsias fills this gap: a system tray application that makes software appear — ephemeral, local-first, reproducible, and safe — by orchestrating containerized development environments invisibly.

The forge container images and thinking-service daemon already exist as proven research. What's missing is the thin, cross-platform orchestration layer that ties them together behind a zero-cognitive-load UX where users only see: **Create**, **Work**, **Run**, **Stop**.

## What Changes

- **New Rust + Tauri v2 tray application** with system tray-only UI (no main window)
- **Filesystem scanner** watching `~/src` for projects using OS-native file events (inotify/kqueue/ReadDirectoryChangesW) via tokio, with near-zero idle resource usage
- **Podman command execution layer** abstracting container lifecycle (create, start, stop, destroy) behind user-friendly "app" semantics — users never see containers
- **Configuration-driven environment runtime** that defaults to the Macuahuitl forge image but allows power users to configure custom container images via dotfiles
- **Artifact detection** reading standard Containerfiles and runtime metadata from project directories to determine what can be run
- **Cross-platform support** from day one: Linux native, macOS and Windows with Podman Machine as a documented prerequisite
- **Rust-native serialization** (bincode/postcard/rkyv) for all internal IPC and configuration passing — no JSON in hot paths
- **Event-driven architecture** using tokio with observable streams, background low-priority queues, and ~0% idle CPU target

## Capabilities

### New Capabilities
- `tray-app`: Tauri v2 system tray UI — menu hierarchy, icon state management (idle/detected/running/multiple), cross-platform tray behavior, minimal resource footprint
- `filesystem-scanner`: Event-driven project discovery in `~/src` — OS-native watchers via tokio, project detection heuristics, artifact presence detection, low-priority background queue
- `podman-orchestration`: Container lifecycle management — rootless podman execution, GPU passthrough detection, volume mounting with security hardening (cap-drop, no-new-privileges, userns keep-id), cross-platform podman machine awareness
- `environment-runtime`: Configuration-driven container launch — default forge image with override support, OpenCode + curated settings injection, mount strategy for code persistence and cache sharing, ephemeral by design
- `app-lifecycle`: User-facing application semantics — start/stop/destroy mapped to container operations, running app tracking, tray status display, graceful shutdown with hold-to-destroy safety
- `artifact-detection`: Standard container artifact discovery — reads existing Containerfiles and runtime metadata from project directories, no new file formats, transparent over existing container infrastructure

### Modified Capabilities
<!-- No existing specs to modify — this is a greenfield project -->

## Impact

- **New codebase**: Rust workspace with Tauri v2, targeting Linux/macOS/Windows
- **Host dependencies**: Podman (rootless) required; on macOS/Windows additionally Podman Machine
- **Filesystem**: Watches `~/src/`, caches in `~/.cache/tillandsias/` (containers, settings), config in `~/.config/tillandsias/`
- **External project integration**: References Macuahuitl forge images (ghcr.io/8007342/macuahuitl) as default container image — but the image itself is developed and published independently
- **Serialization boundary**: Internal IPC uses Rust-native binary formats; external interfaces (MCP servers, container labels) may use standard formats where interop requires it
- **Security surface**: All user code runs in isolated containers with dropped capabilities. The tray app itself is the only trusted component. Forge and user code are untrusted/hostile trust zones.
