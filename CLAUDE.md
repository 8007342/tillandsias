# CLAUDE.md

## Project

**Tillandsias** — a cross-platform system tray application (Rust + Tauri v2) that orchestrates containerized development environments invisibly. Users never see containers.

## Build Commands

```bash
./build.sh                          # Debug build (auto-creates toolbox if needed)
./build.sh --release                # Release build (Tauri bundle)
./build.sh --test                   # Run test suite
./build.sh --check                  # Type-check only
./build.sh --clean                  # Clean + rebuild
./build.sh --clean --release        # Clean release build
./build.sh --install                # Release build + install to ~/.local/bin/
./build.sh --remove                 # Remove installed binary
./build.sh --wipe                   # Remove target/, caches
./build.sh --toolbox-reset          # Destroy and recreate toolbox
```

The build script auto-creates the `tillandsias` toolbox with all system deps on first run.

### Manual Commands (without build.sh)

```bash
toolbox run -c tillandsias cargo build --workspace
toolbox run -c tillandsias cargo test --workspace
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
