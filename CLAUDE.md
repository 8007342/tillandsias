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
./build.sh --install                # Build AppImage + install to ~/Applications/
./build.sh --remove                 # Remove installed AppImage + symlink
./build.sh --wipe                   # Remove target/, caches
./build.sh --toolbox-reset          # Destroy and recreate toolbox
```

The build script auto-creates the `tillandsias` toolbox with all system deps on first run.

### macOS Native Build

```bash
./build-osx.sh                      # Debug build (native, no toolbox)
./build-osx.sh --release            # Release build (Tauri .dmg bundle)
./build-osx.sh --test               # Run test suite
./build-osx.sh --check              # Type-check only
./build-osx.sh --clean              # Clean + rebuild
./build-osx.sh --clean --release    # Clean release build
./build-osx.sh --install            # Release build + install to ~/Applications/
./build-osx.sh --remove             # Remove installed app + CLI symlink
./build-osx.sh --wipe               # Remove target/, caches
```

Builds directly on macOS using Xcode CLT + Rust — no toolbox needed. Supports Apple Silicon (aarch64) and Intel (x86_64). Local builds are unsigned; use `xattr -cr ~/Applications/Tillandsias.app` to bypass Gatekeeper.

### Windows Cross-Compilation

```bash
./build-windows.sh                  # Debug cross-build (auto-creates toolbox)
./build-windows.sh --release        # Release cross-build (unsigned NSIS/MSI)
./build-windows.sh --check          # Type-check for Windows target
./build-windows.sh --test           # Compile tests (not executed on Linux)
./build-windows.sh --clean          # Clean Windows artifacts
./build-windows.sh --toolbox-reset  # Destroy and recreate Windows toolbox
```

Uses `cargo-xwin` in a dedicated `tillandsias-windows` toolbox. Artifacts are unsigned — for local testing only. See `docs/cross-platform-builds.md` for details and macOS build strategy.

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

## CI/CD — Conservative Cloud Usage

Both CI and Release workflows are **manual trigger only** (`workflow_dispatch`). They NEVER run automatically on push or PR. This is intentional — cloud minutes are expensive.

**Rules:**
- Push code freely — zero cloud minutes consumed
- **Do NOT** trigger `gh workflow run` after every commit
- Batch changes, test locally, trigger a release only when shipping
- Use `./build.sh --test` and `cargo clippy` locally before pushing
- A release is a deliberate act: bump VERSION, tag, then `gh workflow run release.yml -f version=X.Y.Z`

**Release workflow**: `gh workflow run release.yml -f version="0.1.37.25"`
**CI workflow**: `gh workflow run ci.yml` (lint + test only, no artifacts)

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

## Container Image Builds (Nix)

Images are built reproducibly using Nix inside a dedicated builder toolbox (`tillandsias-builder`), separate from the dev toolbox.

### Builder Toolbox

```bash
scripts/ensure-builder.sh          # Create builder toolbox with Nix (auto-called by build-image.sh)
scripts/build-image.sh forge       # Build the forge (dev environment) image
scripts/build-image.sh web         # Build the web server image
scripts/build-image.sh forge --force  # Rebuild even if sources unchanged
```

The build script:
1. Ensures the `tillandsias-builder` toolbox exists with Nix + flakes
2. Checks staleness (hashes `flake.nix`, `flake.lock`, `images/` sources)
3. Runs `nix build` inside the builder toolbox to produce a tarball
4. Loads the tarball into podman via `podman load`
5. Tags as `tillandsias-forge:latest` or `tillandsias-web:latest`

Build cache is stored in `.nix-output/` (gitignored).

### Image Architecture

- `flake.nix` defines image outputs using `dockerTools.buildLayeredImage`
- `images/default/Containerfile` and `images/web/Containerfile` are kept as reference documentation
- The primary build path is always through `flake.nix` via `build-image.sh`
- Rust code (`handlers.rs`, `runner.rs`) calls `build-image.sh` as a subprocess

## Related Projects

- `../forge` — Container images (Macuahuitl forge). Tillandsias uses these as default container images.
- `../thinking-service` — Autonomous daemon. Architecture patterns (tokio::select!, event loop) informed Tillandsias design.

## OpenSpec — Monotonic Convergence

All changes go through OpenSpec (`/opsx:ff` or `/opsx:new`). No exceptions for "quick fixes".

**Purpose**: OpenSpec ensures **monotonic convergence** — specs and implementation move toward each other with every change, never apart. The spec trail is the project's institutional memory and proof of work.

**Rules**:
- Spec must reflect what was built. Implementation must reflect what was spec'd.
- If implementation diverges from spec during development, update the spec.
- If a spec decision is revised, update the spec before (or with) the code change.
- Use `/opsx:verify` before archiving to confirm convergence.
- Break large features into multiple changes — each independently convergent.

## Trace Annotations — @trace spec:<name>

Add `@trace spec:<name>` annotations in ALL code changes. Traces are the connective tissue between specs, code, and runtime accountability.

**Where to add:**
- Rust: `// @trace spec:<name>` near functions implementing a spec
- Shell: `# @trace spec:<name>` near relevant code blocks
- Docs/cheatsheets: `@trace spec:<name>` as plain text
- Commits: include GitHub search URL for the trace
- Log events: `spec = "<name>"` field on accountability-tagged tracing events

**Coverage:** ~145 trace annotations across 73 files. Every new feature should add traces.

## Cheatsheets

Document operational knowledge in `docs/cheatsheets/` with `@trace` annotations.

Current: `logging-levels.md`, `secret-management.md`, `token-rotation.md`, `terminal-tools.md`.

## Agent Waves

For batch tasks, organize parallel agents into waves by size (small first). Track each group with a separate OpenSpec change. Report traces added/updated after each wave.

## Commit Conventions

When a commit implements or fixes a spec-traced feature, include a clickable GitHub code search URL in the commit body:

```
fix: entrypoint crashes under set -e

@trace spec:forge-launch
https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Aforge-launch&type=code

OpenSpec change: fix-entrypoint-regression
```

The URL links to every source file implementing that spec. GitHub renders it as a clickable link in the commit view. The search is always live — no generated files to maintain.

Format — replace `SPECNAME` with the actual spec name (e.g., `forge-launch`):
```
https://github.com/8007342/tillandsias/search?q=%40trace+spec%3ASPECNAME&type=code
```

## Conventions

- User-facing text MUST NOT contain: "container", "pod", "image", "runtime"
- "Attach Here" = launch development environment for a project
- Each environment gets a tillandsia genus name for visual linking
- Plant lifecycle maps to container lifecycle: Pup→Initializing, Mature→Ready, Blushing→Building, Blooming→Complete, Dried→Error
