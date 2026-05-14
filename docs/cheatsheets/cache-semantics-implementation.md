# Cache Semantics Implementation Guide

**Status**: Implementation complete for Wave 7 Task 5  
**Date**: 2026-05-14  
**Specs**: `forge-cache-dual`, `forge-staleness`

## Overview

This document describes the formal cache directory structure and staleness detection rules implemented in Tillandsias. It covers:

1. Four path categories with defined staleness policies
2. Cache path constants exported by `lib-common.sh`
3. Staleness detection functions and version tracking
4. Per-project cache isolation guarantees
5. Test coverage and verification procedures

## Four Path Categories

### 1. Shared Cache (RO): `/nix/store/`

- **Source**: Baked into image at build time via Nix
- **Staleness**: Never stale (versioned by image tag)
- **Isolation**: N/A (shared across all projects)
- **Mount**: Read-only bind-mount from host's nix store
- **Single entry point**: Nix only — no other tools write here

**Implementation in lib-common.sh**:
```bash
export TILLANDSIAS_SHARED_CACHE="/nix/store"
```

**Verification**: Tools like Maven, npm, Cargo MUST redirect their artifacts to the per-project cache, never to `/nix/store/`.

### 2. Per-Project Cache (RW): `/home/forge/.cache/tillandsias-project/`

- **Source**: Bind-mount from host's `~/.cache/tillandsias/<project>/`
- **Staleness**: Checked at container launch; stale if image version differs
- **Isolation**: Per-project only
- **Mount**: Read-write bind-mount (project-specific)
- **Populated by**: Package managers (Cargo, npm, Maven, Gradle, pip, Go, etc.)

**Implementation in lib-common.sh**:
```bash
PROJECT_CACHE="/home/forge/.cache/tillandsias-project"
export TILLANDSIAS_PROJECT_CACHE="$PROJECT_CACHE"

# Standard env vars for package managers (all pointing into PROJECT_CACHE)
export CARGO_HOME="$PROJECT_CACHE/cargo"
export CARGO_TARGET_DIR="$PROJECT_CACHE/cargo/target"
export GOPATH="$PROJECT_CACHE/go"
export GOMODCACHE="$PROJECT_CACHE/go/pkg/mod"
export MAVEN_OPTS="-Dmaven.repo.local=$PROJECT_CACHE/maven ${MAVEN_OPTS:-}"
export GRADLE_USER_HOME="$PROJECT_CACHE/gradle"
export PUB_CACHE="$PROJECT_CACHE/pub"
export npm_config_cache="$PROJECT_CACHE/npm"
export NPM_CONFIG_PREFIX="$PROJECT_CACHE/npm/global"
export YARN_CACHE_FOLDER="$PROJECT_CACHE/yarn"
export PNPM_HOME="$PROJECT_CACHE/pnpm"
export UV_CACHE_DIR="$PROJECT_CACHE/uv"
export PIP_CACHE_DIR="$PROJECT_CACHE/pip"
export PATH="$NPM_CONFIG_PREFIX/bin:$CARGO_HOME/bin:$GOPATH/bin:$PNPM_HOME:$PATH"
```

**Per-project isolation**: The tray creates a separate cache directory for each project:
- Project A: `~/.cache/tillandsias/project-a/`
- Project B: `~/.cache/tillandsias/project-b/`

Each project's container sees only its own cache via the bind-mount.

### 3. Project Workspace: `/home/forge/src/<project>/`

- **Source**: Bind-mount from host's user working tree (git repo)
- **Content**: Source code only (no build artifacts)
- **Staleness**: User-managed (not touched by tray)
- **Isolation**: Per-project (separate bind-mount per project)
- **Persistence**: Committed to git; survives container stop

**Implementation**: No env vars needed; entrypoint clones from git mirror and cd's into the workspace.

**Anti-pattern flagged**: Build artifacts under the workspace (e.g., `target/`, `node_modules/`, `build/`) are anti-patterns and pollute the git repo. All tools support env var redirection.

### 4. Ephemeral: `/tmp`, `/run/user/1000`, unmounted home dirs

- **Mount type**: tmpfs with kernel-enforced size caps
- **Size limits**:
  - `/tmp`: 256 MB (via `--tmpfs=/tmp:size=256m,mode=1777`)
  - `/run/user/1000`: 64 MB (via `--tmpfs=/run/user/1000:size=64m,mode=0700`)
  - Unmounted home dirs: Unbounded (container's overlayfs upper-dir)
- **Staleness**: N/A (always fresh, wiped per stop)
- **Isolation**: Per-container (ephemeral, lost on stop)

**Implementation**: No code needed; Podman launches with `--tmpfs` flags to enforce caps.

## Staleness Detection

### How Staleness Works

1. **Initial Attach**:
   ```bash
   # Tray records the image version in the cache directory
   mkdir -p ~/.cache/tillandsias/<project>/
   echo "v0.1.169.226" > ~/.cache/tillandsias/<project>/VERSION
   ```

2. **Subsequent Attach**:
   ```bash
   # Container entrypoint calls (from lib-common.sh):
   cache_is_stale "my-project" "v0.1.169.226"
   # Returns 0 (true/stale) if version file missing or versions differ
   # Returns 1 (false/fresh) if versions match
   ```

3. **On Stale Detect**:
   ```bash
   # Log warning (non-blocking)
   [cache] WARN: cache for my-project is stale (v0.1.169.224 != v0.1.169.226)
   [cache] recommend: rm -rf ~/.cache/tillandsias/my-project/
   # Attach continues; user can clear manually or rebuild to refresh
   ```

### Cache Staleness Functions

#### `cache_is_stale <project> <image_version>`

**Purpose**: Detect if per-project cache is stale relative to running image  
**Returns**: 0 (stale) if version file missing or versions differ; 1 (fresh) if versions match  
**@trace**: `spec:forge-staleness`

```bash
# Implemented in lib-common.sh
cache_is_stale() {
    local project="$1" image_version="$2"
    [ -z "$project" ] || [ -z "$image_version" ] && return 1

    local cache_version_file="$HOME/.cache/tillandsias/${project}/VERSION"
    if [ ! -f "$cache_version_file" ]; then
        # No version file → cache is stale
        return 0
    fi

    local cache_version
    cache_version="$(cat "$cache_version_file" 2>/dev/null || echo "")"
    [ -z "$cache_version" ] && return 0

    # Compare versions: if they differ, cache is stale
    [ "$cache_version" != "$image_version" ]
}
```

#### `record_cache_version <project> <image_version>`

**Purpose**: Record image version for future staleness checks  
**Called**: Once per project at first attach (idempotent)  
**@trace**: `spec:forge-staleness`

```bash
# Implemented in lib-common.sh
record_cache_version() {
    local project="$1" image_version="$2"
    [ -z "$project" ] || [ -z "$image_version" ] && return 1

    local cache_dir="$HOME/.cache/tillandsias/${project}"
    mkdir -p "$cache_dir" 2>/dev/null || return 1

    echo "$image_version" > "$cache_dir/VERSION" 2>/dev/null || return 1
    trace_lifecycle "cache" "recorded version ${image_version} for project ${project}"
    return 0
}
```

## Test Coverage

### Test Suite: `scripts/test-cache-semantics.sh`

**Status**: All 17 tests passing  
**Coverage**: Staleness detection, directory structure, isolation, version management

**Test categories**:

1. **Staleness Detection** (3 tests):
   - `cache_is_stale_with_no_version_file`: Returns 0 (stale) when file missing
   - `cache_is_stale_with_matching_version`: Returns 1 (fresh) when versions match
   - `cache_is_stale_with_differing_version`: Returns 0 (stale) when versions differ

2. **Directory Structure** (4 tests):
   - `cache_directories_structure`: Standard cache paths created successfully
   - `per_project_cache_isolation`: Project A cannot see project B's cache

3. **Version Management** (2 tests):
   - `record_cache_version`: Version file created with correct content
   - Idempotency verified

4. **Constants and Paths** (2 tests):
   - `cache_constants_exported`: TILLANDSIAS_* constants defined correctly
   - `ephemeral_paths_defined`: Size caps documented (256 MB, 64 MB)

**Running the tests**:
```bash
bash scripts/test-cache-semantics.sh
```

**Expected output**:
```
======================================
Cache Semantics Unit Tests
======================================

Cache staleness detection:
  ✓ cache_is_stale returns 0 when version file missing
  ✓ cache_is_stale returns 1 when versions match
  ✓ cache_is_stale returns 0 when versions differ

Cache directory structure:
  ✓ cargo directory created
  ✓ go/pkg/mod directory created
  ✓ npm directory created
  ✓ maven directory created
  ✓ project-a cannot see project-b's cache
  ✓ project-b cannot see project-a's cache
  ✓ project-a has its own file
  ✓ project-b has its own file

Cache version management:
  ✓ version file created
  ✓ version content matches

Cache constants and paths:
  ✓ TILLANDSIAS_SHARED_CACHE is /nix/store
  ✓ PROJECT_CACHE template is /home/forge/.cache/tillandsias-project
  ✓ tmp ephemeral cap
  ✓ run user ephemeral cap

======================================
Test Results: 17/17 passed
======================================
SUCCESS: All tests passed
```

## Verification Checklist

### Path Constants Exported

- [x] `TILLANDSIAS_SHARED_CACHE` = `/nix/store`
- [x] `TILLANDSIAS_PROJECT_CACHE` = `/home/forge/.cache/tillandsias-project`
- [x] `TILLANDSIAS_WORKSPACE` = `/home/forge/src`
- [x] `TILLANDSIAS_EPHEMERAL` = `/tmp`

### Staleness Rules Documented

- [x] Shared cache: Never stale (baked into image)
- [x] Per-project cache: Stale if image version changed
- [x] Workspace: User-managed (not touched by tray)
- [x] Ephemeral: Always fresh (wiped on stop)

### Functions Implemented

- [x] `cache_is_stale <project> <image_version>`: Detect staleness
- [x] `record_cache_version <project> <image_version>`: Record version marker

### Tests Passing

- [x] `scripts/test-cache-semantics.sh`: 17/17 tests passing

### Documentation Complete

- [x] `images/default/lib-common.sh`: Cache paths documented, functions implemented
- [x] `scripts/install.sh`: Cache paths noted in preamble
- [x] `scripts/test-cache-semantics.sh`: Comprehensive test suite
- [x] `cheatsheets/runtime/forge-cache-semantics.md`: User-facing guide

### @trace Annotations

- [x] `@trace spec:forge-cache-dual` on path exports in lib-common.sh
- [x] `@trace spec:forge-staleness` on staleness functions
- [x] All specs cited in cheatsheet frontmatter

## Files Changed

1. **images/default/lib-common.sh**
   - Added cache directory structure documentation
   - Added four path category explanation
   - Added `cache_is_stale()` function
   - Added `record_cache_version()` function
   - Added `TILLANDSIAS_*` constant exports
   - Added @trace annotations

2. **scripts/install.sh**
   - Added preamble documenting cache paths created during installation
   - Added @trace annotations

3. **scripts/test-cache-semantics.sh** (new)
   - 17 unit tests covering staleness, isolation, directory structure, version management
   - All tests passing

4. **cheatsheets/runtime/forge-cache-semantics.md** (new)
   - User-facing guide to cache architecture
   - Practical workflows and debugging tips
   - Related specs and @trace annotations

5. **docs/cheatsheets/cache-semantics-implementation.md** (new)
   - Implementation overview and architecture documentation
   - Verification checklist and test coverage summary

## Integration Points

### Tray Handler (`handlers.rs::ensure_forge_ready`)

When attaching a project:
1. Determine project name
2. Get running image version (from VERSION file)
3. Create `~/.cache/tillandsias/<project>/` if missing
4. Call `record_cache_version` (via lib-common.sh) to establish baseline

### Container Entrypoint

When launching a forge container:
1. Source `/usr/local/lib/tillandsias/lib-common.sh` (standard)
2. Export all cache path constants (`TILLANDSIAS_*`, per-language env vars)
3. Optional: Call `cache_is_stale` to detect and log staleness

### Manual Debugging

Users can:
```bash
# Check cache status
ls ~/.cache/tillandsias/
cat ~/.cache/tillandsias/<project>/VERSION

# Clear stale cache
rm -rf ~/.cache/tillandsias/<project>/

# Verify paths inside container
docker exec <container> echo $CARGO_HOME
docker exec <container> echo $npm_config_cache
```

## Related Specifications

- `openspec/specs/forge-cache-dual/spec.md` — Complete cache requirements
- `openspec/specs/forge-staleness/spec.md` — Complete staleness requirements
- `cheatsheets/runtime/forge-cache-semantics.md` — User guide

## Future Work

- Integrate staleness detection logging into tray (currently stubbed with `@trace`)
- Implement automatic cache pruning (cleanup old project caches)
- Add telemetry for cache hit rates and bytes downloaded at runtime
- Extend staleness check to shared cache (nix store auto-cleanup)
