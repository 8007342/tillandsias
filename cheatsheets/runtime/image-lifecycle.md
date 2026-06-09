---
tags: [containers, images, podman, oci, lifecycle]
languages: [bash]
since: 2026-05-06
last_verified: 2026-06-08
sources:
  - https://docs.podman.io/en/latest/markdown/podman-image.1.html
  - https://github.com/opencontainers/image-spec
  - https://docs.podman.io/en/latest/markdown/podman-storage.1.html
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# Tillandsias Container Image Lifecycle

@trace spec:user-runtime-lifecycle, spec:init-command, spec:init-incremental-builds, spec:containerfile-staleness
@cheatsheet runtime/user-runtime-install.md, build/container-image-tagging.md

**Use when**: Understanding how images are built, stored, referenced, and cleaned up; debugging image-related issues; or designing image management workflows.

## Provenance

- [Podman Image Management](https://docs.podman.io/en/latest/markdown/podman-image.1.html) — official reference for image operations
- [OCI Image Specification](https://github.com/opencontainers/image-spec) — defines image structure and behavior
- [Podman Storage](https://docs.podman.io/en/latest/markdown/podman-storage.1.html) — how podman stores and manages images locally
- [Container Image Naming](https://docs.podman.io/en/latest/markdown/podman.1.html#image-names) — image name format and resolution
- **Last updated:** 2026-06-08

## Tillandsias Images Overview

| Image | Purpose | Base | Size | Lifecycle |
|-------|---------|------|------|-----------|
| **tillandsias-forge** | Dev environment (code editor, tools, agents) | Fedora Minimal 44 | ~5.7 GB | Build once per source digest, cached |
| **tillandsias-git** | Git mirror + daemon + credentials | Alpine 3.20 | ~77 MB | Build as-needed for --github-login |
| **tillandsias-proxy** | HTTPS caching proxy (squid + SSL bump) | Alpine 3.20 | ~27 MB | Build as-needed, rarely changes |
| **tillandsias-inference** | Ollama CPU binary + local LLM | Fedora Minimal 44 | ~187 MB | Build once per source digest, cached |
| **tillandsias-router** | Caddy reverse proxy and route reload helper | Alpine 3.20 | small | Build once per release, cached |
| **tillandsias-web** | OpenCode web UI runtime | Runtime image context | variable | Build once per release, cached |
| **tillandsias-chromium-core** | Browser isolation core | Runtime image context | variable | Build once per release, cached |
| **tillandsias-chromium-framework** | Browser isolation framework | Runtime image context | variable | Build once per release, cached |

## Build Lifecycle

### 1. Source → Build Inputs

```
images/default/Containerfile (Forge reference documentation)
images/git/Containerfile      (Git service build instructions)
images/proxy/Containerfile    (Proxy build instructions)
images/inference/Containerfile (Inference build instructions)
images/router/Containerfile   (Router build instructions)
images/chromium/Containerfile.core
images/chromium/Containerfile.framework
images/web/Containerfile
```

For installed users these inputs are embedded in the release binary and
materialized to `$XDG_DATA_HOME/tillandsias/runtime/<VERSION>` or the
`~/.local/share/tillandsias/runtime/<VERSION>` fallback. For developers,
`TILLANDSIAS_ROOT` may explicitly point at a checkout to test local image
changes.

### 2. Build (Rust + Podman)

**Trigger**: 
- `tillandsias --init --debug` (explicit: build missing/stale runtime images)
- `scripts/build-image.sh <image>` (canonical developer build engine)
- `build-*.sh` compatibility wrappers delegate to the canonical script
- `./build.sh --ci-full --install` followed by installed-binary init validation
- `tillandsias --github-login` checks if git image exists, builds if missing
- OpenCode/OpenCode Web/tray paths preflight the images they need

**Process**:
```bash
tillandsias --init --debug
```

**Output**:
- Canonical tag: `tillandsias-<name>:<SOURCE_DIGEST>`
- Human aliases: `tillandsias-<name>:v<VERSION>` and `tillandsias-<name>:latest`
- OCI labels include `io.tillandsias.image.source-digest`,
  `io.tillandsias.image.version`, and `io.tillandsias.image.name`
- Example: `tillandsias-forge:v0.1.260505.11`
- Stored in podman's local image storage: `~/.local/share/containers/storage/`

**Staleness Detection**:
- Hashes materialized image context files for each image.
- Compares to `~/.cache/tillandsias/init-build-state.json`.
- Rebuilds when the local image is missing, the previous build failed,
  `--force` is passed, or the image source digest changed.
- A VERSION-only change or missing alias retags the existing canonical image
  without invoking `podman build`.

### 3. Runtime (Container Start)

**Image Reference**:
```rust
tillandsias-forge:v0.1.260505.11
tillandsias-git:v0.1.260505.11
tillandsias-proxy:v0.1.260505.11
tillandsias-inference:v0.1.260505.11
tillandsias-router:v0.1.260505.11
tillandsias-web:v0.1.260505.11
```

**Image Resolution** (podman + registries.conf):
1. Check local storage (podman image DB)
2. If found → use it
3. If not found and `unqualified-search-registries = []` → fail (don't try external registries)
4. If external registry configured → pull from registry

**Container Launch** (rootless):
```bash
podman run \
  --userns=keep-id \
  --cap-drop=ALL \
  tillandsias-forge:v0.1.260505.11
```

### 4. Cleanup

**Manual**:
```bash
podman image rm tillandsias-forge:v0.1.260505.11   # Remove specific version
podman image prune -a                               # Remove all dangling images
```

**Automatic** (in `handlers.rs`):
```rust
pub(crate) fn prune_old_images() {
    // Remove images with old version tags after successful build
    // Keeps disk usage bounded
}
```

## Image Name Format

### Bare (Local) Names
```
tillandsias-forge:v0.1.260505.11
tillandsias-git:v0.1.260505.11
```

**No registry prefix** → podman looks in local storage only
**registries.conf controls whether external registries are searched**

### Fully-Qualified Names (External)
```
docker.io/library/squid:6.1
quay.io/podman/podman:latest
```

**Registry prefix included** → podman knows exact location, no resolution needed

### ⚠️ Incorrect: localhost/ Prefix
```
localhost/tillandsias-forge:v0.1.x     ← WRONG
```

`localhost/` is interpreted as a Docker registry hostname, not a local image marker.
→ Podman tries HTTPS access to `localhost:443`, which fails
→ Use bare names for local images instead

## Staleness & Rebuilds

**Problem**: Images disappear or aren't found
→ Usually because registries.conf is missing or incorrect

**Solution**: Ensure registries.conf exists with:
```toml
unqualified-search-registries = []  # Don't search external registries for local names
short-name-mode = "disabled"         # Fail fast on ambiguous names
```

**Result**:
- `podman run tillandsias-git:v0.1.x` → uses local image (fast, no prompt)
- `podman run docker.io/library/squid:6.1` → pulls from docker.io (explicit)

## Dev Proxy (During Builds)

**Image**: `docker.io/library/squid:6.1` (standard, not tillandsias-proxy)

**Why separate**:
- Tillandsias-proxy is under build, might be broken
- Dev proxy needs to be stable for caching during build
- Standard squid image is widely available, well-tested

**Config**: Uses default squid (no HTTPS bump, no parent peers)

**Lifecycle**:
```
1. Start: podman run docker.io/library/squid:6.1 --name tillandsias-dev-proxy
2. Run: Used as HTTP cache during build (HTTP_PROXY=127.0.0.1:3129)
3. Stop: podman rm tillandsias-dev-proxy (--rm flag auto-removes on exit)
```

## Storage Locations

| Component | Path | Lifecycle |
|-----------|------|-----------|
| **Local images** | `~/.local/share/containers/storage/` | Persistent until pruned |
| **Runtime assets** | `~/.local/share/tillandsias/runtime/<VERSION>/` | Rewritten only when missing/corrupt/stale |
| **Image build state** | `~/.cache/tillandsias/init-build-state.json` | Persistent, tracks success and source digests |
| **Build telemetry** | `$XDG_STATE_HOME/tillandsias/image-build-events.jsonl` | Bounded JSONL decisions and outcomes |
| **Proxy cache** (dev) | `~/.cache/tillandsias/dev-proxy-cache/` | Ephemeral, cleared between builds |
| **CA certificates** (dev) | `~/.cache/tillandsias/ca-*.pem` | Ephemeral, regenerated per build |

## Debugging Commands

```bash
# List all images
podman images

# Inspect image metadata
podman inspect tillandsias-forge:v0.1.260505.11

# Check registries configuration
podman info | grep -A 20 "registries:"
cat ~/.config/containers/registries.conf

# Verify image exists and is loadable
podman image exists tillandsias-forge:v0.1.260505.11 && echo "OK" || echo "NOT FOUND"

# Force rebuild (keeps runtime assets and projects intact)
tillandsias --init --force --debug

# Developer build and explicit no-cache diagnostic
scripts/build-image.sh forge
scripts/build-image.sh forge --force --no-cache

# Inspect structured build telemetry
tail -n 50 "${XDG_STATE_HOME:-$HOME/.local/state}/tillandsias/image-build-events.jsonl"

# Inspect bounded Prometheus projection
curl -fsS http://127.0.0.1:9464/metrics | grep tillandsias_image_build

# Inspect materialized runtime assets
find ~/.local/share/tillandsias/runtime -maxdepth 3 -type f | sort | head

# View image history/layers
podman history tillandsias-forge:v0.1.260505.11
podman image tree tillandsias-forge:v0.1.260505.11
```

## Related Cheatsheets

- `cheatsheets/utils/podman-registries.md` — Short-name resolution and registries.conf configuration
- `cheatsheets/utils/podman-secrets.md` — Credential mounting for containers
- `cheatsheets/runtime/container-lifecycle.md` — Full container lifecycle (create → run → cleanup)
- `cheatsheets/runtime/user-runtime-install.md` — Checkout-free runtime assets and installer PATH contract
