# CLAUDE.md

## Authority

`methodology.yaml` is the source of truth for project methodology, bootstrap,
OpenSpec discipline, trace rules, versioning policy, agent orchestration, and
agent observability. This file is only local project/tooling notes for
Claude-compatible tools. If this file conflicts with `methodology.yaml`, follow
`methodology.yaml` and report this file as stale.

## Project

**Tillandsias** — a portable Linux native binary (musl-static) that orchestrates containerized development environments. Runs in headless mode (CLI/automation) or with optional native GTK tray UI. Users never see containers.

## Build Commands

```bash
./build.sh                          # Debug build (auto-creates toolbox if needed)
./build.sh --release                # Release build (musl-static binary)
./build.sh --test                   # Run test suite
./build.sh --check                  # Type-check only
./build.sh --clean                  # Clean + rebuild
./build.sh --clean --release        # Clean release build
./build.sh --install                # Build + install binary to ~/.local/bin/tillandsias
./build.sh --remove                 # Remove installed binary
./build.sh --wipe                   # Remove target/, caches
./build.sh --toolbox-reset          # Destroy and recreate toolbox
```

The build script auto-creates the `tillandsias` toolbox with all system deps on first run. Release builds target `x86_64-unknown-linux-musl` for maximum portability across Linux distros.

### Manual Commands (without build.sh)

```bash
toolbox run -c tillandsias cargo build --workspace
toolbox run -c tillandsias cargo test --workspace
```

## Workspace Structure

```
crates/tillandsias-core/        # Shared types, config, genus system, serialization
crates/tillandsias-scanner/     # Event-driven filesystem watcher (notify crate)
crates/tillandsias-podman/      # Async podman CLI abstraction
crates/tillandsias-headless/    # Musl-static binary: headless mode + optional GTK tray
assets/                         # Icons, SVG tillandsia genera
openspec/                       # Spec-driven development artifacts
images/                         # Container Containerfiles (proxy, git, forge, inference)
```

## Key Architecture Decisions

- **Event-driven, NEVER polling** — `notify` for filesystem, `podman events` for containers, exponential backoff fallback
- **Security flags are non-negotiable** — `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--rm` always applied
- **No JSON in hot paths** — `postcard` for internal IPC, TOML for user config
- **Container naming** — `tillandsias-<project>-<genus>` (e.g., `tillandsias-my-app-aeranthos`)
- **Config-driven** — global at `~/.config/tillandsias/config.toml`, per-project at `.tillandsias/config.toml`
- **Forge image is local** — Tillandsias builds and manages its own forge images. Default image: `tillandsias-forge` (version tag computed at runtime from `forge_image_tag()`)
- **TLS via rustls (pure Rust)** — HTTP clients use `rustls` instead of `native-tls`/OpenSSL. Reason: musl-static requires pure-Rust or fully-vendored statics. rustls is CNCF-audited (Cure53), production-ready (AWS, Google, Cloudflare), and aligns with "event-driven, no new formats" philosophy. Trade-off: +1.5MB binary vs -0.5MB OpenSSL (acceptable for dev tool). See references below.

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
2. **Headless/Tray creates secrets** — At startup, `handlers::setup_secrets()` reads credentials from keyring and creates podman secrets via `podman secret create --driver=file`
3. **Containers mount secrets** — Container launch passes `--secret <name>` flags; secrets appear at `/run/secrets/<name>` inside container with no world-readable file on disk
4. **Cleanup on exit** — On SIGTERM/SIGINT, `handlers::shutdown_all()` calls `podman_secret::cleanup_all()` which removes all `tillandsias-*` secrets before process exit

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

## Headless Mode & GTK Tray

Tillandsias supports three runtime modes, selected transparently based on environment:

**Headless Mode** (default, or `--headless` flag):
- No UI, suitable for CI/CD, automation, and server deployments
- Emits JSON events on stdout: `{"event":"app.started"}`, `{"event":"containers.running","count":N}`, `{"event":"app.stopped"}`
- Graceful shutdown on SIGTERM/SIGINT with configurable timeout (default 30s)
- All container orchestration managed via podman
- Example: `tillandsias --headless /path/to/project`

**Tray Mode** (transparent auto-detection, or `--tray` flag):
- Requires GTK4 runtime + `tray` feature compiled in (`cargo build --release --features tray`)
- Spawns headless subprocess + displays GTK window with project status, logs, container list
- System tray icon (minimize-to-tray)
- Window close or tray quit triggers graceful shutdown of headless process
- Signal forwarding: SIGTERM/SIGINT propagated to headless child
- Example: `tillandsias --tray /path/to/project` or just `tillandsias` (auto-detects GTK)

**Transparent Mode Detection**:
- If `--headless` flag: run headless, no tray
- If `--tray` flag: run tray (requires GTK, feature must be compiled)
- If no flag: auto-detect GTK via pkg-config, choose tray if available, otherwise headless
- Auto-detection allows same binary to work across CI (headless) and desktop (tray) without user configuration

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

Versioning policy is defined by `methodology.yaml` and
`methodology/versioning.yaml`. Do not redefine it here.

```bash
./scripts/bump-version.sh              # Sync all files to VERSION
./scripts/bump-version.sh --bump-build # Increment build number
./scripts/bump-version.sh --bump-changes # Increment change count (after /opsx:archive)
```

## Test Commands

```bash
# Run all tests (native target)
cargo test --workspace

# Run all tests with musl target (portable verification)
cargo test --workspace --target x86_64-unknown-linux-musl

# Run specific crate tests
cargo test -p tillandsias-core
cargo test -p tillandsias-headless

# Test headless mode manually
./target/x86_64-unknown-linux-musl/release/tillandsias-headless --headless /tmp/test-project

# Test with signal handling (5s timeout, then SIGTERM)
timeout 5 ./target/x86_64-unknown-linux-musl/release/tillandsias-headless --headless /tmp/test-project
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

## TLS Strategy (rustls)

### Decision

HTTP clients use **rustls** (pure Rust TLS) instead of `native-tls` + system OpenSSL.

### Why rustls for musl-static?

The challenge: musl-static requires either pure Rust or fully-vendored statics. System libraries like OpenSSL are glibc-compiled and can't be linked into musl binaries.

**Why Nix doesn't provide musl-compatible OpenSSL:**
- Architectural principle: Nix prioritizes reproducibility via **binary caching** (pre-built, fast, cryptographically verified)
- Cross-compiling musl-compatible OpenSSL forces full C toolchain rebuild (30+ min, 10GB disk, breaks cache)
- Nix's design: musl targets should assume pure Rust or use rustls; mixing musl + glibc-OpenSSL is architecturally wrong

**Why rustls is the right choice:**
- Pure Rust: always static, always cached, always portable
- **CNCF-audited** by Cure53 (same auditor for major CNCF projects)
- **Production deployments**: AWS (Firecracker, S3, CloudFront), Google, Cloudflare, Linkerd
- **Security**: zero memory-safety bugs; vastly cleaner than OpenSSL's Heartbleed/stream of CVEs
- **Feature parity**: TLS 1.2/1.3, FIPS (via aws-lc-rs since 0.23), session resumption
- **Alignment**: fits "event-driven, no new formats" philosophy (no C FFI, pure Rust)

### Trade-offs

| Aspect | rustls | OpenSSL |
|--------|--------|---------|
| Binary size | +1.5 MB | -0.5 MB |
| musl-static | ✅ Works | ❌ Breaks |
| Pure Rust | ✅ Yes | ❌ C FFI |
| CNCF audit | ✅ Yes | ❌ No |
| FIPS | ✅ Yes (0.23+) | ✅ Yes |
| Production ready | ✅ Yes | ✅ Yes |

**Verdict**: Binary size increase acceptable for dev tool. rustls wins on all other dimensions for musl-static.

### References

- [RFC 1721: Static CRT linking](https://rust-lang.github.io/rfcs/1721-crt-static.html) — Rust ecosystem consensus on musl+pure-Rust pattern
- [CNCF Rustls Audit & Q1 2026 Performance](https://www.memorysafety.org/blog/26q1-rustls-performance/) — Security audit results and institution backing
- [Rust Blog: musl 1.2.5 update](https://blog.rust-lang.org/2025/12/05/Updating-musl-1.2.5/) — musl targets assume pure Rust
- [Prossimo: Memory Safety Initiative](https://www.memorysafety.org/initiative/rustls/) — Long-term funding and governance

## Related Projects

- `../forge` — Container images (Macuahuitl forge). Tillandsias uses these as default container images.
- `../thinking-service` — Autonomous daemon. Architecture patterns (tokio::select!, event loop) informed Tillandsias design.

## Cheatsheets

Two distinct directories:
- `docs/cheatsheets/` — Tillandsias-internal operational knowledge (tray state machine, secrets management, token rotation). Read by maintainers on the host.
- `cheatsheets/` — agent-facing cheatsheets baked into the forge image at `/opt/cheatsheets/`. Read by agents inside the forge via `cat $TILLANDSIAS_CHEATSHEETS/INDEX.md | rg <topic>`.

Methodology, provenance, traceability, and refresh rules are defined by
`methodology.yaml` and `methodology/cheatsheets.yaml`.

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

## Linux-Only Development

Tillandsias is developed exclusively on Linux (Fedora Silverblue) with the following workflow:

**Build and test:**
```bash
./build.sh --test && cargo clippy --workspace
```

**Version bumps:**
- Follow `methodology.yaml` and `methodology/versioning.yaml`.
- Do not commit local version churn from feature work.
- Release workflows are manual and main-branch only.

**Cargo.lock:** Committed to git (correct for binary projects). If Cargo.lock conflicts at merge time, regenerate: `cargo generate-lockfile`.

## Cloud Workflows — Conservative Usage

See CI/CD section above. Both CI and Release workflows are `workflow_dispatch` only. NEVER auto-trigger. Batch changes, release deliberately.

## Conventions

- User-facing text MUST NOT contain: "container", "pod", "image", "runtime"
- "Attach Here" = launch development environment for a project
- Each environment gets a tillandsia genus name for visual linking
- Plant lifecycle maps to container lifecycle: Pup→Initializing, Mature→Ready, Blushing→Building, Blooming→Complete, Dried→Error
