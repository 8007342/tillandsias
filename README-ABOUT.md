# Tillandsias — Architecture, Configuration, and Development

This document provides a deep dive into Tillandsias architecture, configuration options, and development workflows.

## Quick Links

| Topic | Document |
|-------|----------|
| **Architecture Overview** | [Enclave Architecture](docs/cheatsheets/enclave-architecture.md) |
| **Container Lifecycle** | [Container Lifecycle](docs/cheatsheets/container-lifecycle.md) |
| **Cache Semantics** | [Cache Semantics Implementation](CACHE_SEMANTICS_ARCHITECTURE.md) |
| **Release Workflow** | [Release Notes](RELEASE-NOTES.md) |
| **OpenCode Integration** | [OpenCode CLI Implementation](docs/OPENCODE-INTEGRATION-COMPLETED.md) |
| **Secrets & Credentials** | [Secrets Architecture](docs/SECRETS.md) |

## Architecture at a Glance

Tillandsias orchestrates **four containerized services** (proxy, git, inference, forge) in an isolated enclave:

```
                          ┌─────────────────────────────────────┐
                          │   tillandsias-enclave (--internal)  │
                          │                                     │
  ┌──────────┐            │  ┌───────┐ ┌───────┐ ┌──────────┐ │
  │ internet │◄──bridge───┤  │proxy  │ │git    │ │inference │ │
  │          ├──bridge───►│  │:3128  │ │mirror │ │(ollama)  │ │
  └──────────┘            │  └───────┘ └───────┘ └──────────┘ │
                          │       ▲        ▲           ▲      │
                          │       │        │           │      │
                          │  ┌────┴────────┴───────────┴────┐ │
                          │  │        forge (you)          │ │
                          │  │ (NO credentials, NO net)    │ │
                          │  └─────────────────────────────┘ │
                          │                                  │
                          └─────────────────────────────────┘
                                     ▲
                                     │ D-Bus
                                     ▼
                          ┌──────────────────────┐
                          │  host keyring        │
                          │  (GitHub tokens)     │
                          └──────────────────────┘
```

**Key Properties:**
- **Forge container**: Where you work. Has ZERO credentials, ZERO external network access.
- **Proxy container**: Caching HTTP/HTTPS proxy (Squid). All external traffic flows through here.
- **Git service container**: Stores GitHub tokens. Fetches/pushes on your behalf via D-Bus → host keyring.
- **Inference container**: Runs ollama. Provides local LLM models (no cloud, no tokens).

For full details, see [Enclave Architecture](docs/cheatsheets/enclave-architecture.md).

## Configuration

Tillandsias uses two levels of configuration:

### Global Configuration

Location: `~/.config/tillandsias/config.toml`

```toml
# Example global config
[runtime]
headless = false  # Prefer headless mode (no tray UI)

[models]
default_tier = "mid"  # T0, T1, mid, high, ultra
keep_alive = "24h"    # How long to keep models loaded
```

### Per-Project Configuration

Location: `.tillandsias/config.toml` (in your project root)

```toml
# Per-project overrides
[runtime]
mount_rw = ["src/", ".git/"]  # Which directories get RW access
mount_ro = ["docs/", "README.md"]  # Read-only mounts

[forge]
tools = ["rust", "node", "python"]  # Which dev tools to include
```

See `CLAUDE.md` for complete configuration reference.

## Next Steps for New Users

### Getting Started Quickly

**Option A: Initialize a Project**
```bash
# Create a new managed project
tillandsias --init ~/my-project

# Tillandsias will:
# - Create .tillandsias/config.toml with project defaults
# - Generate README.md using FOR HUMANS/FOR ROBOTS structure
# - Install pre-push hooks for automated README updates
```

**Option B: Read the Onboarding Guide**
```bash
# Inside the forge, read the structured onboarding guide
cat $TILLANDSIAS_CHEATSHEETS/welcome/readme-discipline.md

# Or browse all cheatsheets
cat $TILLANDSIAS_CHEATSHEETS/INDEX.md | grep welcome
```

**Option C: Run Sample Commands**
```bash
# Inside the forge (after `tillandsias /your/project`)
tillandsias-inventory    # See all available tools and languages
tillandsias-services     # Check enclave endpoints (proxy, git, inference)
tillandsias-models       # View available LLM models and tiers
```

### Multi-Workspace Setup

Tillandsias supports managing multiple projects independently:

```bash
# Terminal 1: Work on project A
tillandsias ~/src/project-a

# Terminal 2: Work on project B (separate environment)
tillandsias ~/src/project-b

# Terminal 3: Work on project C (isolated container, no state leakage)
tillandsias ~/src/project-c
```

**Key properties**:
- Each project gets its own forge container
- No credentials shared between projects
- Code changes are ephemeral (lost on container stop)
- Git history is shared (read from enclave mirror)
- Git auth handled centrally (via host keyring)

**Git Worktrees**: Tillandsias also detects git worktrees as separate projects:
```bash
cd ~/src/main-project
git worktree add feature-branch
tillandsias ~/src/main-project/feature-branch  # Works correctly!
```

### Troubleshooting

**Problem: "Container failed to start"**
- Check: `tillandsias --diagnostics /your/project`
- Verify: `podman ps` shows no stale containers
- Fix: `tillandsias --reset /your/project` (recreates enclave)

**Problem: "GPU not detected"**
- Inside forge, run: `nvidia-smi`
- Check: `tillandsias-models` shows available model tiers
- Host issue: Verify `nvidia-smi` works on host before launching forge

**Problem: "Missing model for inference tier"**
- Models are lazy-pulled after forge starts
- Check: `ls ~/.cache/tillandsias/models/` for downloaded models
- Manual pull: `ollama pull qwen2.5-coder:7b` on host (faster)

**Problem: "Git push fails in forge"**
- Forge has NO credentials (by design)
- Git auth via git-service container (reads from host keyring)
- Fix: Ensure GitHub token is in `secret-tool` or GNOME Keyring
- Test: `tillandsias-services` shows git-service endpoint

---

## Development

### Building from Source

```bash
# Debug build (auto-creates toolbox on Silverblue)
./build.sh

# Release build (musl-static, portable across Linux distros)
./build.sh --release

# Run tests
./build.sh --test

# Install to ~/.local/bin/tillandsias
./build.sh --install
```

### Project Structure

```
crates/tillandsias-core/        # Shared types, config, serialization
crates/tillandsias-podman/      # Async podman abstraction
crates/tillandsias-headless/    # CLI + GTK tray UI
crates/tillandsias-scanner/     # Filesystem watcher
docs/cheatsheets/               # Operational knowledge
images/                         # Container Containerfiles
openspec/                       # Spec-driven development artifacts
```

### Key Design Decisions

- **Event-driven, never polling**: Uses `notify` crate for filesystem, `podman events` for containers
- **No JSON in hot paths**: Postcard for IPC, TOML for user config
- **Ephemeral-first security**: Podman secrets auto-cleanup, no disk writes
- **Transparent mode detection**: Binary chooses tray (if GTK available) or headless automatically

See `CLAUDE.md` and `methodology.yaml` for full design principles.

## Image Building

Container images are built reproducibly using Nix inside a dedicated builder toolbox:

```bash
# Build the forge (dev environment) image
scripts/build-image.sh forge

# Build all images
for image in forge proxy git inference; do
  scripts/build-image.sh $image
done
```

Images are tagged as `tillandsias-<name>:v<VERSION>` and include:
- **Proxy**: Squid 6.x, CA bundle generation, SSL-bump MITM
- **Git service**: Git daemon, OAuth token support, D-Bus bridge
- **Forge**: Dev tools (Rust, Python, Node, etc.), Nix + direnv
- **Inference**: Ollama, pre-loaded models (T0/T1), lazy-pull (T2–T5)

## Secrets & Credentials

Tillandsias uses **ephemeral podman secrets** for credential isolation:

1. **Host keyring** stores GitHub tokens (GNOME Keyring / KDE Wallet / macOS Keychain)
2. **Git service container** reads tokens from keyring via D-Bus
3. **Forge container** has NO secrets, NO credentials
4. **Secrets auto-cleanup** on Tillandsias shutdown

See [Secrets Architecture](docs/SECRETS.md) for implementation details.

## Versioning

Version format: `v<Major>.<Minor>.<ChangeCount>.<BuildIncrement>`

Example: `v0.1.260505.29`

- **Major.Minor**: Feature releases (infrequent)
- **ChangeCount**: Number of OpenSpec changes merged (increments per spec)
- **BuildIncrement**: Local builds (auto-increments, high counts normal)

See `methodology/versioning.yaml` for versioning policy.

## Testing

### Smoke Tests

Before release, run the smoke test suite:

```bash
./scripts/smoke-test.sh
```

This verifies:
- Image builds succeed
- Containers start and stop cleanly
- Enclave networking works
- Git/proxy/inference services respond
- Forge can execute commands

### Unit Tests

```bash
cargo test --workspace --target x86_64-unknown-linux-musl
```

### Integration Tests

Located in `crates/*/tests/`. Run with `cargo test --test '*'`.

## Release Workflow

Releases are **manual only** (never auto-triggered). To release:

```bash
# 1. Bump version
./scripts/bump-version.sh --bump-changes

# 2. Tag locally
git tag v0.1.260505.30

# 3. Trigger release workflow (manual)
gh workflow run release.yml -f version="0.1.260505.30"

# 4. Wait for CI to build and sign artifacts
# (Check: https://github.com/8007342/tillandsias/actions)

# 5. GitHub Actions creates the release automatically
```

See [Release Notes](RELEASE-NOTES.md) for changelog.

## Observability

### Logging

Tillandsias emits structured logs with `@trace` annotations:

```bash
# Real-time logs (with filtering)
tillandsias --diagnostics /path/to/project

# Structured logs with timestamps
RUST_LOG=debug ./target/debug/tillandsias-headless --headless /project
```

### Traces

Every feature and bug fix includes a `@trace spec:<name>` annotation in code. Traces link implementation to OpenSpec specifications:

```bash
# Find all traces for a spec
git log -p | grep -A 5 "@trace spec:enclave-network"
```

See `TRACES.md` for the full trace index.

## Contributing

1. **Read methodology.yaml** — Defines OpenSpec discipline, trace rules, versioning
2. **Follow CLAUDE.md** — Project conventions, build commands, architecture
3. **Use OpenSpec** — Create specs for every change (`/opsx:ff` or `/opsx:new`)
4. **Add traces** — Annotate code with `@trace spec:<name>`
5. **Test locally** — Run `./build.sh --test` before pushing

## FAQ

**Q: Can I run Tillandsias on macOS or Windows?**  
A: Linux is the source of truth. macOS and Windows support is planned via thin platform wrappers.

**Q: Does Tillandsias send data to the cloud?**  
A: No. All containers run locally. Proxy and Git service have no external network (except proxy for your allowlist). Inference runs ollama locally.

**Q: Can I use my own container images?**  
A: Yes. Override via `~/.config/tillandsias/config.toml` or `.tillandsias/config.toml` in your project.

**Q: How do I update Tillandsias?**  
A: Use the built-in auto-updater (`tillandsias --check-update`) or reinstall from the latest release. See [UPDATING.md](docs/UPDATING.md).

**Q: How are credentials managed?**  
A: GitHub tokens live in your OS keyring. The git-service container reads them via D-Bus and authenticates on your behalf. The forge container never sees any credentials. See [SECRETS.md](docs/SECRETS.md).

## Links

- **Homepage**: https://github.com/8007342/tillandsias
- **Releases**: https://github.com/8007342/tillandsias/releases
- **Issues**: https://github.com/8007342/tillandsias/issues
- **Verification**: [VERIFICATION.md](docs/VERIFICATION.md)

---

**Last updated:** 2026-05-14
