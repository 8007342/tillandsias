<!-- @trace spec:forge-staleness -->
# forge-staleness Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-08-fix-forge-staleness-and-pruning/
annotation-count: 13

## Purpose

Ensure forge image staleness detection respects version boundaries, always invokes the build script for freshness checks, auto-prunes old images to save disk space, and forward-compatible detects newer forge images from a different binary version.

## Requirements

### Requirement: Version-scoped staleness hash file

The forge staleness hash file SHALL be versioned to match the current release version. Instead of `.last-build-forge.sha256`, the file SHALL be named `.last-build-forge-v<MAJOR>.<MINOR>.<CHANGE>.sha256` where the version is extracted from the `VERSION` file at tray startup.

Each version maintains its own hash state. When the VERSION bumps, a new hash file is created — the old one is discarded and does not carry over, preventing false "up to date" results across version upgrades.

#### Scenario: Version bump creates new hash file

- **WHEN** the VERSION file changes from `v0.1.97` to `v0.1.98`
- **THEN** the tray SHALL check for `.last-build-forge-v0.1.98.sha256`
- **AND** the old `.last-build-forge-v0.1.97.sha256` is ignored
- **AND** the image is rebuilt because the new hash file does not exist

#### Scenario: Same version reuses hash state

- **WHEN** the tray is restarted without a VERSION change
- **THEN** the staleness hash file retains its version-scoped name
- **AND** staleness is checked against the same hash, enabling cache hits on rebuild

### Requirement: Tray always invokes build script for staleness check

The tray handler (`handlers.rs::ensure_forge_ready` or similar) SHALL NOT short-circuit the build script when `podman image exists(tillandsias-forge:v<VERSION>)` returns true. Instead, the tray SHALL ALWAYS invoke `scripts/build-image.sh forge`, which handles staleness detection internally.

The build script checks if the computed source hash matches the version-scoped `.last-build-forge-v<VERSION>.sha256`. On match, the script exits early (no rebuild). On mismatch, the script rebuilds.

#### Scenario: Stale source triggers rebuild despite image existing

- **WHEN** `podman image exists(tillandsias-forge:v0.1.98)` returns true
- **BUT** source files under `flake.nix`, `images/default/`, etc. have changed
- **AND** `scripts/build-image.sh forge` recomputes the source hash
- **AND** the hash does not match `.last-build-forge-v0.1.98.sha256`
- **THEN** the script SHALL rebuild the image
- **AND** update the hash file

#### Scenario: Fresh image with matching hash skips rebuild

- **WHEN** the image exists AND the source hash matches `.last-build-forge-v0.1.98.sha256`
- **THEN** `scripts/build-image.sh forge` exits early with "image up to date"
- **AND** no rebuild occurs
- **AND** the attach proceeds with the cached image

### Requirement: Prune old forge images after successful build

After a successful forge image build, the tray SHALL prune all forge images except:

1. The current-version image (just built)
2. The latest single other version (as a fallback in case of the current version failing)

All other older forge images SHALL be deleted via `podman rmi`.

#### Scenario: Old images cleaned up after build

- **WHEN** `scripts/build-image.sh forge` completes successfully
- **THEN** the tray runs `podman images tillandsias-forge --format='...'` to list all forge images
- **AND** deletes all but the current version (most recent by timestamp)
- **AND** one additional prior version (as a safety fallback)
- **AND** logs how many images were pruned

#### Scenario: Pruning saves disk space

- **WHEN** the user has upgraded from v0.1.90 → v0.1.95 → v0.1.98
- **THEN** the images for v0.1.90 and v0.1.93 are deleted
- **AND** only v0.1.95 (fallback) and v0.1.98 (current) are retained
- **AND** freed disk space is available for other operations

### Requirement: Forward-compatible newer image detection

If a forge image exists with a version higher than the current `VERSION` (e.g., the user downgraded or the binary is older), the tray SHALL detect this and use the newer image with a logged warning.

#### Scenario: Newer image is preferred over rebuilding

- **WHEN** the current binary's VERSION is v0.1.96
- **AND** a forge image `tillandsias-forge:v0.1.98` already exists
- **THEN** the tray SHALL use the v0.1.98 image
- **AND** emit a `warn!` log: "Using newer forge image v0.1.98 (binary is v0.1.96)"`
- **AND** NOT rebuild or attempt to downgrade

#### Scenario: Forward compatibility preserves functionality

- **WHEN** a newer image is used with an older binary
- **THEN** the attach and forge launch succeed without error
- **AND** the user's session is unaffected
- **AND** the warning surfaces the version mismatch for operator awareness

### Requirement: Staleness detection in init command

The `tillandsias --init` command SHALL apply the same version-scoped staleness and pruning logic when building the initial forge image.

#### Scenario: Init command builds fresh forge with staleness check

- **WHEN** `tillandsias --init` is run for the first time
- **THEN** the forge image build is invoked with version-scoped hash detection
- **AND** subsequent `--init` runs with no source change skip the rebuild
- **AND** old images from failed prior attempts are pruned

## Sources of Truth

- `cheatsheets/build/podman-image-management.md` — image listing, deletion, version tag patterns
- `cheatsheets/runtime/version-file-conventions.md` — VERSION file structure and semantic versioning in scripts
- `cheatsheets/build/nix-flake-caching.md` — reproducible hash computation for Nix builds

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Stale entries are cleaned; no persistent outdated state
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable
