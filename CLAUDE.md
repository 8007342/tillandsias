# CLAUDE.md

## Project

**Tillandsias** — a cross-platform system tray application (Rust + Tauri v2) that orchestrates containerized development environments invisibly. Users never see containers.

## Build Commands

```bash
# Library crates only (no system deps needed)
cargo check -p tillandsias-core -p tillandsias-scanner -p tillandsias-podman
cargo test -p tillandsias-core -p tillandsias-scanner -p tillandsias-podman

# Full workspace (requires GTK/WebKit dev libs — use toolbox on Silverblue)
toolbox run -c tillandsias cargo build --workspace
toolbox run -c tillandsias cargo test --workspace

# If system libs are installed directly
cargo build --workspace
cargo test --workspace
```

### Toolbox Setup (Fedora Silverblue)

```bash
toolbox create tillandsias
toolbox run -c tillandsias sudo dnf install -y gcc gtk3-devel webkit2gtk4.1-devel libappindicator-gtk3-devel librsvg2-devel openssl-devel pkg-config
```

## Workspace Structure

```
crates/tillandsias-core/      # Shared types, config, genus system, serialization
crates/tillandsias-scanner/   # Event-driven filesystem watcher (notify crate)
crates/tillandsias-podman/    # Async podman CLI abstraction
src-tauri/                    # Tauri v2 tray binary (system tray, no main window)
assets/                       # Icons, SVG tillandsia genera
openspec/                     # Spec-driven development artifacts
```

## Key Architecture Decisions

- **Event-driven, NEVER polling** — `notify` for filesystem, `podman events` for containers, exponential backoff fallback
- **Security flags are non-negotiable** — `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--rm` always applied
- **No JSON in hot paths** — `postcard` for internal IPC, TOML for user config
- **Container naming** — `tillandsias-<project>-<genus>` (e.g., `tillandsias-my-app-aeranthos`)
- **Config-driven** — global at `~/.config/tillandsias/config.toml`, per-project at `.tillandsias/config.toml`
- **Forge image is external** — Tillandsias orchestrates containers but doesn't build them. Default image: `ghcr.io/8007342/macuahuitl:latest`

## Versioning

Format: `v<Major>.<Minor>.<ChangeCount>.<Build>` — source of truth is the `VERSION` file at project root.

```bash
./scripts/bump-version.sh              # Sync all files to VERSION
./scripts/bump-version.sh --bump-build # Increment build number
./scripts/bump-version.sh --bump-changes # Increment change count (after /opsx:archive)
```

Cargo.toml and tauri.conf.json use 3-part semver (Major.Minor.ChangeCount). Git tags use full 4-part.

## Test Commands

```bash
# Run all tests
cargo test --workspace

# Run specific crate tests
cargo test -p tillandsias-core
cargo test -p tillandsias-scanner
cargo test -p tillandsias-podman
```

## Related Projects

- `../forge` — Container images (Macuahuitl forge). Tillandsias uses these as default container images.
- `../thinking-service` — Autonomous daemon. Architecture patterns (tokio::select!, event loop) informed Tillandsias design.

## Conventions

- User-facing text MUST NOT contain: "container", "pod", "image", "runtime"
- "Attach Here" = launch development environment for a project
- Each environment gets a tillandsia genus name for visual linking
- Plant lifecycle maps to container lifecycle: Bud→Creating, Bloom→Running, Dried→Stopping, Pup→Rebuilding
