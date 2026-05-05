# Tillandsias Container Image Lifecycle

**Use when**: Understanding how images are built, stored, referenced, and cleaned up; debugging image-related issues; or designing image management workflows.

## Provenance

- [Podman Image Management](https://docs.podman.io/en/latest/markdown/podman-image.1.html) — official reference for image operations
- [OCI Image Specification](https://github.com/opencontainers/image-spec) — defines image structure and behavior
- [Podman Storage](https://docs.podman.io/en/latest/markdown/podman-storage.1.html) — how podman stores and manages images locally
- [Container Image Naming](https://docs.podman.io/en/latest/markdown/podman.1.html#image-names) — image name format and resolution
- **Last updated:** 2026-05-05

## Tillandsias Images Overview

| Image | Purpose | Base | Size | Lifecycle |
|-------|---------|------|------|-----------|
| **tillandsias-forge** | Dev environment (code editor, tools, agents) | Fedora Minimal 44 | ~456 MB | Build once per release, cached |
| **tillandsias-git** | Git mirror + daemon + credentials | Alpine 3.20 | ~77 MB | Build as-needed for --github-login |
| **tillandsias-proxy** | HTTPS caching proxy (squid + SSL bump) | Alpine 3.20 | ~27 MB | Build as-needed, rarely changes |
| **tillandsias-inference** | Ollama + local LLM | Alpine 3.20 | ~300 MB | Build once per release, cached |

## Build Lifecycle

### 1. Source → Build Inputs

```
flake.nix + flake.lock      (Nix reproducible build definition)
images/default/Containerfile (Forge reference documentation)
images/git/Containerfile      (Git service build instructions)
images/proxy/Containerfile    (Proxy build instructions)
images/inference/Containerfile (Inference build instructions)
```

**Key**: Images are git-tracked. Untracked files in `images/*/` are **silently excluded** by Nix.
→ Always `git add` image files before building.

### 2. Build (Nix + Podman)

**Trigger**: 
- `./build.sh --init` (explicit: rebuild all)
- `./build.sh --release` (builds all)
- `tillandsias --github-login` checks if git image exists, builds if missing
- Any `run_build_image_script("git", false)` call

**Process**:
```bash
scripts/build-image.sh forge       # Nix flake build → OCI image → podman load
```

**Output**: Image tagged as `tillandsias-<name>:v<VERSION>`
- Example: `tillandsias-forge:v0.1.260505.11`
- Stored in podman's local image storage: `~/.local/share/containers/storage/`

**Staleness Detection** (`scripts/build-image.sh`):
- Hashes: `flake.nix`, `flake.lock`, image source files
- Compares to cache file: `~/.cache/tillandsias/build-hashes/.last-build-<tag>.sha256`
- **If unchanged**: skips rebuild, uses `--force` to force rebuild

### 3. Runtime (Container Start)

**Image Reference** (from `handlers.rs`):
```rust
tillandsias_forge:v0.1.260505.11
tillandsias-git:v0.1.260505.11
tillandsias-proxy:v0.1.260505.11
tillandsias-inference:v0.1.260505.11
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
| **Image cache** (build) | `~/.cache/tillandsias/build-hashes/` | Persistent, tracks staleness |
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

# Force rebuild (clears staleness cache)
rm ~/.cache/tillandsias/build-hashes/.last-build-*
./scripts/build-image.sh forge

# View image history/layers
podman history tillandsias-forge:v0.1.260505.11
podman image tree tillandsias-forge:v0.1.260505.11
```

## Related Cheatsheets

- `cheatsheets/utils/podman-registries.md` — Short-name resolution and registries.conf configuration
- `cheatsheets/utils/podman-secrets.md` — Credential mounting for containers
- `cheatsheets/runtime/container-lifecycle.md` — Full container lifecycle (create → run → cleanup)

