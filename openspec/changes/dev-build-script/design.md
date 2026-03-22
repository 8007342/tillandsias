## Context

On Fedora Silverblue, Tauri's system dependencies (GTK, WebKit, libappindicator) can't be installed on the immutable host. The `tillandsias` toolbox containers these deps. The forge project's `build.sh` and `run.sh` establish the pattern — a single script that auto-enters the right toolbox and handles everything.

## Goals / Non-Goals

**Goals:**
- Single `./build.sh` covers the entire dev lifecycle
- Toolbox auto-created on first run (zero manual setup)
- Flags for every lifecycle operation
- Works on fresh checkout — no prerequisites beyond `toolbox` and `podman`

**Non-Goals:**
- End-user installation (that's the release pipeline's job)
- Cross-compilation (that's CI's job)
- Production deployment

## Decisions

### D1: Flag Design

| Flag | Action |
|------|--------|
| (none) | Debug build (`cargo build --workspace`) |
| `--release` | Release build (`cargo tauri build`) |
| `--test` | Run all tests (`cargo test --workspace`) |
| `--check` | Type-check only (`cargo check --workspace`) |
| `--clean` | `cargo clean` + remove build artifacts |
| `--install` | Build release + copy binary to `~/.local/bin/tillandsias` |
| `--remove` | Remove installed binary from `~/.local/bin/` |
| `--wipe` | Remove `~/.cache/tillandsias/` and `target/` |
| `--toolbox-reset` | Destroy and recreate the toolbox from scratch |
| `--help` | Show usage |

Multiple flags can be combined: `./build.sh --clean --release --install`

### D2: Toolbox Auto-Creation

On every invocation, check if `tillandsias` toolbox exists. If not:
1. Create it from `fedora-toolbox:43` (or latest)
2. Install system deps: `gtk3-devel webkit2gtk4.1-devel libappindicator-gtk3-devel librsvg2-devel openssl-devel pkg-config gcc`
3. Install `tauri-cli` via cargo if not present

This adds ~60s on first run, then ~0s on subsequent runs.

### D3: Toolbox Name Convention

Toolbox name = project directory name (`tillandsias`), matching the workspace-wide convention from the parent CLAUDE.md.

### D4: Install Paths

| Artifact | Install location |
|----------|-----------------|
| Binary | `~/.local/bin/tillandsias` |
| Desktop entry | `~/.local/share/applications/tillandsias.desktop` (future) |
| Tray icon | `~/.local/share/icons/hicolor/256x256/apps/tillandsias.png` (future) |

MVP: binary only. Desktop entry and icon are future tasks.
