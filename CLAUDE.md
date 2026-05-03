# CLAUDE.md

## Project

**Tillandsias** — a Linux system tray application (Rust + Tauri v2) that orchestrates containerized development environments invisibly. Users never see containers.

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

**Credential flow:** GitHub tokens live exclusively in the host OS keyring (Linux: Secret Service / GNOME Keyring via D-Bus). The git service container reads the token through a D-Bus bridge and performs authenticated push/fetch against GitHub on behalf of the forge. Forge containers never see tokens — they speak plain git protocol to the enclave-local mirror.

**Images are built via:**
```bash
scripts/build-image.sh forge      # Dev environment
scripts/build-image.sh proxy      # Caching proxy
scripts/build-image.sh git        # Git mirror service
scripts/build-image.sh inference  # Local LLM inference
```

### Inference Container — Lazy Model Pulling

The inference container (ollama-based) supports both baked and lazy-pulled models:

- **Baked (always present)**: T0/T1 models baked into image at build time
  - T0: `qwen2.5:0.5b`
  - T1: `llama3.2:3b`

- **Lazy-pulled (background task)**: T2-T5 models pulled host-side after inference startup
  - Triggered automatically after inference health check passes
  - GPU VRAM tier determines which models pull: `gpu::detect_gpu_tier()`
  - Pull via host-side `ollama` binary (bypasses proxy entirely)
  - Models land in `~/.cache/tillandsias/models/` (bind-mounted RW)
  - Fully automatic, no UX, no user interaction

**Model Tier Mapping** (`@trace spec:inference-host-side-pull`):

| Tier | VRAM | Models to Pull |
|------|------|---|
| None | 0GB | (none — T0/T1 sufficient) |
| Low | ≤4GB | (none — T0/T1 sufficient) |
| Mid | 4-8GB | qwen2.5-coder:7b |
| High | 8-12GB | qwen2.5-coder:7b, qwen2.5-coder:14b |
| Ultra | ≥12GB | qwen2.5-coder:7b, qwen2.5-coder:14b, qwen2.5-coder:32b |

**Why host-side pull?** Per `project_squid_ollama_eof.md`: Squid 6.x manifests EOF hard on large ollama pull streams. Pulling host-side via the native `ollama` binary avoids the proxy entirely and achieves 100% success rate.

**Cache-aware**: Before pulling, checks if `~/.ollama/models/manifests/registry.ollama.ai/library/<name>/<tag>` exists locally. Skips if already cached.

**If ollama missing**: Logs `DEGRADED: host-side ollama not found`, skips all pulls. T0/T1 baked models are still available.

## Secrets Architecture — Ephemeral-First Security

@trace spec:podman-secrets-integration, spec:secrets-management

Tillandsias uses **ephemeral podman secrets** for credential isolation in rootless containers. Secrets are never stored on disk and never appear in logs, ps output, or `podman inspect` output.

**Flow:**
1. **Host keyring** — GitHub tokens and CA certificates stored in Linux Secret Service (GNOME Keyring / pass)
2. **Tray creates secrets** — At startup, `handlers::setup_secrets()` reads credentials from keyring and creates podman secrets via `podman secret create --driver=file`
3. **Containers mount secrets** — Container launch passes `--secret <name>` flags; secrets appear at `/run/secrets/<name>` inside container with no world-readable file on disk
4. **Cleanup on shutdown** — `scripts/cleanup-secrets.sh` removes all `tillandsias-*` secrets when tray exits

**Secret names and contents:**
- `tillandsias-github-token` — GitHub OAuth token (read by git-service container for authenticated push/fetch)
- `tillandsias-ca-cert` — Custom CA certificate (read by proxy and inference containers for HTTPS verification)
- `tillandsias-ca-key` — Custom CA private key (read by proxy container for TLS interception)

**Security properties:**
- Secrets are NOT visible in `podman inspect` output (no value exposure)
- Secrets are NOT visible in `ps` output inside containers
- Secrets are NOT visible in container logs
- Only containers explicitly mounted with `--secret <name>` can read the secret
- Forge containers do NOT receive any secrets (fully offline)
- Secrets auto-cleanup prevents accidental credential leaks after tray shutdown

**Implementation:**
- Script: `scripts/create-secrets.sh` — reads from keyring, creates secrets (called by tray)
- Script: `scripts/cleanup-secrets.sh` — removes secrets (called on shutdown)
- Test script: `scripts/test-secrets.sh` — verifies mount, isolation, and cleanup with `--userns=keep-id`
- Entrypoints: `images/proxy/entrypoint.sh`, `images/git/entrypoint.sh`, `images/inference/entrypoint.sh` read from `/run/secrets/`

**References:**
- `cheatsheets/utils/podman-secrets.md` — Podman secrets mechanics and rootless mode requirements
- `cheatsheets/utils/tillandsias-secrets-architecture.md` — Tillandsias-specific credential flow and D-Bus integration

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

## Nix Inside the Forge

The forge includes **Nix, direnv, and nix-direnv** baked into the image for reproducible development environments.

### Quick Start — Using Flakes

Inside a forge container, create a `flake.nix` and `.envrc` in your project:

```bash
# Create a flake for Rust development
nix flake init -t github:NixOS/templates#rust

# Create .envrc to auto-load the environment on cd
echo 'use flake' > .envrc
direnv allow
```

Now every time you `cd` into that directory, direnv automatically loads the flake environment.

### Available Commands

```bash
nix --version           # Check Nix version (2.24.14+)
nix flake show          # Show flake outputs
nix flake check         # Validate flake.nix
nix develop             # Enter dev environment (or via .envrc auto-activation)
nix build               # Build outputs
direnv --version        # Check direnv version (2.35.0+)
```

### Configuration

- **Experimental features**: `nix-command` and `flakes` are pre-enabled in `/home/forge/.config/nix/nix.conf`
- **NIX_PATH**: Set to `nixpkgs=flake:nixpkgs` so `nix shell nixpkgs#hello` works without `flake.lock`
- **direnv auto-activation**: `.envrc` files activate automatically via shell hooks in bash, zsh, and fish

### Performance — nix-direnv Caching

nix-direnv caches flake evaluations and only re-evaluates when `flake.nix` or `flake.lock` changes. This prevents the 5-10 second delay on every `cd` that would occur with full flake re-evaluation.

### Use Cases

- **Multi-language projects**: Combine Rust, Python, Node, etc. in a single `flake.nix` with automatic environment isolation
- **Pinned dependencies**: Lock tool versions in `flake.lock` — every developer uses identical versions
- **Container-agnostic**: The same `flake.nix` works inside the forge and on your host machine

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

## Sources of Truth — every spec references at least one cheatsheet

Every NEW spec under `openspec/changes/<change>/specs/<capability>/spec.md` and `openspec/specs/<capability>/spec.md` SHALL include a `## Sources of Truth` section at the bottom listing one or more cheatsheets from `cheatsheets/` that informed the spec's implementation guidance. Format:

```markdown
## Sources of Truth

- `cheatsheets/<category>/<filename>.md` — one-line reason this cheatsheet was load-bearing
- `cheatsheets/<category>/<filename>.md` — one-line reason
```

`<category>` is one of `runtime`, `languages`, `utils`, `build`, `web`, `test`, `agents`. Filenames are lowercase-hyphenated. The cheatsheet path SHALL resolve to a real file in the repo. Missing or unresolvable references emit a `openspec validate` warning (non-blocking).

**Why**: cheatsheets pin the version of each tool the forge ships and capture the idiomatic usage patterns. When a tool ships a breaking change, the cheatsheet is the single point of update — every spec that referenced it inherits the new pin. Without explicit Sources of Truth, spec-vs-tool drift is invisible until production breaks.

**Existing specs** (those present before this convention landed) are exempt until a separate retrofit sweep adds the section. New specs MUST include the section from day one.

## Cheatsheets

Two distinct directories:
- `docs/cheatsheets/` — Tillandsias-internal operational knowledge (tray state machine, secrets management, token rotation). Read by maintainers on the host.
- `cheatsheets/` — agent-facing cheatsheets baked into the forge image at `/opt/cheatsheets/`. Read by agents inside the forge via `cat $TILLANDSIAS_CHEATSHEETS/INDEX.md | rg <topic>`.

Both use `@trace` annotations and scannable tables. New tool/language references go in `cheatsheets/<category>/<topic>.md` using `cheatsheets/TEMPLATE.md`. Each new cheatsheet must also be added to `cheatsheets/INDEX.md`.

### Provenance is mandatory in every cheatsheet

Every cheatsheet under `cheatsheets/` SHALL include a `## Provenance` section listing at least one high-authority source URL and a `**Last updated:** YYYY-MM-DD` line. Authority hierarchy: vendor / standards body first (`python.org`, `rust-lang.org`, `oracle.com`, `aws.amazon.com`, `cloud.google.com`, `redhat.com`, IETF RFC, W3C/WHATWG), then recognised community projects (`mozilla.org/MDN`, `postgresql.org`, etc.). Stack Overflow / blogs / AI-generated docs are NEVER acceptable as primary provenance.

Cheatsheets without provenance are REJECTED at review time. The `agent-cheatsheets` capability spec is the source of truth for the format and refresh cadence.

### Cheatsheet citation traceability

Code, log events, telemetry, and specs that derive their behaviour from a cheatsheet SHALL cite the cheatsheet by relative path:

- Rust: `// @cheatsheet languages/rust.md`
- Shell: `# @cheatsheet languages/bash.md`
- Log events: `cheatsheet = "build/cargo.md"` field
- OpenSpec: cite under `## Sources of Truth` (already mandated)

This makes the cheatsheet → code → spec graph queryable by `git grep '@cheatsheet'` exactly like `@trace spec:`.

### Cheatsheet refresh cadence and staleness detection

Cheatsheets are living documents. Each cheatsheet's `**Last updated:** YYYY-MM-DD` line indicates when it was last verified against the cited authoritative sources. A soft staleness check runs periodically:

**Refresh workflow:**
1. Run `scripts/check-cheatsheet-staleness.sh` to identify cheatsheets older than 90 days (default threshold)
2. For each flagged cheatsheet:
   - Re-fetch the cited URLs and confirm the cheatsheet content still matches the upstream source
   - Correct any divergences in the cheatsheet content
   - Update the `**Last updated:**` date to today ONLY after re-verification (never blindly)
3. Commit with message like: `chore(cheatsheets): refresh stale entries — verified against upstream sources`

**Automation:**
- Manual cadence: run `scripts/check-cheatsheet-staleness.sh --days 90` every 3 months (or as part of release prep)
- Future enhancement: CI workflow can run this check on schedule or on-demand (`workflow_dispatch`)
- The check is informational (non-blocking) — staleness does not fail builds. It surfaces in RUNTIME_LIMITATIONS logs and host-side monitoring

**No blind bumps:** The `**Last updated:**` line is a promise that the cheatsheet was actually re-verified. Never bump the date without re-checking the cited URLs.

## @tombstone — never silently delete

Dead code, deprecated specs, and removed features get a `@tombstone superseded:<new>` (replacement exists) or `@tombstone obsolete:<old>` (no replacement) annotation. The block is commented out, NOT deleted, for **three releases** (since Tillandsias has a release cadence — VERSION track) before final deletion. The tombstone records the version it landed in so reviewers know when it's safe to delete.

```rust
// @tombstone superseded:tray-no-disabled-items
// Old projection — removed in 0.1.169.226. Safe to delete after 0.1.169.229.
//
// fn set_stage(&self, stage: Stage) { ... }
```

This complements OpenSpec's `## REMOVED Requirements` section (which carries `**Reason**:` and `**Migration**:` — the spec-level tombstone). Together they form a complete audit of behavioural transitions.

`git log -G '@tombstone'` reveals every transition; `cheatsheet = ...` and `tombstone = ...` log fields make runtime behaviour cross-reference removed code paths.

Current: `logging-levels.md`, `secrets-management.md`, `token-rotation.md`, `terminal-tools.md`.

## Project README Discipline

@trace spec:project-bootstrap-readme

Every Tillandsias-managed project's README.md follows a two-section contract, auto-generated from authoritative sources (manifests, git history, agent observations). See `cheatsheets/welcome/readme-discipline.md` for the complete specification.

**Four bootstrap skills**:
- `/startup` — Entrypoint. Detects project state and routes to empty-project, repair, or ready flow
- `/bootstrap-readme-and-project` — Empty-project welcome with sample prompts and capability summary
- `/bootstrap-readme` — Regenerate and validate README from source manifests
- `/status` — Show project state (recent commits, OpenSpec items, readme.traces tail)

**Key files**:
- `scripts/regenerate-readme.sh` — Dispatcher: walks manifests, invokes summarizers, renders FOR HUMANS + FOR ROBOTS sections
- `scripts/check-readme-discipline.sh` — Validator: confirms structure, headers, timestamp freshness, YAML well-formedness
- `scripts/install-readme-pre-push-hook.sh` — Pre-push hook: auto-regenerates README on every git push
- `.tillandsias/readme.traces` — Append-only JSONL ledger of agent observations (committed to git, cross-machine)

**Telemetry events**:
- `startup_routing` — Which branch was taken (empty / bootstrap-readme / status)
- `readme_regen` — README regenerated; which summarizers ran
- `readme_requires_pull` — Cheatsheet materialized from requires_cheatsheets YAML block

Mandatory maintainer TODO: Migrate Tillandsias' own README.md to the FOR HUMANS / FOR ROBOTS structure (task 10 of this change).

## Plugins & Skills

Invoke installed skills proactively when their trigger fires. Order below is by expected frequency in this project.

- **OpenSpec suite (`opsx:new`, `opsx:ff`, `opsx:apply`, `opsx:verify`, `opsx:archive`, `opsx:sync`, plus `openspec-*` equivalents)**: the primary workflow gate. See the **OpenSpec — Monotonic Convergence** section above for rules and sequencing. Never bypass with ad-hoc edits.
- **`simplify`**: invoke after implementing a non-trivial change (new module, refactor, >100 LOC touched) and before `opsx:verify`. Catches duplication, leaky abstractions, and hot-path JSON (forbidden here — use `postcard`).
- **`security-review`**: invoke before merging any branch that touches enclave containers, credential paths, proxy/git-service config, `--cap-drop`/`--security-opt`/`--userns` flags, keyring/D-Bus code, or anything under `src-tauri/` that crosses the host/forge boundary.
- **`review`**: invoke before `gh pr create` on branches destined for `main` from `linux-next`. Complements `security-review`; run both for enclave-adjacent work.
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

## Linux-Only Development

Tillandsias is developed exclusively on Linux (Fedora Silverblue) with the following workflow:

**Build and test:**
```bash
./build.sh --test && cargo clippy --workspace
```

**Version bumps:**
- During development: NO version bumps. Let `--bump-build` happen locally but don't commit it.
- At merge time: `./scripts/bump-version.sh --bump-changes` once, commit, push main.
- Release: `gh workflow run release.yml -f version="X.Y.Z.B"` from main only.

**Cargo.lock:** Committed to git (correct for binary projects). If Cargo.lock conflicts at merge time, regenerate: `cargo generate-lockfile`.

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

## @tombstone — Never Silently Delete

Dead code, deprecated specs, and removed features get a `@tombstone superseded:<new>` (replacement exists) or `@tombstone obsolete:<old>` (no replacement) annotation. The block is commented out, NOT deleted, for **three releases** (since Tillandsias has a release cadence — VERSION track) before final deletion. The tombstone records the version it landed in so reviewers know when it's safe to delete.

**Rust example:**
```rust
// @tombstone superseded:tray-no-disabled-items
// Old projection — removed in 0.1.169.226. Safe to delete after 0.1.169.229.
// @trace spec:old-tray-menu-state
//
// fn set_stage(&self, stage: Stage) { ... }
```

**Shell example:**
```bash
# @tombstone obsolete:legacy-forge-init
# Superseded by direct podman pull path in 0.1.37.45. Safe to delete after 0.1.37.48.
#
# init_forge_image() { ... }
```

**Markdown example (in CLAUDE.md or specs):**
```markdown
<!-- @tombstone superseded:agent-cheatsheets-v1 — kept for three releases -->
<!-- Replaced by agent-cheatsheets-v2 in 0.1.100.1. Safe to delete after 0.1.100.4. -->
```

**Required fields:**
- `superseded:<new-spec-name>` — replacement capability exists
- OR `obsolete:<old-spec-name>` — entire feature gone, no replacement
- Version landed in and safe-to-delete version (based on current VERSION file)
- 1–3 lines of rationale
- Optional: `@trace spec:<name>` linking to removed spec

**Retention window:**
- **Cadence-based projects** (Tillandsias — 4-part VERSION track): three releases on the same Major.Minor track
- Example: removed in v0.1.169.226, safe to delete after v0.1.169.229

**What this enables:**
- `git log -G '@tombstone'` reveals every behavioural transition
- Log events with `tombstone = "<name>"` field create runtime cross-references
- Refactor history is observable without deep `git blame` spelunking
- Reviewers know exactly when orphaned code becomes deletable

**What it does NOT mean:**
- Tombstones are not for keeping dead code forever. After the retention window the tombstoned block is deleted in a normal commit.
- A function with no callers and no spec relationship does NOT need a tombstone — it gets deleted normally
- Tombstones mark **transitions**, not orphans

This complements OpenSpec's `## REMOVED Requirements` section (which carries `**Reason**:` and `**Migration**:` — the spec-level tombstone). Together they form a complete audit of behavioural transitions.

## Conventions

- User-facing text MUST NOT contain: "container", "pod", "image", "runtime"
- "Attach Here" = launch development environment for a project
- Each environment gets a tillandsia genus name for visual linking
- Plant lifecycle maps to container lifecycle: Pup→Initializing, Mature→Ready, Blushing→Building, Blooming→Complete, Dried→Error
