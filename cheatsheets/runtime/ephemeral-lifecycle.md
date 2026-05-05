# Ephemeral Lifecycle — Container Creation, Caching, and Cleanup

**Use when**: Understanding how Tillandsias manages container creation on first launch, caching across sessions, and cleanup, with the guarantee that the host filesystem remains pristine.

## Provenance

- [Container and Image Lifecycle (Docker docs)](https://docs.docker.com/config/containers/start-containers-automatically/) — How containers start, stop, and persist across sessions
- [Podman Local Storage (Podman docs)](https://docs.podman.io/en/latest/markdown/podman-system.1.html#storage) — How podman manages local image and container storage
- [Linux Ephemeral Filesystems](https://wiki.archlinux.org/title/Tmpfs) — Understanding ephemeral vs persistent storage
- **Last updated:** 2026-05-05

## Core Principle

**Tillandsias never stores permanent state on the host.** Containers are ephemeral (created, used, destroyed), images are cached (reusable but regenerable), and the host system remains completely pristine. On uninstall, only the binary is removed; container artifacts are cleaned separately.

```
Host Filesystem Zones:
├── Permanent (never touched by Tillandsias)
│   ├── ~/src/          (user's project code)
│   ├── ~/.local/bin/   (just the binary installed here)
│   └── ~/.config/      (ZERO Tillandsias config files)
│
├── Ephemeral Cache (safe to delete anytime)
│   └── ~/.cache/tillandsias/
│       ├── packages/           (dnf/apt cached packages, reused across builds)
│       ├── build-logs/         (temporary build logs, cleaned after init)
│       ├── metadata/           (image version tracking, manifests)
│       └── models/             (optional: lazy-pulled LLM models)
│
└── Podman Storage (ephemeral, cleaned by podman system prune)
    └── ~/.local/share/containers/   (container images, volumes, metadata)
```

## Container Lifecycle Stages

### Stage 1: First Launch (Image Creation)
```
User action:     tillandsias /path/to/project
                 ↓
Tray detects:    First run? Check if containers exist in local podman
                 ↓
Result:          Containers NOT found
                 ↓
Action:          Run automatic --init internally
                 ↓
Build process:   Construct proxy, git, inference, forge images
                 Store in:  ~/.local/share/containers/podman/... (podman local storage)
                 Metadata:  ~/.cache/tillandsias/images.json (image versions, tags)
                 ↓
Containers:      Created from images, running in enclave network
                 Store in:  podman ps, container metadata in ~/.local/share/containers/
                 ↓
Tray status:     "Ready" ✓
```

### Stage 2: Cached Session (Reuse)
```
User action:     tillandsias /path/to/project (subsequent runs)
                 ↓
Tray detects:    Containers exist in local podman storage?
                 ↓
Result:          YES, images cached
                 ↓
Action:          Reuse existing images, start containers immediately
                 ↓
Startup time:    <3 seconds (no rebuild)
                 ↓
Tray status:     "Ready" ✓
```

### Stage 3: Cache Invalidation (External Cleanup)
```
Host admin runs: podman system prune -a
                 (or manually deletes ~/.local/share/containers/)
                 ↓
Result:          Container images removed from local storage
                 ↓
Next launch:     User runs: tillandsias /path/to/project
                 ↓
Tray detects:    Images missing
                 ↓
Action:          Rebuild images (identical to Stage 1)
                 Automatic, no user intervention
                 ↓
Startup time:    Minutes (rebuild happens)
                 Tray status:    "Setting up your development environment..."
                 ↓
Tray status:     "Ready" ✓
```

### Stage 4: Binary Update (Container Rebuild)
```
User action:     curl install (updated binary)
                 ↓
Binary:          Updated in ~/.local/bin/tillandsias
                 ↓
Next tray run:   tillandsias
                 ↓
Tray detects:    Version mismatch between binary and cached images
                 Check: Image tag version (e.g., tillandsias-forge:v0.1.37.25)
                        vs Binary version (e.g., tillandsias --version → v0.1.37.26)
                 ↓
Action:          Stop all running containers gracefully
                 Remove old images from podman local storage
                 Build new images with new version tag
                 Tray status:    "Updating your development environment..."
                 ↓
Startup time:    Minutes (rebuild)
                 ↓
Tray status:     "Ready" ✓
```

### Stage 5: Shutdown and Cleanup
```
User action:     Close tray / Quit Tillandsias
                 ↓
Tray action:     shutdown_all()
                 ├── Stop running containers (SIGTERM, grace period, then SIGKILL)
                 ├── Remove containers from podman (podman rm)
                 ├── Keep images in local storage (for next session reuse)
                 └── Destroy enclave network
                 ↓
Host state:      Container images still in ~/.local/share/containers/
                 Cache files still in ~/.cache/tillandsias/
                 (Both are safe for next launch to reuse)
                 ↓
Next session:    Stage 2 (Cached Session) begins
```

## Package Cache Layer (Bandwidth Optimization)

Tillandsias uses a two-layer package caching strategy:

### Layer 1: Container Build Cache (Podman Internal)
```
podman build layer caching:
  FROM alpine:latest          → cached, reuse between builds
  RUN dnf install nginx       → layer cached if dependencies unchanged
  COPY entrypoint.sh /        → cached if source file unchanged
```

### Layer 2: Package Download Cache (Host-Mounted)
```
Host cache directory: ~/.cache/tillandsias/packages/
  ├─ Contains: Downloaded RPMs, .debs, tarballs from previous builds
  ├─ Mounted into container during build: -v ~/.cache/tillandsias/packages:/var/cache/tillandsias/packages
  ├─ Package manager uses: dnf looks in /var/cache/tillandsias/packages/ first
  ├─ Result: If hash matches cached package, no re-download from mirror
  └─ Semantics: Disposable but expensive to regenerate
```

### How It Works

**First build (no cache):**
```
podman build ... -v ~/.cache/tillandsias/packages:/var/cache/tillandsias/packages
├─ Inside container: dnf install nginx
├─ dnf checks: /var/cache/tillandsias/packages/ (empty)
├─ Action: Download nginx RPM from mirror (e.g., fedora.example.com)
├─ Result: Stored in /var/cache/tillandsias/packages/ (host-mounted)
└─ Time: Minutes (network-bound, downloading all packages)
```

**Subsequent build (same versions):**
```
podman build ... -v ~/.cache/tillandsias/packages:/var/cache/tillandsias/packages
├─ Inside container: dnf install nginx
├─ dnf checks: /var/cache/tillandsias/packages/ (has nginx RPM)
├─ Action: Verify hash matches, use cached file
├─ Result: No network request
└─ Time: Seconds (local cache hit)
```

**After binary update (same Containerfile):**
```
Binary v0.1.37.26 (new Containerfile, same dependencies)
├─ podman build with mounted cache
├─ dnf install nginx (same RPM, different mirror possible)
├─ dnf checks: /var/cache/tillandsias/packages/ (still has old nginx RPM)
├─ Verify: Hash matches cached version
├─ Result: Network refresh attempts, but local copy is used
└─ Time: Seconds (cache hit, hash match verified)
```

### Cache Staleness Management

**Acceptable stale scenarios:**
```
~/.cache/tillandsias/packages/ can accumulate:
  ├─ Old RPM versions from previous binary builds
  ├─ Unused packages (no longer in Containerfiles)
  └─ Mirror-specific variants (same content, different source)

User can clean anytime:
  rm -rf ~/.cache/tillandsias/packages/
  (Next rebuild re-downloads, same semantics as first launch)
```

**Staleness metrics** (optional telemetry):
```
Track per package:
  - Last used: when was this RPM last used in a build?
  - Size: how much disk space?
  - Mirror source: which mirror was it fetched from?

Example cleanup policy:
  - Delete packages not used in last 30 days
  - Warn if cache exceeds 1GB
  - Offer one-click "clear unused packages"
```

## Caching Strategy

### What Gets Cached
- **Container images** — Stored in podman local storage (`~/.local/share/containers/`)
  - Reused across sessions
  - Tagged with version: `tillandsias-forge:v0.1.37.25`
  - Rebuilt only on version mismatch

- **Build metadata** — Stored in cache (`~/.cache/tillandsias/`)
  - `.cache/tillandsias/images.json` — manifest of cached images and tags
  - `.cache/tillandsias/init-*.log` — build logs (cleaned after init completes)
  - `.cache/tillandsias/models/` — lazy-pulled LLM models (ollama)

- **Enclave network** — Ephemeral network created at startup
  - Named: `tillandsias-enclave`
  - Destroyed on tray shutdown
  - Recreated on next tray start (fresh network, no state)

### What Is NOT Cached
- **Containers** — Removed on shutdown, recreated on next launch
- **Container volumes** — Ephemeral (user workspace is in /home/ inside forge, lost on container stop)
- **Configuration files** — NEVER stored on host (config is baked into binary or per-project `.tillandsias/config.toml`)
- **Logs** — Stored in cache, cleaned after init completes
- **Host system files** — Zero pollution

## Version Detection and Update Cycle

### Binary Version
```bash
tillandsias --version
# Output: v0.1.37.25
# Source: VERSION file, baked into binary at compile time
```

### Image Tag Version
```bash
podman images | grep tillandsias-forge
# Output: tillandsias-forge:v0.1.37.25 <ID> ...
# Version embedded in image metadata (see spec:init-command)
```

### Version Mismatch Detection
```rust
// In src-tauri/src/handlers.rs (conceptual)
fn check_image_staleness() -> bool {
    let binary_version = env!("TILLANDSIAS_FULL_VERSION");
    let image_tag = format!("tillandsias-forge:v{}", binary_version);
    
    // Check if image exists AND has matching version
    podman_image_exists(&image_tag)
        .is_ok()
}

// If image missing or version mismatch → rebuild
```

### Rebuild on Update
```
Old state:  tillandsias-forge:v0.1.37.25 exists
New state:  Binary updated to v0.1.37.26
            tillandsias-forge:v0.1.37.26 does NOT exist
Result:     Trigger rebuild, discard v0.1.37.25 images
```

## Host Pristineness Guarantee

### Files Tillandsias CAN Create/Modify
- `~/.local/bin/tillandsias` — The binary itself (installation)
- `~/.cache/tillandsias/` — Build cache, logs, temporary metadata (ephemeral)
- `~/.local/share/containers/` — Podman local storage (ephemeral, cleaned by podman)

### Files Tillandsias MUST NEVER Touch
- `~/.config/tillandsias/` — No configuration files here
- `~/.config/containers/registries.conf` — No host-side registry config
- `/etc/containers/` — No system-wide configuration
- User project directories (`.tillandsias/config.toml` is user-written, not deployed by tray)

### Validation
```bash
# After running Tillandsias, verify host pristineness:

# Should be EMPTY (no Tillandsias config):
find ~/.config -name "*tillandsias*"

# Should show ONLY the binary:
ls -la ~/.local/bin/tillandsias*

# Should be ONLY the cache (ephemeral):
du -sh ~/.cache/tillandsias/

# Should be cleaned on tray shutdown:
podman ps -a | grep tillandsias-
# (should show no running/exited containers)
```

## Uninstall and Cleanup

### Minimal Uninstall (Binary Only)
```bash
rm ~/.local/bin/tillandsias
# Host is now completely clean
# Cache and podman storage remain (can be cleaned separately)
```

### Full Cleanup (Cache + Images)
```bash
# Remove cache
rm -rf ~/.cache/tillandsias/

# Remove all Tillandsias container images
podman rmi $(podman images | grep tillandsias | awk '{print $3}')

# Clean podman storage
podman system prune -a
```

## Difference from Traditional Container Apps

| Aspect | Ephemeral (Tillandsias) | Traditional Docker |
|--------|----------|-------------|
| **Config location** | None (baked in binary) | `~/.docker/config.json`, registry configs |
| **Image storage** | `~/.local/share/containers/` (same as normal) | `~/.docker/` (application-specific) |
| **First launch** | Automatic init, images built | User runs `docker pull` manually |
| **Updates** | Binary updates trigger image rebuild | User runs `docker pull` again |
| **Uninstall** | Remove binary, cache auto-cleans | Remove docker, leave images behind |
| **Host pollution** | Zero configuration files | Config files, daemon sockets, networks |

## Related Cheatsheets

- `runtime/container-health-checks.md` — HEALTHCHECK probes and readiness
- `runtime/podman.md` — Podman CLI reference and patterns
- `build/container-image-building.md` — How images are built and embedded
- `build/container-image-tagging.md` — Image version tagging and staleness
