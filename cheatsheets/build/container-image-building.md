---
tags: [images, building, containerfile, nix, appimage, deployment]
languages: [dockerfile, bash, nix, rust]
since: 260505
last_verified: 2026-05-05
sources: []
authority: internal
status: current
tier: bundled
pull_recipe: null
summary_generated_by: specification
bundled_into_image: false
committed_for_project: false
---

# Container Image Building and Embedding

@trace spec:user-runtime-lifecycle

**Use when**: Understanding how Tillandsias images are built from Containerfiles, direct podman builds, and embedded release assets, and how sources make their way from development to deployed binaries.

## Provenance

- [Podman Build (Podman docs)](https://docs.podman.io/en/latest/markdown/podman-build.1.html) — `podman build` command and Containerfile format
- [Nix Flakes (NixOS docs)](https://nixos.wiki/wiki/Flakes) — Reproducible builds with Nix
- [AppImage Format (AppImage docs)](https://docs.appimage.org/) — Self-contained executables with bundled assets
- [OCI Image Spec](https://github.com/opencontainers/image-spec) — Container image format and metadata
- **Last updated:** 2026-05-05

## Three Image Build Paths

### Path 1: Developer Local Build (`./build.sh`)

**Context**: Developer on Fedora Silverblue with Tillandsias checked out

```
Developer runs: ./build.sh
    ↓
build.sh:
    1. Creates tillandsias toolbox (if needed)
    2. Enters toolbox
    3. Runs: cargo build --release
    4. Runs: scripts/build-image.sh proxy
    5. Runs: scripts/build-image.sh git
    6. Runs: scripts/build-image.sh forge
    7. Runs: scripts/build-image.sh inference
    8. Runs: scripts/build-image.sh chromium-core
    9. Runs: scripts/build-image.sh chromium-framework
    ↓
    scripts/build-image.sh logic:
    1. Check: Does image already exist? Have sources changed?
    2. If unchanged → skip (content hash wins)
    3. If changed → rebuild:
       a. Hash the image source tree under images/<name>/
       b. Run: podman build -f images/proxy/Containerfile (or equivalent)
       c. Tag: tillandsias-proxy:v0.1.37.25
    ↓
Images stored in: Toolbox's podman storage
    ~/.local/share/containers/ (inside toolbox namespace)
    ↓
Output:
    - Binary ready in target/release/tillandsias
    - Images ready in toolbox podman
    - Developer can test locally
```

### Path 2: Cloud Build (GitHub Actions)

**Context**: CI/CD pipeline builds images on GitHub, produces AppImage artifact

```
Developer: git push to GitHub
    ↓
GitHub Actions triggers (manual workflow_dispatch):
    runs: ubuntu-latest
    ↓
Actions setup:
    1. Install podman
    2. Checkout repo (sources available)
    3. Run: scripts/build-image.sh proxy git forge inference chromium-core chromium-framework
    4. Run: cargo build --release --target x86_64-unknown-linux-gnu
    ↓
Build output:
    1. Built local images for all services (proxy, git, forge, etc.)
    2. Release binary (Linux AppImage)
    ↓
Bundling (Tauri AppImage build):
    1. Embed the binary plus any runtime assets required by the release artifact
    2. Create: Tillandsias-v0.1.37.25.AppImage (~500MB-1GB, depending on embedded images)
    ↓
Artifact published: GitHub Releases (AppImage available for download)
    ↓
User: curl https://github.com/tlatoani/tillandsias/releases/download/v0.1.37.25/Tillandsias-v0.1.37.25.AppImage
```

### Path 3: User First Launch (Image Building from Containerfiles)

**Context**: User has installed AppImage, runs Tillandsias for the first time

```
User: tillandsias /path/to/project
    ↓
Tray detects: First launch? Images don't exist?
    ↓
Binary contains: Containerfiles + supporting source (images/proxy/Containerfile, etc.)
    ↓
Tray prepares package cache:
    mkdir -p ~/.cache/tillandsias/packages/
    (directory will hold downloaded RPMs, .deb files, etc.)
    ↓
Tray action:
    Extract Containerfiles and source from binary
    ├─ for image in proxy git forge inference chromium-core chromium-framework:
    │   podman build \
    │     -f images/$image/Containerfile \
    │     -v ~/.cache/tillandsias/packages:/var/cache/tillandsias/packages \
    │     -t tillandsias-$image:v0.1.37.25 .
    ├─ Startup time: 3-10 minutes (building all layers, downloading packages first time)
    └─ Result: Fresh images, built locally from Containerfiles
    ↓
During build (inside container):
    dnf install nginx apache2 ... 
    (dnf caches downloads to /var/cache/tillandsias/packages/)
    (inside container mounts to ~/.cache/tillandsias/packages/ on host)
    ↓
Images stored in: ~/.local/share/containers/ (user's podman local storage)
Package cache: ~/.cache/tillandsias/packages/ (persistent, for bandwidth optimization)
    ↓
Containers created: proxy, git, inference, forge, chromium-core, chromium-framework
    ↓
Tray status: "Ready" ✓

Bandwidth optimization (subsequent launches & updates):
    Same binary version:
    ├─ Check: Do images tillandsias-*:v0.1.37.25 exist locally?
    ├─ Result: YES → reuse cached images (<3 seconds)
    └─ Subsequent launches skip rebuild (image cache hit)
    
    Binary update or cache eviction:
    ├─ Check: Do images tillandsias-*:v0.1.37.25 exist? v0.1.37.26 needed?
    ├─ Result: NO → rebuild (same Containerfile build path)
    ├─ dnf checks /var/cache/tillandsias/packages/ (host-mounted)
    ├─ If packages already cached → dnf uses local files (no re-download)
    ├─ If not cached → dnf downloads, stores in cache
    └─ Old container images removed after new ones ready
    
Package cache staleness:
    User can safely delete: rm -rf ~/.cache/tillandsias/packages/
    Next rebuild: dnf re-downloads packages (same behavior as first launch)
    Cache growth: Packages accumulate; user can clean with staleness metrics
```

## Developer Build System - Direct Podman, Not Nix

**IMPORTANT**: `scripts/build-image.sh` uses direct `podman build` with embedded Containerfiles. The build is source-hash based and does not require Nix.

### Developer Build with Podman
```bash
# Developer toolbox / checkout flow:

scripts/build-image.sh proxy
# Internally:
#   1. Hash the files under images/proxy/
#   2. Run podman build -f images/proxy/Containerfile
#   3. Tag: tillandsias-proxy:v0.1.37.25
```

### Why Podman Here
- **Developer/CI**: Direct podman build matches the user-facing build path and keeps the source of truth in Containerfiles
- **User Runtime**: Only podman + Containerfiles; zero external dependencies beyond podman
- **Distribution**: Binary contains Containerfiles (durable) and sources, not Nix definitions or OCI tarballs

## Containerfile (Dockerfile) Approach

### Example: Proxy Containerfile
```dockerfile
# images/proxy/Containerfile
# @trace spec:proxy-container

FROM fedora:rawhide

RUN dnf install -y squid ca-certificates && dnf clean all

COPY squid.conf /etc/squid/squid.conf
COPY entrypoint.sh /entrypoint.sh

# HEALTHCHECK tells orchestrator when service is ready
HEALTHCHECK --interval=2s --timeout=5s --start-period=5s --retries=15 \
    CMD nc -z 127.0.0.1 3128 || exit 1

ENTRYPOINT ["/entrypoint.sh"]
```

### Building from Containerfile
```bash
podman build -f images/proxy/Containerfile \
  -t tillandsias-proxy:v0.1.37.25 .
```

### Containerfile Model vs Historical Nix Notes

| Aspect | Containerfile build path | Historical Nix path |
|--------|-----|-----|
| **Scope** | User first-launch, binary updates, binary contains them | Archived idea, not the live build path |
| **Dependency** | Only podman (already on user's system) | Would require Nix, but that is not how the current script builds |
| **Portability** | Universal; runs on any podman setup | Not part of the current runtime contract |
| **User Experience** | Transparent: `podman build`, cached locally | Not exposed in the live path |
| **Reproducibility** | Content-hash based source set plus pinned Containerfile base images | Locked by flake.lock, but not used here |

**Correctness Rule**: The live build path uses direct `podman build` against Containerfiles. If a doc or script says `nix build` is required for `scripts/build-image.sh`, that claim is stale.

## AppImage Embedding Strategy

### Option 1: Embed Pre-built OCI Tarballs (Fastest)
```
AppImage contents:
├── Tauri binary (20-50 MB)
├── Embedded images/
│   ├── proxy-v0.1.37.25.tar.gz (50-100 MB)
│   ├── forge-v0.1.37.25.tar.gz (200-400 MB)
│   ├── git-v0.1.37.25.tar.gz (50-100 MB)
│   ├── inference-v0.1.37.25.tar.gz (2-5 GB, with baked ollama models)
│   └── ...
└── Total AppImage: 2.5-6 GB

On first launch:
  for tarball in proxy git forge inference chromium-*:
    podman load < $tarball.tar.gz
  
Startup time: ~30 seconds (IO-bound, extracting tarballs)
```

### Option 2: Embed Containerfiles + Additional Source Files (Flexible)
```
AppImage contents:
├── Tauri binary (20-50 MB)
├── Containerfiles/
│   ├── images/proxy/Containerfile
│   ├── images/git/Containerfile
│   ├── images/forge/Containerfile
│   └── ...
├── scripts/build-image.sh
└── Total AppImage: 50-100 MB

On first launch:
  for image in proxy git forge:
    podman build -f images/$image/Containerfile
    podman tag <content-hash> tillandsias-$image:vX
  
Startup time: ~3-10 minutes (building from sources)
```

### Option 3: Hybrid (Baked + Rebuilds on User System)
```
AppImage contents:
├── Tauri binary
├── Pre-built images:
│   ├── proxy-v0.1.37.25.tar.gz (fastest path)
│   ├── forge-v0.1.37.25.tar.gz
│   └── git-v0.1.37.25.tar.gz (cached images)
├── Containerfiles (for future rebuilds or custom builds)
├── flake.nix (for advanced users)
└── Total AppImage: ~500 MB-1 GB

On first launch:
  # Load pre-built images quickly
  podman load < proxy-v0.1.37.25.tar.gz
  podman load < forge-v0.1.37.25.tar.gz
  
  # Start inference async (larger, takes longer)
  podman load < inference-v0.1.37.25.tar.gz &
  
Startup time: ~30 seconds to ready (proxy + forge), inference loads in background
```

## Source Staleness in Development

### Working Tree Requirement

**IMPORTANT**: `scripts/build-image.sh` hashes the image source files from the working tree under `images/<name>/`. It does not read the git index.

```bash
# Developer edits images/forge/entrypoint.sh

# Next rebuild:
scripts/build-image.sh forge
  ↓
hash images/forge/
  ↓
podman build uses the extracted image sources
  ↓
Result: the local file change is picked up on the next build
```

### Verify Sources Included
```bash
# Show the current image source files on disk:
find images/forge -type f

# Rebuild after editing files in the working tree:
scripts/build-image.sh forge --force
```

## Build Artifact Caching

### Layer Caching (Fast Rebuilds)
```
First build: 5 minutes
├─ Install packages
├─ Download source code
├─ Compile dependencies
└─ Build application

Second build (unchanged sources): <30 seconds
├─ Layer cache hit: reuse installed packages
├─ Layer cache hit: reuse downloaded source
├─ Layer cache miss: rebuild application
└─ Final image reused if hash matches
```

### Incremental Builds (`--force` flag)
```bash
# Normal (incremental):
scripts/build-image.sh forge
# Skips rebuild if image tag already exists and sources unchanged

# Force rebuild (ignoring cache):
scripts/build-image.sh forge --force
# Rebuilds all layers, even if cache would hit
```

## Related Cheatsheets

- `runtime/ephemeral-lifecycle.md` — How images are loaded and cached at runtime
- `runtime/container-image-tagging.md` — Image versioning and staleness detection
- `build/build-lock-semantics.md` — Coordinating concurrent builds
