---
tags: [images, versioning, tagging, staleness, podman]
languages: [bash, rust]
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

# Container Image Tagging and Staleness Detection

@trace spec:user-runtime-lifecycle

**Use when**: Understanding how Tillandsias tags images with versions, detects stale images, and rebuilds on version mismatch.

## Provenance

- [Docker Image Tagging Best Practices](https://docs.docker.com/engine/reference/commandline/tag/) — Image naming and version conventions
- [Podman Image Inspection](https://docs.podman.io/en/latest/markdown/podman-image-inspect.1.html) — Querying image metadata
- [OCI Image Format Spec](https://github.com/opencontainers/image-spec) — Standard image metadata (Labels, version info)
- **Last updated:** 2026-05-05

## Image Naming Convention

Tillandsias uses a strict, versioned naming scheme:

```
tillandsias-<image-type>:<version>
│                       │           │
│                       │           └── Version tag (semantic, tied to binary)
│                       └── Image type (proxy, git, forge, inference, chromium-core, chromium-framework)
└── Registry-less bare name (stored in local podman, no docker.io/ prefix)
```

### Examples
```
tillandsias-proxy:v0.1.37.25
tillandsias-forge:v0.1.37.25
tillandsias-git:v0.1.37.25
tillandsias-inference:v0.1.37.25
tillandsias-chromium-core:v0.1.37.25
tillandsias-chromium-framework:v0.1.37.25
```

### Version Format
- **v** — literal prefix (OCI convention)
- **0.1** — Major.Minor (rarely changes; tracks public API stability)
- **37** — Change count (incremented by `/opsx:archive` workflow; tracks OpenSpec convergence)
- **25** — Build number (auto-incremented on every local build; globally monotonic)

**Source**: `VERSION` file at repository root. Baked into binary at compile time via `const TILLANDSIAS_FULL_VERSION`.

```bash
# Check the VERSION file
cat VERSION
# Output: 0.1.37.25

# In Rust, this becomes:
const TILLANDSIAS_FULL_VERSION: &str = "0.1.37.25";

// Image tag generated:
fn forge_image_tag() -> String {
    format!("tillandsias-forge:v{}", env!("TILLANDSIAS_FULL_VERSION"))
    // Returns: "tillandsias-forge:v0.1.37.25"
}
```

## Image Registry Location

All images are **bare-name, unqualified** (no registry prefix):

```
✓ CORRECT:   tillandsias-forge:v0.1.37.25
✗ WRONG:     localhost/tillandsias-forge:v0.1.37.25
✗ WRONG:     docker.io/tillandsias/forge:v0.1.37.25
```

**Why?** Tillandsias images are local-only, built and stored in podman's local storage (`~/.local/share/containers/`). They are never pushed to registries. Bare names tell podman to search local storage first, avoiding registry lookups and TTY prompts.

### Podman Local Storage Path
```
Image metadata:
~/.local/share/containers/storage/libpod/images/containers-conf.d/

Image layers:
~/.local/share/containers/storage/overlay-containers/
```

### Inspect Image Metadata
```bash
# List all Tillandsias images
podman images | grep tillandsias

# Inspect specific image
podman image inspect tillandsias-forge:v0.1.37.25

# Get image ID
podman image inspect tillandsias-forge:v0.1.37.25 --format '{{.ID}}'

# Check if image exists
podman image exists tillandsias-forge:v0.1.37.25 && echo "Found" || echo "Not found"
```

## Staleness Detection and Rebuild

### How Tillandsias Detects Stale Images

**Scenario**: Binary updated from v0.1.37.25 → v0.1.37.26

```rust
// In src-tauri/src/init.rs or handlers.rs
// @trace spec:init-command, spec:user-runtime-lifecycle

fn is_image_stale(image_type: &str) -> bool {
    let current_version = env!("TILLANDSIAS_FULL_VERSION");
    let image_tag = format!("tillandsias-{}:v{}", image_type, current_version);
    
    // Check if image with CURRENT version exists
    match podman_image_exists(&image_tag) {
        Ok(true) => {
            // Image exists AND matches current binary version → NOT stale
            false
        }
        _ => {
            // Image missing OR version doesn't match → STALE
            true
        }
    }
}

// On tray startup:
if is_image_stale("forge") || is_image_stale("git") || is_image_stale("proxy") {
    // Rebuild all images
    run_init_sequence().await?;
}
```

### Staleness Check Flow
```
Tray startup
    ↓
For each image type (proxy, git, forge, inference, chromium-core, chromium-framework):
    ↓
    Query: podman image inspect tillandsias-<type>:v<CURRENT_VERSION>
    ↓
    If image found AND tag matches:
        → Image is FRESH, skip rebuild
    Else:
        → Image is STALE, mark for rebuild
    ↓
If any image marked STALE:
    → Run full init sequence (rebuilds all images)
    → Remove old images (optional: to save space)
Else:
    → Reuse cached images, startup completes in <3s
```

### Multi-Image Atomicity
**Important**: If ANY image is stale, ALL images are rebuilt (not individually). This ensures consistency: all images have the same version tag, no mismatches.

```bash
# Example: After binary update from v25 to v26

# Check current state
podman images | grep tillandsias
# tillandsias-forge:v0.1.37.25
# tillandsias-git:v0.1.37.25
# tillandsias-proxy:v0.1.37.25
# (inference, chromium-* also at v25)

# Tray starts with binary v0.1.37.26
# Detects: tillandsias-forge:v0.1.37.26 does NOT exist

# Action: Rebuild all
podman rmi tillandsias-*:v0.1.37.25  (remove old)
# ... build new images ...
podman build -t tillandsias-forge:v0.1.37.26 .
podman build -t tillandsias-git:v0.1.37.26 .
# ... etc ...

# Result: All images now at v26
```

## Image Build Sources

### Method 1: Embedded in AppImage (Most Common)
```
User installs: ~/Applications/Tillandsias-v0.1.37.26.AppImage
    ↓
AppImage contains:
    ├── Binary (Rust/Tauri executable)
    ├── Containerfiles (images/proxy/Containerfile, images/git/Containerfile, etc.)
    ├── Nix flake definitions (flake.nix, flake.lock)
    └── Build scripts (scripts/build-image.sh)
    ↓
On first launch, tray extracts and builds images:
    $ podman build -f images/proxy/Containerfile -t tillandsias-proxy:v0.1.37.26 .
    $ podman build -f images/git/Containerfile -t tillandsias-git:v0.1.37.26 .
    ↓
Images stored in: ~/.local/share/containers/storage/
```

### Method 2: Serialized Image Data (Pre-built, Faster)
```
User installs: AppImage
    ↓
AppImage contains:
    ├── Binary
    ├── Serialized image tarballs:
    │   ├── tillandsias-proxy-v0.1.37.26.tar.gz
    │   ├── tillandsias-forge-v0.1.37.26.tar.gz
    │   └── ...
    └── Load script
    ↓
On first launch, tray loads images:
    $ podman load -i tillandsias-proxy-v0.1.37.26.tar.gz
    $ podman load -i tillandsias-forge-v0.1.37.26.tar.gz
    ↓
Images appear in local storage immediately (minutes → seconds)
```

### Method 3: Cloud Build (CI/CD)
```
Developer pushes to GitHub
    ↓
GitHub Actions runs: scripts/build-image.sh
    ↓
Images built in Ubuntu container, tagged, and pushed to artifact registry
    ↓
Release workflow downloads images and embeds in AppImage
    ↓
User gets pre-built, ready-to-load images
```

## Staleness and Cache Invalidation

### Cache Invalidation Triggers

| Trigger | What Happens | User Experience |
|---------|-------------|-----------------|
| **Binary updates** | Tray detects version mismatch, rebuilds all images | "Updating your development environment..." (1-3 min) |
| **`podman system prune -a`** | Images deleted from local storage | On next tray launch, automatic rebuild (1-3 min) |
| **User deletes ~/.local/share/containers/** | Same as above | On next tray launch, automatic rebuild |
| **Containerfile modified** | Developer rebuilds via `./build.sh`, new sources in git | Developer toolbox rebuilds, AppImage updated, user gets new binary |
| **Nix flake.lock updated** | Same as above | Automatic rebuild on next user launch |

### Source Staleness Check (Development)
```bash
# In developer toolbox, when building images:
scripts/build-image.sh forge

# Internally checks:
# 1. Does tillandsias-forge:v0.1.37.25 exist? Yes
# 2. Have sources changed since image was built? Hash check
# 3. If sources unchanged → skip rebuild (incremental layer cache wins)
# 4. If sources changed → rebuild, new image

# Result: Incremental builds; unchanged sources skip rebuild
```

## Querying Image Versions

### List All Tillandsias Images
```bash
podman images --filter "reference=tillandsias*"
```

### Get Specific Image Version
```bash
podman image inspect tillandsias-forge:v0.1.37.25 \
  --format '{{.RepoTags}}'
# Output: [tillandsias-forge:v0.1.37.25]
```

### Check Binary vs Image Version Mismatch
```bash
# Binary version
BINARY_VERSION=$(tillandsias --version | grep -oP 'v\K[0-9.]+')
echo "Binary: v$BINARY_VERSION"

# Image version
IMAGE_VERSION=$(podman image inspect tillandsias-forge | \
  grep -oP '"version":"v\K[0-9.]+"' | head -1)
echo "Image:  $IMAGE_VERSION"

# Compare
if [[ "$BINARY_VERSION" == "$IMAGE_VERSION" ]]; then
  echo "✓ Versions match"
else
  echo "✗ Version mismatch — images are stale"
fi
```

## Version Cleanup (Removing Old Images)

### Keep Latest Only
```bash
# Remove all images except the current version
CURRENT=$(tillandsias --version | grep -oP 'v\K[0-9.]+')

podman images | grep "tillandsias.*:v" | awk '{print $3}' | while read ID; do
  if ! podman image inspect "$ID" --format '{{.RepoTags}}' | grep -q "v$CURRENT"; then
    podman rmi "$ID"
  fi
done
```

### Remove All Tillandsias Images
```bash
podman rmi $(podman images | grep tillandsias | awk '{print $3}')
```

## Related Cheatsheets

- `runtime/ephemeral-lifecycle.md` — Container creation, caching, and cleanup lifecycle
- `build/container-image-building.md` — How images are built (Dockerfile, Nix, embedded)
- `build/build-lock-semantics.md` — Coordinating concurrent builds
