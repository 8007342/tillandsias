# Tillandsias

*A quiet system that makes software appear.*

Tillandsias is a cross-platform system tray application that lets users create, work on, and run applications from simple intent — safely, locally, reproducibly. Users never see containers, runtimes, or infrastructure. They only see:

- **Attach Here** — open an isolated development environment
- **Start** — run the application
- **Stop** — shut it down

Everything else happens invisibly.

## Architecture

```
Tillandsias Tray App (Rust + Tauri v2)
        |
  Event-driven orchestration (tokio)
        |
  +-----------+-----------+
  |           |           |
Scanner    Podman      Config
(notify)   (async CLI)  (TOML)
  |           |
~/src/     Containers
projects   (ephemeral)
```

### Workspace Structure

```
tillandsias/
├── Cargo.toml                    # Workspace root
├── crates/
│   ├── tillandsias-core/         # Shared types, config, genus system
│   ├── tillandsias-scanner/      # Event-driven filesystem watcher
│   └── tillandsias-podman/       # Async podman CLI abstraction
├── src-tauri/                    # Tauri v2 tray binary
│   ├── tauri.conf.json
│   └── src/main.rs
└── assets/                       # Icons, SVG tillandsia genera
```

### Key Design Decisions

- **Event-driven, never polling** — OS-native filesystem events via `notify`, container events via `podman events`, exponential backoff fallback. Near-zero idle CPU.
- **Security-hardened containers** — `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--rm`. Non-negotiable.
- **Configuration-driven** — defaults to the Macuahuitl forge image, power users can override per-project via `.tillandsias/config.toml`.
- **Tillandsia genus iconography** — each environment gets a unique genus name (Aeranthos, Ionantha, etc.) with lifecycle icons (bud/bloom/dried/pup) linking the project tree and running environment visually.
- **Rust-native serialization** — `postcard` for internal IPC, TOML for user-facing config. No JSON in hot paths.

## Requirements

- **Podman** (rootless)
  - Linux: install from your package manager
  - macOS: `brew install podman && podman machine init && podman machine start`
  - Windows: install [Podman Desktop](https://podman-desktop.io/)

## Build

```bash
./build.sh                  # Debug build (auto-creates toolbox on first run)
./build.sh --test           # Run tests
./build.sh --release        # Release build (Tauri bundle)
./build.sh --install        # Release + install to ~/.local/bin/
./build.sh --clean          # Clean + rebuild
./build.sh --wipe           # Remove target/, caches
./build.sh --toolbox-reset  # Destroy and recreate toolbox
./build.sh --remove         # Uninstall from ~/.local/bin/
```

The build script handles everything — toolbox creation, system dependencies, Tauri CLI installation. Zero manual setup on Fedora Silverblue.

## Configuration

### Global (`~/.config/tillandsias/config.toml`)

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

### Per-project (`<project>/.tillandsias/config.toml`)

```toml
image = "custom-forge:latest"
port_range = "8080-8089"

[runtime]
command = "npm start"
port = 3000
```

## Container Naming

Environments are namespaced as `tillandsias-<project>-<genus>`:

```
tillandsias-my-app-aeranthos
tillandsias-my-app-ionantha      (second concurrent environment)
tillandsias-other-project-xerographica
```

## Tillandsia Genera

Eight curated genera serve as visual namespaces:

| Genus | Slug | Character |
|-------|------|-----------|
| Aeranthos | aeranthos | Compact, vibrant |
| Ionantha | ionantha | Small, colorful |
| Xerographica | xerographica | Flowing, airy |
| Caput-Medusae | caput-medusae | Structured |
| Bulbosa | bulbosa | Rounded |
| Tectorum | tectorum | Fuzzy, white |
| Stricta | stricta | Upright |
| Usneoides | usneoides | Cascading |

### Lifecycle Icons

| Container State | Plant State | Visual |
|----------------|-------------|--------|
| Creating/booting | Bud | Small green plant |
| Running (healthy) | Bloom | Colorful flower |
| Stopping | Dried | Faded flower |
| Rebuilding | Pup | New growth |

## Versioning

Format: `v<Major>.<Minor>.<ChangeCount>.<Build>`

| Component | Meaning | Bumped when |
|-----------|---------|-------------|
| Major | Breaking changes | Manual — API/UX breaks |
| Minor | New features | Manual — feature additions |
| ChangeCount | OpenSpec archived changes | Incremented by `/opsx:archive` |
| Build | Build number | Auto-incremented by CI |

```bash
# Bump build number
./scripts/bump-version.sh --bump-build

# Bump change count (after archiving OpenSpec changes)
./scripts/bump-version.sh --bump-changes

# Sync all version locations from VERSION file
./scripts/bump-version.sh
```

Rolling tags: `stable` (latest release), `latest` (latest build).

## License

GPL-3.0-or-later
