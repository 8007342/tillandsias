<!-- @trace spec:build-script-architecture -->

# build-script-architecture Specification

## Status

active

## Purpose

Specify the dual-path architecture for the Tillandsias build system: fast local iteration reusing the forge image (with cached dependencies), periodic full reproducibility verification via clean Ubuntu builds, and cloud releases always from scratch.

This spec defines when each path is appropriate, their guarantees, and how they converge to a single end-to-end pipeline without performance regression for local developers.

## Context

**Problem**: The AppImage builder (Ubuntu 22.04 clean container) was extremely slow for local `./build.sh --install` (9min 45s apt-get update at 656 B/s), while the forge image has full caches and is fast (~30s rebuild).

**Solution**: Option A + C architecture
- **Option A** (Local iteration): Reuse existing forge image + cached toolchain for `./build.sh --install` → fast (~30s)
- **Option C** (Periodic verification): `./build.sh --clean` forces full Ubuntu clean build → slow but correct (~10min), catches dependency drift
- **Cloud releases**: CI/release.yml unchanged (always clean from scratch for reproducibility)

## Invariants

- **Fast local development**: Developer iteration on `./build.sh --install` must complete in <2 minutes (after initial toolbox creation)
- **Reproducibility verified**: `./build.sh --clean` proves from-scratch builds still work (gate before shipping)
- **Cloud independence**: CI/release.yml must remain unchanged; local optimizations never affect published artifacts
- **Version consistency**: All paths produce binaries with identical version strings and metadata
- **Cache transparency**: Local cache use is opaque to the user; no cache management required

## Requirements

### Requirement: Detect build context (local vs cloud)

The build script SHALL distinguish between local development and cloud CI builds.

#### Scenario: Local development build
- **WHEN** `./build.sh --install` is run from a developer's machine
- **THEN** the script SHALL detect it's running locally (not in CI environment)
- **AND** SHALL use the existing forge image for AppImage assembly (skip clean Ubuntu rebuild)

#### Scenario: Cloud CI build
- **WHEN** `./build.sh` is invoked by GitHub Actions (CI environment)
- **THEN** the script SHALL detect it's running in CI
- **AND** SHALL execute the full clean Ubuntu build path (unchanged behavior)
- **AND** SHALL NOT use any local caches (reproducibility requirement)

### Requirement: Fast local AppImage assembly

For local development, the build script SHALL reuse the existing forge image instead of rebuilding in a fresh Ubuntu container.

#### Scenario: Reuse forge image for local build
- **WHEN** `./build.sh --install` runs locally and forge image exists
- **THEN** the script SHALL run `cargo tauri build` inside the existing forge image
- **AND** SHALL extract the AppImage from the forge's `target/release/bundle/appimage/`
- **AND** SHALL copy the AppImage to `~/.local/bin/tillandsias`
- **AND** build time SHALL be <2 minutes (including cargo link time)

#### Scenario: Missing forge image
- **WHEN** `./build.sh --install` runs locally but forge image is missing
- **THEN** the script SHALL fall back to the clean Ubuntu build path
- **AND** SHALL log: `[build] No cached forge image — performing full Ubuntu build (this will be slow)`

### Requirement: Periodic full-stack reproducibility verification

The `--clean` flag SHALL force a full clean build, verifying that from-scratch builds still work correctly.

#### Scenario: Clean local build
- **WHEN** `./build.sh --clean --install` runs locally
- **THEN** the script SHALL execute `cargo clean` first
- **AND** SHALL proceed with the full Ubuntu AppImage builder path (same as CI)
- **AND** SHALL ignore any cached images or artifacts
- **AND** build time MAY be ~10 minutes (full apt-get update, no caches)

#### Scenario: Periodic gate before shipping
- **WHEN** a developer runs `./build.sh --clean` as a pre-release sanity check
- **THEN** they gain confidence that CI's full build will succeed
- **AND** catches any undocumented dependencies or environment assumptions
- **AND** exit code SHALL be 0 (success) or 1 (failure) as per dev-build spec

### Requirement: Cloud CI path unchanged

The GitHub Actions release and CI workflows MUST NOT be modified by local optimization changes.

#### Scenario: Release workflow executes full build
- **WHEN** release.yml runs (triggered manually or by workflow)
- **THEN** it SHALL invoke `./build.sh --release` in the CI environment
- **AND** the script SHALL detect CI context and execute the full clean Ubuntu build path
- **AND** produced artifacts SHALL be byte-identical to any other full clean build
- **AND** versioning and hashing SHALL be unchanged from current behavior

### Requirement: Transparent cache coherence

The local forge image cache MUST NOT cause inconsistencies between local and CI artifacts.

#### Scenario: Cache doesn't affect semantics
- **WHEN** developer builds locally with `./build.sh --install`
- **AND** later runs `./build.sh --clean --install` on the same machine
- **THEN** both builds SHALL produce binaries with identical version strings, hashes, and functionality
- **AND** the `--clean` version SHALL NOT differ from the local cached version except in compile time
- **AND** both SHALL match CI artifacts (modulo timestamp/build environment)

#### Scenario: Cargo.lock enforces dependency pinning
- **WHEN** either local or CI build runs
- **THEN** Cargo.lock (committed to git) SHALL pin all dependencies
- **AND** no local caching mechanism SHALL bypass Cargo.lock
- **AND** dependency updates SHALL go through normal git workflow (Cargo.lock commits)

### Requirement: Build script detects and reports strategies

The build script output SHALL make the chosen strategy visible to the user.

#### Scenario: Local cached build feedback
- **WHEN** `./build.sh --install` runs locally and uses the forge image
- **THEN** script SHALL log: `[build] Using cached forge image (fast local path)`
- **AND** SHALL log build time at completion

#### Scenario: Clean build feedback
- **WHEN** `./build.sh --clean --install` runs
- **THEN** script SHALL log: `[build] Full clean build (reproducibility verification)`
- **AND** SHALL warn if running locally: `[build] This path is slow; use for pre-release gates only`

#### Scenario: CI detection feedback
- **WHEN** `./build.sh` detects CI environment
- **THEN** script SHALL log: `[build] CI environment detected; using full reproducible build path`

### Requirement: Toolbox remains the compile environment

Whether local cached or clean, compilation happens inside the toolbox; AppImage assembly strategy changes, not compilation.

#### Scenario: Compilation inside toolbox
- **WHEN** `./build.sh --install` runs
- **THEN** `cargo build` and `cargo tauri build` SHALL execute inside the `tillandsias` toolbox
- **AND** the toolbox Rust version, LLVM, and system libraries SHALL be the same for both cached and clean paths
- **AND** source compilation SHALL NOT use local host libraries (isolation enforced)

### Requirement: APT/package caching for clean local builds (optional optimization)

Future: For `./build.sh --clean` running locally (not in CI), the script MAY persist apt caches between builds to avoid 10min apt-get stalls while still forcing code rebuild.

#### Scenario: APT cache reuse (future)
- **WHEN** `./build.sh --clean --install` runs locally and `tillandsias-appimage-apt-cache` volume exists
- **THEN** the Ubuntu container MAY use cached apt lists and downloaded packages
- **AND** script SHALL still force `cargo clean` before compilation (no source code cache)
- **AND** this optimization SHALL NOT run in CI (CI always fresh)

## Design Decisions

### Why reuse the forge image for local builds?

The forge image already has:
- Rust toolchain + cargo cache from recent builds
- All system libraries (OpenSSL, C/C++ compilers, tauri dependencies)
- Consistent environment (same GCC, LLVM versions as CI)

Rebuilding in clean Ubuntu wastes ~10 minutes on apt-get and initial compile setup, with no correctness benefit for local iteration. The developer will rebuild many times before shipping.

### Why keep `--clean` for periodic verification?

One-off clean builds catch:
- Undocumented system dependencies (e.g., a new -dev package required)
- Environment assumptions (e.g., specific GCC version expectations)
- Drift in the dependency tree (Cargo.lock should prevent this, but validates the assumption)

Before shipping, developers run `./build.sh --clean` once to verify CI's full build will succeed.

### Why NOT change CI/release.yml?

- CI's reproducibility guarantee is essential for trust and troubleshooting
- Any divergence between local and CI builds creates a parallel path (hard to debug)
- GitHub Actions secrets and release artifacts must come from a clean, auditable build
- Local optimizations are only safe if they're transparent and reversible

### Why this architecture and not alternatives?

| Alternative | Pros | Cons | Verdict |
|---|---|---|---|
| **A: Reuse forge + C: Periodic clean** (chosen) | Fast local, verified periodic, CI unchanged | Requires careful context detection | ✅ Meets all goals |
| B: Always clean Ubuntu (current) | Simple, consistent, reproducible | 10min per local build — unworkable for iteration | ❌ Too slow |
| D: Local apt cache only | Improves B from 10min to ~5min | Still slower than A, adds cache management complexity | ❌ Insufficient |
| E: CI caching | Speeds up CI builds | Violates reproducibility requirement | ❌ Wrong for releases |

## Sources of Truth

- `cheatsheets/build/build-strategy.md` — Explains when to use `--install` vs `--clean`, cache coherence assumptions
- `CLAUDE.md` § Build Commands — Build script interface and toolbox defaults
- `scripts/build.sh` — Implementation of context detection (CI env vars, path checks)
- `scripts/build-image.sh` — AppImage builder logic (may differ for local vs CI)
- `Cargo.lock` — Pinned dependencies (gate for cache safety)

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:

### litmus:build-cache-transparent
**Requirement**: Local caches do not change semantics

- `./build.sh --install` (with cache) → produce AppImage with hash H1, exit 0
- `./build.sh --clean --install` (no cache) → produce AppImage with hash H2
- H1 and H2 MAY differ (timestamps, non-reproducible randomness)
- Both H1 and H2 SHALL run identically when executed
- Both SHALL report same version string

### litmus:build-clean-from-scratch-works
**Requirement**: Full clean builds are not broken by local optimizations

- `./build.sh --clean --install` (local, full Ubuntu) → exit 0
- AppImage SHALL install to `~/.local/bin/tillandsias` without errors
- `tillandsias --version` SHALL match VERSION file
- `tillandsias --init --test` SHALL succeed

### litmus:ci-unchanged-behavior
**Requirement**: CI builds are not affected by this spec

- CI runs `./build.sh --release` in GitHub Actions environment
- Release artifact hashing and versioning are unchanged
- `.github/workflows/release.yml` produces same output as before

### litmus:toolbox-isolation
**Requirement**: Both paths use isolated toolbox compilation

- `./build.sh --install` (cached path) uses toolbox
- `./build.sh --clean --install` (clean path) uses toolbox
- Neither path uses host system Rust, host system C compiler, or host system cargo
- Toolbox isolation is enforced by `--cap-drop=ALL`, `--userns=keep-id`

## Observability

Annotations referencing this spec can be found by:

```bash
grep -rn "@trace spec:build-script-architecture" scripts/ src-tauri/ CLAUDE.md --include="*.sh" --include="*.rs" --include="*.md"
```

Key trace locations:
- `scripts/build.sh` — context detection, path selection logic
- `scripts/build-image.sh` — image assembly (may differ for local vs CI)
- Build output: `[build] Using cached forge image` vs `[build] Full clean build` messages

## Future Work

1. **APT cache persistence** (optional): Implement tiered caching so `./build.sh --clean` on local machines reuses apt lists but not source code
2. **Cheatsheet: Build strategy decisions** — Guide developers on when to use --clean, how caching works, recovery if cache is corrupted
3. **Metrics**: Track build times (local cached vs clean) to detect when caching becomes stale or harmful
4. **CI cache gates** (CI only): If GitHub Actions implements layer caching, evaluate safely (reproducibility-compatible caching only)
