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
- **Forge image is local** — Tillandsias builds and manages its own forge images. Default image: `tillandsias-forge` (version tag computed at runtime from `forge_image_tag()`)

## Enclave Architecture

Tillandsias uses a multi-container enclave for security isolation. Coding containers are fully offline with zero credentials.

| Container | Image | Role | Network | Credentials |
|-----------|-------|------|---------|-------------|
| **Proxy** | `tillandsias-proxy` | Caching HTTP/S proxy with domain allowlist | External + enclave | None |
| **Git Service** | `tillandsias-git` | Bare mirror, git daemon, auto-push | Enclave only | D-Bus → host keyring |
| **Forge** | `tillandsias-forge` | Dev environment, coding agents | Enclave only | **None** |
| **Inference** | `tillandsias-inference` | Local ollama for LLM | Enclave only | None |

**Key principles:**
- Forge containers have ZERO credentials and ZERO external network access
- Code comes from git mirror clone, packages through proxy, inference from ollama
- Uncommitted changes are ephemeral — lost on container stop
- Multiple forge containers per project, each with independent git working tree
- All operations logged via `--log-enclave`, `--log-proxy`, `--log-git` with `@trace` links

**Credential flow:** GitHub tokens live exclusively in the host OS keyring (Linux: Secret Service / GNOME Keyring via D-Bus; macOS: Keychain; Windows: Credential Manager). The git service container reads the token through a D-Bus bridge and performs authenticated push/fetch against GitHub on behalf of the forge. Forge containers never see tokens — they speak plain git protocol to the enclave-local mirror.

**Images are built via:**
```bash
scripts/build-image.sh forge      # Dev environment
scripts/build-image.sh proxy      # Caching proxy
scripts/build-image.sh git        # Git mirror service
scripts/build-image.sh inference  # Local LLM inference
```

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
5. Tags as `tillandsias-forge:v<FULL_VERSION>` or `tillandsias-web:v<FULL_VERSION>`

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

**Workflow**: `/opsx:ff` (create artifacts) -> `/opsx:apply` (implement) -> `/opsx:archive` (archive + sync specs) -> `./scripts/bump-version.sh --bump-changes`

**Rules**:
- Spec must reflect what was built. Implementation must reflect what was spec'd.
- Specs are source of truth — never modify specs without user approval.
- Specs converge toward **intent**, not toward code. If code diverges from spec, the code is wrong.
- If a spec decision is revised, update the spec before (or with) the code change.
- Use `/opsx:verify` before archiving to confirm convergence.
- Break large features into multiple changes — each independently convergent.
- Each change produces: proposal.md, design.md, specs/<capability>/spec.md, tasks.md
- Delta specs sync to main specs at archive time.

## Trace Annotations — @trace spec:<name>

Add `@trace spec:<name>` annotations in ALL code changes. Traces are the connective tissue between specs, code, and runtime accountability.

**Where to add:**
- Rust: `// @trace spec:<name>` near functions implementing a spec
- Shell: `# @trace spec:<name>` near relevant code blocks
- Docs/cheatsheets: `@trace spec:<name>` as plain text
- Commits: include GitHub search URL for the trace
- Log events: `spec = "<name>"` field on accountability-tagged tracing events
- Multiple specs: `@trace spec:foo, spec:bar`

**Why:** Traces create bidirectional links between specs and implementation. Power users reading logs or source should follow a trace to the spec governing that behavior. The accountability log format renders `@trace spec:name URL` lines with clickable GitHub search links.

## Cheatsheets

Document operational knowledge in `docs/cheatsheets/` with `@trace` annotations and scannable tables.

Current: `logging-levels.md`, `secrets-management.md`, `token-rotation.md`, `terminal-tools.md`.

## Plugins & Skills

Invoke installed skills proactively when their trigger fires. Order below is by expected frequency in this project.

- **OpenSpec suite (`opsx:new`, `opsx:ff`, `opsx:apply`, `opsx:verify`, `opsx:archive`, `opsx:sync`, plus `openspec-*` equivalents)**: the primary workflow gate. See the **OpenSpec — Monotonic Convergence** section above for rules and sequencing. Never bypass with ad-hoc edits.
- **`simplify`**: invoke after implementing a non-trivial change (new module, refactor, >100 LOC touched) and before `opsx:verify`. Catches duplication, leaky abstractions, and hot-path JSON (forbidden here — use `postcard`).
- **`security-review`**: invoke before merging any branch that touches enclave containers, credential paths, proxy/git-service config, `--cap-drop`/`--security-opt`/`--userns` flags, keyring/D-Bus code, or anything under `src-tauri/` that crosses the host/forge boundary.
- **`review`**: invoke before `gh pr create` on branches destined for `main` from `linux-next`/`osx-next`/`windows-next`. Complements `security-review`; run both for enclave-adjacent work.
- **`less-permission-prompts`**: invoke opportunistically when the session has racked up repeated permission prompts for read-only commands. Scans transcripts and updates `.claude/settings.json`.
- **`update-config`**: invoke for any settings.json / hooks change, or when the user asks for automated "from now on" behavior (memory cannot satisfy those — hooks can).
- **`claude-api`**: invoke only if work touches Anthropic SDK code (none in-tree today; reserved for future inference-container client code).
- **`loop` / `schedule`**: invoke only when the user explicitly asks for recurring or cron-scheduled tasks. Never for one-offs.
- **`init`, `keybindings-help`**: not load-bearing for this project; do not invoke unless explicitly requested.

## Agent Waves

For batch tasks, organize parallel agents into waves by size (small first, large last). Track each group with a separate OpenSpec change. Report traces added/updated after each wave.

- Wave 1: tiny/small tasks (complete in <2 min, all parallel)
- Wave 2: medium tasks (2-5 min, parallel)
- Wave 3: large tasks (dedicated opus agents)
- Between waves: build + test to catch integration issues early
- Each agent gets: full context, OpenSpec creation instructions, @trace requirements

## Cross-Platform Development — Branch-per-Machine

The project is developed across Linux (Fedora Silverblue), macOS, and Windows. To prevent cross-platform merge conflicts:

**Branch strategy:**
- `main` — stable, release-ready. Only merge completed work here.
- `linux-next` — active Linux development branch
- `osx-next` — active macOS development branch
- `windows-next` — active Windows development branch

**Workflow:**
1. Work on the platform branch for your current machine (`git checkout linux-next`)
2. Push to the platform branch freely — no conflicts with other machines
3. When a batch of work is complete and tested: merge to main
4. Bump version ONLY at merge-to-main time, not during feature work
5. Push main. Trigger release from main.

**Why:** Pushing from multiple machines to main simultaneously causes rebase conflicts (version numbers, Cargo.lock, platform-specific scripts). Platform branches eliminate this entirely.

**Version bumps:**
- During development: NO version bumps. Let `--bump-build` happen locally but don't commit it.
- At merge time: `./scripts/bump-version.sh --bump-changes` once, commit, push main.
- Release: `gh workflow run release.yml -f version="X.Y.Z.B"` from main only.

**Cross-platform checks before merging to main:**
```bash
# On Linux:
./build.sh --test && cargo clippy --workspace

# On macOS:
./build-osx.sh --test && cargo clippy --workspace

# On Windows:
./build-windows.sh --check
```

**Cargo.lock:** Committed to git (correct for binary projects). Platform-specific deps resolve the same on all platforms. If Cargo.lock conflicts at merge time, regenerate: `cargo generate-lockfile`.

## Cloud Workflows — Conservative Usage

See CI/CD section above. Both CI and Release workflows are `workflow_dispatch` only. NEVER auto-trigger. Batch changes, release deliberately.

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
