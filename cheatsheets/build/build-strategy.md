---
tags: [build, ci, reproducible-builds, local-development, release]
languages: [bash]
since: 2026-05-06
last_verified: 2026-05-06
sources:
  - https://github.com/8007342/tillandsias/blob/main/CLAUDE.md
  - https://github.com/8007342/tillandsias/blob/main/openspec/specs/build-script-architecture/spec.md
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# Build Strategy: Local vs Reproducible

**Use when**: Deciding between `./build.sh --install` (fast) and `./build.sh --clean --install` (reproducible) during development and release workflows.

## Provenance

- [Tillandsias CLAUDE.md](../../../CLAUDE.md#build-commands) — build command reference (project-local)
- [OpenSpec: build-script-architecture](../../../openspec/specs/build-script-architecture/spec.md) — architectural decision: context-aware build paths
- **Last updated:** 2026-05-04

## Quick Reference

| Scenario | Command | Time | When to Use |
|----------|---------|------|-------------|
| **Daily development** | `./build.sh --install` | <2 min | Iterating on code changes, testing locally |
| **Reproducibility check** | `./build.sh --clean --install` | ~10 min | Pre-release validation, detecting dependency drift |
| **CI/release** | `./build.sh --ci-full` | ~10 min | GitHub Actions workflow (always clean) |

## Fast Local Path: `./build.sh --install`

**Default behavior** when not in CI environment and `--clean` not passed.

### Strategy: Reuse cached forge image

```bash
./build.sh --install
```

- Detects build context automatically (`CI` env var, `GITHUB_ACTIONS` env var)
- If **local** (not CI) AND **not `--clean`** → uses cached forge image
- AppImage built inside toolbox container via `build_appimage_forge_cached()`
- Forge image (tillandsias-forge) reused from previous build
- Cargo incremental builds apply (warm cache)

### Timing

- **First run**: ~2–3 minutes (includes toolbox creation + initial build)
- **Subsequent runs**: <2 minutes (warm caches, reused containers)
- All dependent caches persist: Cargo registry, apt packages, compiled artifacts

### Cache Safety

- `Cargo.lock` pins exact dependency versions (locked across runs)
- Local caches don't bypass version pinning — same output as CI
- To clear caches: `./build.sh --wipe` (then rebuild)

### When to Use

✓ During active development (changes daily)  
✓ Testing code changes before pushing  
✓ Rapid iteration cycles  
✓ When reproducing bugs locally  

✗ NOT for pre-release validation  
✗ NOT for verifying dependency staleness  
✗ NOT when testing CI reproducibility  

## Reproducible Path: `./build.sh --clean --install`

**Enforced** when `--clean` flag is passed OR running in CI environment.

### Strategy: Full clean Ubuntu build

```bash
./build.sh --clean --install
```

- Automatically selected if:
  - `CI=true` or `GITHUB_ACTIONS=true` in environment (CI runner)
  - OR `--clean` flag explicitly passed on command line
- AppImage built in **isolated Ubuntu 22.04 podman container**
- Rust toolchain installed fresh from upstream (latest stable)
- System dependencies fetched via `apt-get update`
- No local caches bypass the build
- Identical to GitHub Actions workflow (hermetic)

### Timing

- **First build**: ~10–20 minutes (downloads Rust toolchain, apt packages, compiles all from source)
- **Second build**: ~2–3 minutes (Rust toolchain + apt cached; Cargo incremental applies)
- **Third+ builds**: <2 minutes (full cache warm)

### Cache Management

Caches stored in `~/.cache/tillandsias/appimage-builder/`:

```
~/.cache/tillandsias/appimage-builder/
├── rustup/               # Rust toolchain (~300MB)
├── cargo-bin/            # cargo-tauri, rustc (~500MB)
├── cargo-registry/       # Downloaded crates
└── apt/                  # Debian package cache
```

These caches persist across clean builds. To verify true reproducibility:

```bash
rm -rf ~/.cache/tillandsias/appimage-builder
./build.sh --clean --install  # Complete rebuild from scratch
```

### When to Use

✓ Before releasing to production  
✓ Detecting dependency drift (are package versions still resolvable?)  
✓ Periodically (weekly/monthly) to catch staleness  
✓ Verifying CI reproducibility locally  
✓ After major dependency updates (Rust, Tauri, system deps)  

✗ During daily development (too slow)  
✗ For rapid iteration (waste time on cache rebuilds)  

## CI/Release Builds (GitHub Actions)

**Always clean** — environment detection is automatic.

```bash
# In GitHub Actions workflow (CI=true auto-set by runner)
./build.sh --ci-full
```

- Detects `CI=true` + `GITHUB_ACTIONS=true` in environment
- Routes to `clean_ubuntu` strategy (see above)
- Runs full Ubuntu reproducible build
- Same guarantees as local `./build.sh --clean --install`
- Published artifacts are always from clean hermetic builds

## Decision Tree

```
Running ./build.sh --install or ./build.sh?
│
├─ CI environment detected (CI=true or GITHUB_ACTIONS=true)?
│  ├─ YES → clean_ubuntu (full rebuild)
│  └─ NO → continue
│
├─ --clean flag passed?
│  ├─ YES → clean_ubuntu (full rebuild)
│  └─ NO → forge_cached (fast local)
│
└─ Result:
   ├─ forge_cached: <2 min, cached images, Cargo incremental
   └─ clean_ubuntu: ~10 min, hermetic, reproducible
```

## Example Workflows

### Daily Development

```bash
# Fast iterative builds
./build.sh                    # Debug build (fastest)
./build.sh --install          # Build AppImage (2 min, fast local path)
tillandsias                   # Run the app

# ... code changes ...
./build.sh --install          # Rebuild (<2 min)
tillandsias                   # Test changes
```

### Pre-Release Validation

```bash
# Ensure reproducible build matches CI
./build.sh --clean --install   # ~10 min first time

# Verify it matches CI artifacts
diff target/release/bundle/appimage/*.AppImage $CI_ARTIFACT

# Run full CI suite locally
./build.sh --ci-full
```

### Weekly Staleness Check

```bash
# Detect if dependency resolution has broken
rm -rf ~/.cache/tillandsias/appimage-builder
./build.sh --clean --install

# If this fails, dependency versions are stale
# (e.g., Debian packages deprecated, Rust version incompatible)
```

## Implementation Details

### Context Detection (build.sh)

```bash
detect_build_context() {
    if [[ -n "${CI:-}" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "ci"
    else
        echo "local"
    fi
}

select_appimage_strategy() {
    local context="$1"
    local use_clean="$2"
    
    if [[ "$context" == "ci" ]]; then
        echo "clean_ubuntu"
    elif [[ "$use_clean" == "true" ]]; then
        echo "clean_ubuntu"
    else
        echo "forge_cached"
    fi
}
```

### Forge Cached Path (build.sh#L349)

- Requires existing `tillandsias-forge` image
- Runs `podman run -v $SCRIPT_DIR:/src:ro` with forge image
- Uses workspace Cargo cache
- Output extracted to `target/release/bundle/appimage/`

### Clean Ubuntu Path (build.sh#L408)

- Spins up ephemeral Ubuntu 22.04 container
- Mounts caches in `~/.cache/tillandsias/appimage-builder/` (RW)
- Mounts source as RO (no in-place edits)
- Installs Rust + system deps fresh
- Builds AppImage in isolated container
- Cleanup on exit (--rm flag)

## See Also

- `./build.sh --help` — Full build script documentation
- `scripts/local-ci.sh` — Full CI suite (spec binding, drift, version, litmus tests)
- `scripts/run-litmus-test.sh` — Executable spec validation
- `openspec/specs/build-script-architecture/` — Full architectural spec

@trace spec:build-script-architecture
