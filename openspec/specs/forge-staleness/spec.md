<!-- @trace spec:forge-staleness -->
# forge-staleness Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-08-fix-forge-staleness-and-pruning/
annotation-count: 13

## Purpose

Ensure forge image staleness detection is driven by the source hash, always invokes the build script for freshness checks, refreshes human aliases on rebuild, auto-prunes old images to save disk space, and forward-compatible detects newer forge images from a different binary version.

## Requirements

### Requirement: Source-hash staleness file

The forge staleness hash file MUST be keyed by image name and track the source hash only. The file MUST be named `.last-build-forge.sha256`.

Version bumps MUST NOT force a rebuild when the source hash is unchanged. Human-facing version and latest tags may be refreshed without changing the underlying canonical image.

#### Scenario: Version bump reuses the same source hash

- **WHEN** the VERSION file changes but the Containerfile inputs do not
- **THEN** `.last-build-forge.sha256` MUST still be consulted
- **AND** the build MUST be skipped if the source hash is unchanged
- **AND** only the human aliases are refreshed

### Requirement: Tray always invokes build script for staleness check

The tray handler (`handlers.rs::ensure_forge_ready` or similar) MUST NOT short-circuit the build script when `podman image exists(tillandsias-forge:v<VERSION>)` returns true. Instead, the tray MUST ALWAYS invoke `scripts/build-image.sh forge`, which handles staleness detection internally.

The build script checks if the computed source hash matches `.last-build-forge.sha256`. On match, the script exits early (no rebuild). On mismatch, the script rebuilds and refreshes aliases.

#### Scenario: Stale source triggers rebuild despite image existing

- **WHEN** `podman image exists(tillandsias-forge:<HASH>)` returns true
- **BUT** source files under `flake.nix`, `images/default/`, etc. have changed
- **AND** `scripts/build-image.sh forge` recomputes the source hash
- **AND** the hash does not match `.last-build-forge.sha256`
- **THEN** the script MUST rebuild the image
- **AND** update the hash file

#### Scenario: Fresh image with matching hash skips rebuild

- **WHEN** the image exists AND the source hash matches `.last-build-forge.sha256`
- **THEN** `scripts/build-image.sh forge` MUST exit early with "image up to date"
- **AND** no rebuild occurs
- **AND** the attach proceeds with the cached image

### Requirement: Prune old forge images after successful build

After a successful forge image build, the tray MUST prune all forge images except:

1. The current canonical hash image (just built)
2. The current human aliases pointing at that canonical image

All other older forge images MUST be deleted via `podman rmi`.

#### Scenario: Old images cleaned up after build

- **WHEN** `scripts/build-image.sh forge` completes successfully
- **THEN** the tray MUST run `podman images tillandsias-forge --format='...'` to list all forge images
- **AND** delete all stale tags except the current canonical hash and refreshed aliases
- **AND** log how many images were pruned

#### Scenario: Pruning saves disk space

- **WHEN** the user has rebuilt from one canonical hash to the next
- **THEN** older stale tags MUST be deleted
- **AND** only the current canonical hash and refreshed aliases MUST be retained
- **AND** freed disk space MUST be available for other operations

### Requirement: Forward-compatible newer image detection

If a forge image exists with a newer human alias than the current `VERSION` (e.g., the user downgraded or the binary is older), the tray MUST detect this and use the newer image with a logged warning.

#### Scenario: Newer image is preferred over rebuilding

- **WHEN** the current binary's VERSION is an older CalVer release
- **AND** a forge image with a newer human alias already exists
- **THEN** the tray MUST use the existing canonical image
- **AND** emit a `warn!` log naming the newer alias and the older binary version
- **AND** MUST NOT rebuild or attempt to downgrade

#### Scenario: Forward compatibility preserves functionality

- **WHEN** a newer image is used with an older binary
- **THEN** the attach and forge launch MUST succeed without error
- **AND** the user's session MUST be unaffected
- **AND** the warning MUST surface the version mismatch for operator awareness

### Requirement: Staleness detection in init command

The `tillandsias --init` command MUST apply the same source-hash staleness and pruning logic when building the initial forge image.

#### Scenario: Init command builds fresh forge with staleness check

- **WHEN** `tillandsias --init` is run for the first time
- **THEN** the forge image build MUST be invoked with source-hash detection
- **AND** subsequent `--init` runs with no source change MUST skip the rebuild
- **AND** old images from failed prior attempts MUST be pruned

## Sources of Truth

- `scripts/build-image.sh` — source-hash freshness checks, alias refresh, and prune behavior
- `crates/tillandsias-core/src/config.rs` — the traced forge staleness config surface
- `crates/tillandsias-core/src/image_builder.rs` — the image builder test seam and staleness harness
- `cheatsheets/build/podman-image-management.md` — image listing, deletion, alias refresh patterns
- `cheatsheets/runtime/version-file-conventions.md` — VERSION file structure and human-facing alias semantics in scripts
- `cheatsheets/build/nix-flake-caching.md` — reproducible hash computation for Nix builds

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:forge-staleness-shape`

Gating points:
- Staleness checks remain source-hash keyed and deterministic
- Human aliases refresh without changing the canonical hash contract
- Old forge images continue to be pruned after successful rebuilds
