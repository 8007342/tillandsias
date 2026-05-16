# Cache Recovery Mechanism Specification

## Status

status: draft
promoted-from: direct
annotation-count: 2

## Purpose

Formalize the behavioral contract for fresh-start cache initialization. An absent `cache_version` file indicates a valid fresh system state (first run, post-reset, ephemeral deployment), not a version mismatch error. This spec prevents regression of the unwrap_or(false) fix at main.rs:549 and documents the cache lifecycle from initialization through corruption recovery.

## Requirements

### Requirement: Fresh Start is NOT a Version Mismatch

An absent `cache_version` file indicates a fresh system state and MUST be treated as valid (not an error). The `check_cache_integrity()` function MUST distinguish between "file absent" (fresh start) and "file present but wrong version" (mismatch error).

#### Scenario: No cached version file — fresh start succeeds

- **WHEN** the `cache_version` file does NOT exist in `~/.cache/tillandsias/`
- **AND** the user runs `tillandsias --init` for the first time
- **THEN** `check_cache_integrity()` MUST return `version_mismatch: false`
- **AND** initialization MUST proceed without error
- **AND** after successful init, `save_version()` writes the current version to `cache_version`

Implementation requirement:
```rust
// check_cache_integrity(), line 546–549
let version_mismatch = cached_version
    .as_ref()
    .map(|v| v != version)
    .unwrap_or(false); // No cached version on fresh start is OK, not a mismatch
```

The `unwrap_or(false)` semantic is **non-negotiable**. It MUST NOT be changed to `unwrap_or(true)`, which would revert fresh-start support.

#### Scenario: Ephemeral deployment (no persistent cache directory)

- **WHEN** Tillandsias runs in a containerized or ephemeral environment (e.g., CI/CD pipeline, ephemeral VM, podman system reset)
- **AND** the cache directory `~/.cache/tillandsias/` does not exist
- **THEN** the first initialization MUST succeed without error (treated as fresh start)
- **AND** all container images MUST be built
- **AND** after completion, the cache directory and version file are created for future checks

### Requirement: Actual Mismatch Triggers Error (with Recovery Path)

When `cache_version` file EXISTS but its content differs from the binary's `VERSION`, this IS a mismatch error and MUST block initialization unless the user opts-in to rebuild.

#### Scenario: Version mismatch detected — user must choose recovery

- **WHEN** the `cache_version` file exists AND contains a different version
- **THEN** `check_cache_integrity()` MUST return `version_mismatch: true`
- **AND** initialization MUST emit a warning to stderr:
  ```
  WARNING: Cache version mismatch detected
    Cached version: <old>
    Current version: <new>
    Suggestion: Use --force to rebuild, or --cache-clear to start fresh
  ```
- **AND** `run_init()` MUST exit with non-zero code
- **AND** user is offered two recovery paths:
  1. `tillandsias --init --force` — rebuild all images
  2. `tillandsias --init --cache-clear` — clear cache directory and rebuild

#### Scenario: User chooses --force to rebuild

- **WHEN** `run_init(force: true)` is called
- **THEN** version mismatch check is skipped (force bypasses integrity check)
- **AND** all images are rebuilt from scratch
- **AND** after successful build, `save_version()` writes the new version to `cache_version`

#### Scenario: User chooses --cache-clear to start fresh

- **WHEN** `--cache-clear` flag is passed (behavior deferred to tray handler)
- **THEN** the entire cache directory `~/.cache/tillandsias/` is deleted
- **AND** the next init run treats it as a fresh start (no `cache_version` file)
- **AND** all images are rebuilt

### Requirement: Corruption Recovery

When the `init-build-state.json` file exists but is corrupted (unreadable or invalid JSON), the cache recovery mechanism MUST detect the corruption, warn the user, delete the corrupted file, and allow initialization to proceed with a rebuilt state.

#### Scenario: JSON parse error detected — file is corrupted

- **WHEN** `detect_and_recover_cache_corruption()` attempts to parse `init-build-state.json`
- **AND** the file content is not valid JSON (syntax error, truncation, bit-flip)
- **THEN** a `warn!` log MUST be emitted with the parse error
- **AND** the warning to stderr MUST include:
  ```
  WARNING: Cache file is corrupted (JSON parse error)
    File: <path>
    Error: <json error>
    Recovery: Deleting corrupted cache and rebuilding
  ```
- **AND** the corrupted file MUST be deleted via `fs::remove_file()`
- **AND** `detect_and_recover_cache_corruption()` returns `true` (recovery triggered)
- **AND** the next phase of initialization (load or create `InitBuildState`) proceeds normally
- **AND** initialization continues without error

#### Scenario: I/O error reading cache file — cannot recover

- **WHEN** the cache file exists but `fs::read_to_string()` fails (permissions, device error, etc.)
- **THEN** a `warn!` log MUST be emitted with the I/O error
- **AND** the warning to stderr MUST surface the error and recovery action
- **AND** the file MUST be deleted (if deletion succeeds)
- **AND** if deletion fails, an error MUST be returned (cannot recover from unreadable, undeletable file)
- **AND** initialization halts (user must manually delete the file or use `--cache-clear`)

#### Scenario: Cache file does not exist — no corruption to recover

- **WHEN** `init-build-state.json` does not exist (fresh start or prior deletion)
- **THEN** `detect_and_recover_cache_corruption()` returns `false` (no recovery needed)
- **AND** `InitBuildState::load()` returns `None`
- **AND** `unwrap_or_else(InitBuildState::new)` creates a fresh state
- **AND** initialization proceeds normally

### Requirement: Cache Directory Lifecycle and Paths

The cache directory location MUST follow XDG specifications. The `cache_version` file MUST be written only after successful initialization, creating a checkpoint for future staleness checks.

#### Scenario: XDG_CACHE_HOME respects environment variable

- **WHEN** the `XDG_CACHE_HOME` environment variable is set
- **THEN** Tillandsias MUST use `$XDG_CACHE_HOME/tillandsias/` as the cache directory
- **AND** `cache_version` MUST be written to `$XDG_CACHE_HOME/tillandsias/cache_version`

#### Scenario: Fallback to ~/.cache/tillandsias/ when XDG_CACHE_HOME is unset

- **WHEN** `XDG_CACHE_HOME` is not set
- **AND** `HOME` environment variable is available
- **THEN** Tillandsias MUST use `~/.cache/tillandsias/` as the cache directory
- **AND** `cache_version` MUST be written to `~/.cache/tillandsias/cache_version`

#### Scenario: Version file is written after successful init, not before

- **WHEN** `InitBuildState::new()` creates an empty state at startup
- **THEN** `cache_version` file MUST NOT be written yet
- **AND** the file MUST only be written after successful image builds (via `save_version()` call)
- **AND** if any image build fails, the version file is NOT written
- **AND** the next init run will detect the missing version file and proceed as a fresh start (allowing recovery)

#### Scenario: init-build-state.json structure and persistence

- **WHEN** `InitBuildState` is serialized to JSON and written to cache
- **THEN** the JSON MUST be valid, readable, and deserializable on subsequent reads
- **AND** each `InitBuildState` field (image names, build status, timestamps) MUST be roundtrip-safe
- **AND** corruption of this file (bit flip, truncation, encoding error) triggers recovery (see Corruption Recovery requirement)

### Requirement: Version File Format and Semantics

The `cache_version` file MUST contain a single line: the current binary version (same as `VERSION` constant in code). No whitespace, metadata, or additional fields.

#### Scenario: Version file contains only the version string

- **WHEN** `save_version(version)` is called with version `"0.1.169.226"`
- **THEN** it writes exactly `0.1.169.226` to the file (no newline, no extras)
- **AND** `check_cache_integrity()` reads the file, trims whitespace, and compares against binary `VERSION`
- **AND** if the strings match exactly, `version_mismatch` is `false`

Implementation detail:
```rust
// save_version(): write version string as-is
fs::write(&version_file, version)

// check_cache_integrity(): read, trim, compare
let cached_version = fs::read_to_string(&version_file)?.trim().to_string();
```

## Invariants

1. **Fresh-start validity**: An absent `cache_version` file MUST always be treated as valid (not a mismatch error).

2. **Monotonic recovery**: Once corruption is detected and recovered, the corrupted file MUST NOT re-appear unless explicitly created by the user.

3. **Version atomicity**: The `cache_version` file MUST be written in one atomic operation (via `fs::write()`). Partial writes MUST be detected and treated as corruption.

4. **Initialization determinism**: Given identical input (source hash, tooling versions), two consecutive init runs with the same cache_version value MUST result in identical image builds (skipped if already cached).

5. **Error transparency**: All cache errors MUST be logged to stderr with actionable recovery suggestions (--force, --cache-clear, or manual deletion).

6. **Non-invasiveness**: Corruption recovery MUST ONLY delete the corrupted cache file (`init-build-state.json`), never the project workspace, git repository, or user files.

## Bindings

### Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:cache-recovery-fresh-start` — Created in Wave C

Test scenarios:
- Fresh start with absent `cache_version` succeeds
- Fresh start with absent `init-build-state.json` succeeds
- Version mismatch with present `cache_version` fails with actionable error
- Corrupted JSON in `init-build-state.json` triggers recovery and succeeds
- Unreadable `init-build-state.json` fails gracefully

### Cross-References

- `spec:forge-cache-dual` — Dual-layer cache architecture (shared + per-project); fresh-start must respect both layers
- `spec:forge-staleness` — Cache staleness detection requires valid `cache_version` file; absent file does not indicate staleness (it's a fresh start)

## Sources of Truth

- `cheatsheets/runtime/cache-architecture.md` — Tiered cache behavior, shared vs per-project state, and cache invalidation
- `cheatsheets/runtime/ephemeral-lifecycle.md` — Fresh-start semantics, disposable cache directories, and host-pristine lifecycle
- `cheatsheets/runtime/version-file-conventions.md` — Version file format and cache-version checkpoint semantics

- `cheatsheets/runtime/cache-architecture.md` — Cache model overview, tiered caching, ephemeral vs persistent layers
