---
title: Forge Cache Semantics
use_when: Managing cache directories, understanding staleness detection, debugging cache misses or pollution
tier: bundled
committed_for_project: true
---

# Forge Cache Semantics

**Use when**: Understanding how Tillandsias manages build artifacts, debugging cache staleness, or implementing cache cleanup strategies.

## Provenance

- `openspec/specs/forge-cache-dual/spec.md` — Dual-cache architecture specification
- `openspec/specs/forge-staleness/spec.md` — Cache staleness detection and refresh
- `images/default/lib-common.sh` — Implementation of cache paths and staleness helpers
- **Last updated:** 2026-05-14

---

## Four Path Categories

Forge containers organize all filesystem access into four distinct categories, each with its own staleness policy and isolation guarantee:

### 1. Shared Cache (RO): `/nix/store/`

**Mount**: Read-only bind-mount from host's `/nix/store/`  
**Populated by**: Nix (only) — no other tool writes here  
**Staleness**: NEVER stale — versioned by image tag  
**Isolation**: N/A (shared across all projects)  
**Size limit**: Host disk (no container-level cap)

```bash
# Inside container (read-only)
ls -la /nix/store/
# Typical contents: cached tool dependencies, compiled libraries, dev tools
```

**Why Nix-only?**
- Content-addressed storage prevents conflicts (same input = same hash)
- Tools like Maven, npm, Cargo that write here would conflict with each other
- Single source of truth for shared dependencies

### 2. Per-Project Cache (RW): `/home/forge/.cache/tillandsias-project/`

**Mount**: Bind-mount from host's `~/.cache/tillandsias/<project>/`  
**Populated by**: Package managers (Cargo, npm, Maven, Gradle, pip, Go, etc.)  
**Staleness**: Checked at container launch; stale if image version differs  
**Isolation**: Per-project only — project A cannot see project B's cache  
**Size limit**: Host disk (no container-level cap)

```bash
# Inside container
export CARGO_HOME="/home/forge/.cache/tillandsias-project/cargo"
export npm_config_cache="/home/forge/.cache/tillandsias-project/npm"
export GOPATH="/home/forge/.cache/tillandsias-project/go"
# ... other language tools follow the same pattern

# Building persists artifacts across container restarts (same project)
cargo build      # downloads ~200 MB on first run
# (container stops, restarts)
cargo build      # CACHE HIT — zero bytes downloaded
```

**Standard subdirectories**:

| Language/Tool | Env var | Path |
|---|---|---|
| Cargo | `CARGO_HOME` | `cargo/` |
| Go | `GOPATH` | `go/pkg/mod/` |
| npm | `npm_config_cache` | `npm/` |
| pip | `PIP_CACHE_DIR` | `pip/` |
| Maven | `MAVEN_OPTS -Dmaven.repo.local=` | `maven/` |
| Gradle | `GRADLE_USER_HOME` | `gradle/` |
| Yarn | `YARN_CACHE_FOLDER` | `yarn/` |
| pnpm | `PNPM_HOME` | `pnpm/` |
| uv | `UV_CACHE_DIR` | `uv/` |
| Flutter/Dart | `PUB_CACHE` | `pub/` |

### 3. Project Workspace: `/home/forge/src/<project>/`

**Mount**: Bind-mount from host's user working tree  
**Content**: Source code (git repo) — NO build artifacts  
**Staleness**: User-managed; never touched by tray  
**Isolation**: Per-project (each project is a separate bind-mount)  
**Persistence**: Committed to git; survives container stop

```bash
# Inside container — your project source
cd /home/forge/src/my-app
cat package.json    # your code
ls -la .git/        # your history

# Build artifacts MUST redirect to per-project cache
cargo build    # target/ → /home/forge/.cache/tillandsias-project/cargo/target/
npm install    # node_modules/ → (if using workspaces, may need manual config)
```

**Anti-pattern**: Build artifacts under the workspace pollute the project directory and get committed to git. Always use env vars to redirect (Cargo, Gradle, Maven all support this).

### 4. Ephemeral: `/tmp`, `/run/user/1000`, and unmounted home dirs

**Mount type**: tmpfs with kernel-enforced size caps  
**Staleness**: N/A — always fresh (wiped per container stop)  
**Isolation**: Per-container (lost on stop)  
**Size limits**:
- `/tmp`: 256 MB (kernel-enforced via `--tmpfs`)
- `/run/user/1000`: 64 MB (kernel-enforced via `--tmpfs`)
- Unmounted home dirs: Unbounded (container's overlayfs upper-dir, backed by host disk)

```bash
# Inside container — ephemeral scratch space
echo "test" > /tmp/scratch.txt     # 256 MB hard limit
echo "test" > ~/.cache/temp.txt    # Unbounded (if ~/.cache is not bind-mounted)

# Writing > 256 MB to /tmp fails with ENOSPC
dd if=/dev/zero of=/tmp/huge.bin bs=1M count=300  # Error: No space left on device
```

---

## Cache Staleness Detection

### How Staleness Works

1. **Initial attach**: Tray records image version in `~/.cache/tillandsias/<project>/VERSION`
   ```bash
   # After first attach
   cat ~/.cache/tillandsias/my-app/VERSION
   # v0.1.169.226
   ```

2. **On subsequent attach**: Container checks if recorded version matches running image
   ```bash
   # Container launch compares:
   cache_version=$(cat ~/.cache/tillandsias/my-app/VERSION)
   image_version="v0.1.169.227"  # image tag at runtime
   [ "$cache_version" != "$image_version" ] && echo "CACHE STALE"
   ```

3. **If stale**: Log a warning; user can manually clear cache or rebuild to refresh
   ```bash
   # Manually clear stale cache (preserves workspace)
   rm -rf ~/.cache/tillandsias/my-app/
   # Next attach re-establishes fresh cache
   ```

### Staleness Rules

| Path | Stale if |
|---|---|
| `/nix/store/` | Never — image version controls staleness |
| `~/.cache/tillandsias/<project>/` | Image version differs from recorded VERSION |
| `/home/forge/src/<project>/` | N/A (user-managed) |
| Ephemeral | N/A (always fresh) |

### Scenario: Image Upgrade

```
Project: my-app
Current cache version: v0.1.169.224
Running image version: v0.1.169.226 (after binary upgrade)

At next attach:
  [cache] WARN: cache for project my-app is stale
  [cache] recorded version v0.1.169.224 != v0.1.169.226
  [cache] recommend: rm -rf ~/.cache/tillandsias/my-app/
  [cache] attach continues; cache persists but may have incompatible artifacts

After user clears cache:
  rm -rf ~/.cache/tillandsias/my-app/
  (next attach)
  [cache] fresh cache established, version v0.1.169.226 recorded
  cargo build  # clean rebuild, all deps re-downloaded
```

---

## Implementation in lib-common.sh

### Cache Path Constants (Exported)

```bash
# Shared cache (RO image layer)
export TILLANDSIAS_SHARED_CACHE="/nix/store"

# Per-project cache (RW bind-mount)
export TILLANDSIAS_PROJECT_CACHE="/home/forge/.cache/tillandsias-project"

# Project workspace (RO user source)
export TILLANDSIAS_WORKSPACE="/home/forge/src"

# Ephemeral scratch
export TILLANDSIAS_EPHEMERAL="/tmp"
```

### Cache Staleness Functions

```bash
# Check if per-project cache is stale
# Returns 0 (true/stale) if version file missing or versions differ
# Returns 1 (false/fresh) if versions match
cache_is_stale <project_name> <image_version>

# Record image version for future staleness checks
# Called once at first attach per project
record_cache_version <project_name> <image_version>
```

### Example: Checking Staleness (inside container)

```bash
#!/usr/bin/env bash
# In an entrypoint script

source /usr/local/lib/tillandsias/lib-common.sh

PROJECT_NAME="my-app"
IMAGE_VERSION="v0.1.169.226"

if cache_is_stale "$PROJECT_NAME" "$IMAGE_VERSION"; then
    echo "⚠ Cache is stale for $PROJECT_NAME"
    echo "  Recorded version: $(cat ~/.cache/tillandsias/$PROJECT_NAME/VERSION 2>/dev/null || echo unknown)"
    echo "  Current image: $IMAGE_VERSION"
    echo "  Run: rm -rf ~/.cache/tillandsias/$PROJECT_NAME/"
else
    echo "✓ Cache is fresh"
fi

# Record for next time (idempotent)
record_cache_version "$PROJECT_NAME" "$IMAGE_VERSION"
```

---

## Practical Workflows

### Scenario: First Time Attach

```bash
# User runs (from host)
tillandsias --attach ./my-app

# Tray does (inside attach handler):
# 1. Launch forge container
# 2. Container entrypoint sources lib-common.sh
# 3. lib-common.sh exports TILLANDSIAS_PROJECT_CACHE
# 4. Tray records: echo "v0.1.169.226" > ~/.cache/tillandsias/my-app/VERSION
# 5. Container continues; agent runs

# Inside container, cargo/npm/etc. use env vars:
echo $CARGO_HOME      # /home/forge/.cache/tillandsias-project/cargo
echo $npm_config_cache # /home/forge/.cache/tillandsias-project/npm
```

### Scenario: Cache Miss / Rebuild

```bash
# User wants to force rebuild (clear cache)
rm -rf ~/.cache/tillandsias/my-app/

# Next attach:
# Container launch finds no VERSION file → cache_is_stale returns true
# Log warning, but continue (non-blocking)
# Tray records fresh VERSION marker
# Tools rebuild from scratch

cargo build  # re-downloads all dependencies
npm install  # re-downloads all packages
```

### Scenario: Multi-Project Isolation

```bash
# Two projects, two separate cache trees
ls ~/.cache/tillandsias/
  project-a/        # Cargo, npm, etc. for project A
  project-b/        # Cargo, npm, etc. for project B

# Project A's Cargo cannot see project B's artifacts
tillandsias --attach ./project-a
# Inside: CARGO_HOME=/home/forge/.cache/tillandsias-project/cargo
#   (linked from ~/.cache/tillandsias/project-a/cargo on host)

# Switching to project B in new container
tillandsias --attach ./project-b
# Inside: CARGO_HOME=/home/forge/.cache/tillandsias-project/cargo
#   (linked from ~/.cache/tillandsias/project-b/cargo on host)
# Project B's Cargo is isolated; no collision
```

---

## Debugging

### View Cache Status

```bash
# On host
ls -lh ~/.cache/tillandsias/
# Shows: project-a/, project-b/, etc. with per-project caches

# Per-project breakdown
du -sh ~/.cache/tillandsias/my-app/*
# Shows: cargo: 500 MB, npm: 200 MB, go: 300 MB, ...

# Check staleness marker
cat ~/.cache/tillandsias/my-app/VERSION
```

### Inside Container

```bash
# Check where artifacts are going
echo "Cargo: $CARGO_HOME"
echo "npm: $npm_config_cache"
echo "Go: $GOPATH"

# Verify mount points
df -h /home/forge/.cache/tillandsias-project/
# Should show: bind-mount from host ~/.cache/tillandsias/<project>/

df -h /nix/store/
# Should show: read-only mount, much larger (shared across projects)

# Test ephemeral limits
df -h /tmp/
# Should show: 256 MB
```

### Simulate Staleness

```bash
# Manually trigger staleness (testing only)
echo "v0.1.0.0" > ~/.cache/tillandsias/my-app/VERSION

# Next attach logs warning:
# [cache] WARN: cache for my-app is stale (v0.1.0.0 != v0.1.169.226)
```

---

## Related Specifications

- `openspec/specs/forge-cache-dual/spec.md` — Dual-cache architecture and env var routing
- `openspec/specs/forge-staleness/spec.md` — Staleness detection and refresh policy
- `cheatsheets/runtime/forge-shared-cache-via-nix.md` — Nix store management
- `cheatsheets/runtime/forge-hot-cold-split.md` — Hot-path tmpfs and cold-path disk

## @trace Annotations

- `@trace spec:forge-cache-dual` — All cache path setup and env var exports
- `@trace spec:forge-staleness` — Staleness check functions and version recording
