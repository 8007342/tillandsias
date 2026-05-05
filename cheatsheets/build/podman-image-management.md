---
title: Podman Image Management — Building, Tagging, and Reproducibility
since: "2026-05-03"
last_verified: "2026-05-03"
tags: [podman, image, docker-compatible, build, tag, layer-caching]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# Podman Image Management — Building, Tagging, and Reproducibility

**Version baseline**: Podman 4.5+ (Fedora 43+)  
**Use when**: Building reproducible container images, tagging images for versioning, pushing/pulling from registries, managing image layer cache, understanding Podman's image storage.

## Provenance

- https://docs.podman.io/en/latest/markdown/podman-build.1.html — `podman build` command reference
- https://docs.podman.io/en/latest/markdown/podman-tag.1.html — Image tagging and naming
- https://docs.podman.io/en/latest/markdown/podman-push.1.html — Pushing images to registries
- https://docs.podman.io/en/latest/markdown/podman-load.1.html — Loading images from tarballs (Nix builds)
- https://docs.docker.com/build/building/best-practices/ — Docker image best practices (Podman-compatible)
- https://opencontainers.org/spec/image/ — OCI Image Spec (container image standard)
- **Last updated:** 2026-05-03

## Quick reference: Image Operations

| Command | Effect | Use Case |
|---------|--------|----------|
| `podman build -t <name>:<tag> .` | Build image from Containerfile | Compile image once per deploy |
| `podman tag <image>:<old-tag> <image>:<new-tag>` | Add alias | Version/release tagging |
| `podman push <registry>/<image>:<tag>` | Upload to registry | Share across machines |
| `podman pull <registry>/<image>:<tag>` | Download from registry | CI/deployment |
| `podman load -i image.tar` | Load from tarball (Nix) | Deploy pre-built artifacts |
| `podman images` | List all images | Inventory and cleanup |
| `podman image rm <image>:<tag>` | Delete image | Free disk space |
| `podman inspect <image>` | Show image metadata | Debug builds, inspect layers |
| `podman image prune` | Delete dangling images | Cleanup |

## Image Naming Convention

Tillandsias uses consistent naming for reproducibility and versioning.

```
<registry>/<namespace>/<name>:<tag>

Examples:
──────────
docker.io/tillandsias/forge:v0.1.37.25          (public registry)
localhost:5000/tillandsias-forge:v0.1.37.25     (local registry)
tillandsias-forge:v0.1.37.25                    (default, no registry prefix)
```

### Version Tag Format

```
v<Major>.<Minor>.<ChangeCount>.<Build>

v0.1.37.25
├─ Major: 0 (breaking changes)
├─ Minor: 1 (new features)
├─ ChangeCount: 37 (number of OpenSpec changes merged)
└─ Build: 25 (local build increment)
```

**Tillandsias images:**
```bash
tillandsias-forge:v0.1.37.25          # Dev environment
tillandsias-proxy:v0.1.37.25          # HTTP/HTTPS proxy
tillandsias-git:v0.1.37.25            # Git mirror service
tillandsias-inference:v0.1.37.25      # Ollama inference
tillandsias-chromium-core:v0.1.37.25  # Headless browser
tillandsias-chromium-framework:v0.1.37.25  # GUI browser
```

All images at same version = coherent release; **cross-version image pairs are NOT supported**.

## Building Images Reproducibly

### Method 1: Podman Build (Docker-Compatible)

```bash
# Standard Dockerfile/Containerfile build
podman build -t tillandsias-forge:v0.1.37.25 \
  --file=images/forge/Containerfile \
  --build-arg VERSION=0.1.37.25 \
  .
```

**Reproducibility concerns:**
- `FROM <image>` pin must include tag (e.g., `ubuntu:24.04`, not `ubuntu:latest`)
- RUN commands must be deterministic (no time-based operations)
- Build context (`.`) must be identical (use git-staging or source manifest)
- Build args should be explicit (no defaults at build time)

### Method 2: Nix Build (Tillandsias Preferred)

Nix images are byte-for-byte reproducible; same source = identical binary output.

```bash
# Via flake.nix (in tillandsias repo)
nix build ./images#forge-image
# Output: result → tarball with image

# Load into Podman
podman load < result
podman tag tillandsias-forge:tmp tillandsias-forge:v0.1.37.25
```

**Advantages:**
- Deterministic inputs (pinned nixpkgs version in flake.lock)
- Identical output across machines (same flake.lock = same binary)
- Reproducible from 2 years ago (nixpkgs is immutable)

See `scripts/build-image.sh` for Tillandsias-specific Nix build flow.

## Layer Caching Strategy

### Layer Cache Behavior

```dockerfile
# Each RUN, COPY, ADD, etc. is a layer
FROM ubuntu:24.04                              # Layer 1 (base image, always cached)
RUN apt-get update && apt-get install -y ...   # Layer 2 (time-based, often cache miss)
COPY app.sh /app/app.sh                        # Layer 3 (source-based, changes = cache miss)
RUN ./app.sh                                   # Layer 4 (depends on Layer 3)
```

**Cache hit/miss logic:**
- Layer 1 (FROM): Cache hit if base image unchanged
- Layer 2 (RUN apt-get): Cache MISS if any prior layer changed or RUN instruction hash differs
- Layer 3 (COPY): Cache MISS if source file hash differs
- Layer 4 (RUN ./app.sh): Cache MISS if Layer 3 missed

### Optimization: Install Dependencies First

```dockerfile
# BAD: changes to app.sh cause full reinstall
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y go gcc    # ~10 seconds
COPY app.sh /app/
RUN ./app.sh

# GOOD: app.sh changes don't rebuild tools
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y go gcc    # cached (10s saved)
COPY app.sh /app/
RUN ./app.sh                                        # only this rebuilds
```

**Caching principle**: Put slow (system packages), stable operations **before** fast (app source) operations.

## Multi-Stage Builds (Reducing Image Size)

```dockerfile
# Stage 1: Build (heavy, temporary)
FROM golang:1.23 AS builder
COPY . /src
WORKDIR /src
RUN go build -o /tmp/app .

# Stage 2: Runtime (lean, final image)
FROM ubuntu:24.04
COPY --from=builder /tmp/app /app/bin/app
ENTRYPOINT ["/app/bin/app"]
```

**Effect:**
- Final image excludes Go compiler, build tools (~1.5GB)
- Only runtime binary included (~50MB)
- Layer cache applies per-stage (builder stage cache independent of runtime stage)

## Tagging for Releases

```bash
# Tag a built image for release
podman tag tillandsias-forge:tmp tillandsias-forge:v0.1.37.25  # Version
podman tag tillandsias-forge:tmp tillandsias-forge:latest      # Latest alias

# Push all tags
podman push docker.io/tillandsias/forge:v0.1.37.25
podman push docker.io/tillandsias/forge:latest
```

**Registry structure:**
```
docker.io/tillandsias/forge
├── v0.1.36.20 (older release)
├── v0.1.37.25 (current release)
└── latest → v0.1.37.25 (alias)
```

**Pulling specific versions:**
```bash
podman pull docker.io/tillandsias/forge:v0.1.37.25  # Specific version
podman pull docker.io/tillandsias/forge:latest      # Latest
```

## Image Storage and Cleanup

### Disk Space Usage

```bash
# Show all images
podman images

# Check image size
podman inspect tillandsias-forge:v0.1.37.25 --format '{{.Size}}'

# Total size of all images
podman images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | awk '{sum+=$NF} END {print sum}'
```

### Dangling Images (Cleanup)

```bash
# Find unused images
podman image prune -a --dry-run

# Remove unused images
podman image prune -a --force

# Remove specific image
podman rmi tillandsias-forge:v0.1.35.10
```

### Storage Driver

Podman stores images in `~/.local/share/containers/storage/` (rootless) or `/var/lib/containers/` (rootful).

```bash
# Check storage backend
podman info | grep -i "storage"
# Output: Storage Driver: overlay

# Manually prune storage
podman system prune -a -f  # Remove all unused images, volumes, containers
```

## Tillandsias Build Workflow

```bash
# 1. Update VERSION file
echo "0.1.37.25" > VERSION

# 2. Build all images (via Nix)
./scripts/build-image.sh forge
./scripts/build-image.sh proxy
./scripts/build-image.sh git
./scripts/build-image.sh inference

# 3. Tag with version
for img in forge proxy git inference; do
  podman tag tillandsias-$img:tmp tillandsias-$img:v0.1.37.25
done

# 4. Test images locally
./build.sh --test

# 5. Push to registry (if public)
./scripts/push-images.sh v0.1.37.25

# 6. Release (update GitHub releases)
gh release create v0.1.37.25 --notes "Release notes..."
```

## Reproducibility Checklist

- [ ] `FROM <image>:<tag>` pins exact base image version
- [ ] `flake.lock` committed (if Nix build)
- [ ] `Containerfile` deterministic (no time-based operations)
- [ ] Build args explicit in `scripts/build-image.sh` (not defaults)
- [ ] Source files git-staged before build (Nix: only sees staged files)
- [ ] Image tag includes version (e.g., `v0.1.37.25`, not `latest`)
- [ ] Test: two builds from same source produce identical image layers

## Common pitfalls

- **`FROM latest` base image** — `latest` changes; rebuilds have different base. Always pin tag: `FROM ubuntu:24.04`, not `FROM ubuntu:latest`.
- **Forgetting layer cache** — rebuilding entire image unnecessarily. Reorder Dockerfile to cache expensive operations (package installs) before cheap ones (source copies).
- **Huge layer sizes** — multi-stage builds reduce this, but `RUN rm -rf /tmp/*` in same layer doesn't shrink layer (deletes are recorded, not shrunk). Use separate layer: `RUN apt-get clean && rm -rf /var/lib/apt/lists/*`.
- **Image pushed to wrong registry** — `podman push` without explicit registry defaults to docker.io. Specify full path: `podman push localhost:5000/tillandsias-forge:v0.1.37.25`.
- **Version mismatch across images** — e.g., forge v0.1.37.25 + proxy v0.1.36.20. Incompatible! Always build all images from same VERSION file.
- **Forgetting to tag after build** — built image exists but has no name (dangling). Always `podman tag <image-id> <name>:<tag>` immediately after build.

## See also

- `build/nix-flake-caching.md` — Nix build caching for reproducible image construction
- `runtime/container-lifecycle.md` — Container startup from images
- `scripts/build-image.sh` — Tillandsias image build automation
- https://docs.podman.io/en/latest/ — Full Podman documentation
