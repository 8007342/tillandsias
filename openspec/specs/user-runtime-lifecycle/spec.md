<!-- @trace spec:user-runtime-lifecycle -->
# User Runtime Lifecycle Specification

## Status

active

## Purpose

Define the complete lifecycle of the Tillandsias binary from installation through first launch, container creation, caching, and update cycles. This is the **User Runtime** — distinct from Developer Runtime (toolbox) and Cloud Runtime (CI/CD).

## Problem Statement

Users should never need to understand containers, images, or configuration. The binary downloads, runs, and automatically creates all necessary containers on first launch. Containers are cached and reused across sessions. When the binary updates, containers are recreated idempotently. The host system remains pristine — no permanent files, no configuration pollution, only ephemeral cache.

## Requirements

### Requirement: Binary Installation
The user installs the Tillandsias binary via curl without any dependencies.

#### Scenario: Fresh install
- **WHEN** user runs `curl https://installer.tillandsias.dev/install.sh | sh`
- **THEN** a single AppImage binary is downloaded and installed (e.g., to `~/.local/bin/tillandsias`)
- **AND** no other files, libraries, or configurations are placed on the host
- **AND** the binary is immediately executable with zero prerequisites

#### Scenario: Install verification
- **WHEN** user runs `which tillandsias`
- **THEN** the binary is found and executable
- **AND** running `tillandsias --version` shows the installed version

### Requirement: First Launch — Automatic Initialization
On first run, the binary automatically initializes containers without requiring explicit `--init` command from the user.

#### Scenario: First launch via menu
- **WHEN** user clicks "Tillandsias" in the application menu for the first time
- **THEN** the binary starts, detects that containers do not exist, and internally runs initialization
- **AND** a tray icon appears with status "Initializing..."
- **AND** containers are created in sequence (proxy, git, inference, forge)
- **AND** user sees progress: "Building environment..." on the tray
- **AND** once complete, the tray icon transitions to a ready state
- **AND** user is never shown technical details (container names, image operations, etc.)

#### Scenario: First launch via CLI
- **WHEN** user runs `tillandsias /path/to/project` for the first time
- **THEN** the binary starts, detects missing containers, and initializes automatically
- **AND** terminal shows user-friendly status: "Setting up your development environment..."
- **AND** containers are created in the background
- **AND** once ready, the shell or IDE integration connects to the forge container

#### Scenario: Explicit init still supported
- **WHEN** user runs `tillandsias --init` explicitly (for testing or debugging)
- **THEN** initialization proceeds as documented in `spec:init-command`
- **AND** the behavior is identical to automatic initialization

### Requirement: Container Image Caching
Containers are created once, then cached and reused across sessions.

#### Scenario: Containers cached after first launch
- **WHEN** first launch completes and containers are running
- **THEN** container images are stored in the local podman storage
- **AND** container metadata is persisted in `~/.cache/tillandsias/`
- **AND** no images, configs, or state files are placed in `~/.config/` or system paths

#### Scenario: Second launch reuses cached containers
- **WHEN** user launches Tillandsias a second time
- **THEN** the binary checks for existing containers
- **AND** finds them in local podman storage
- **AND** reuses them without rebuilding
- **AND** launches immediately (seconds, not minutes)

#### Scenario: Cache is ephemeral
- **WHEN** `podman system prune -a` or similar cleanup runs on the host
- **THEN** Tillandsias containers and images may be removed
- **AND** on next launch, Tillandsias detects missing containers and rebuilds them idempotently
- **AND** user sees "Setting up your development environment..." as if it were the first launch
- **AND** the process completes without error or manual intervention

### Requirement: Update Cycle — Containers Recreated on Binary Update
When the binary is updated, containers are recreated idempotently on the next launch.

#### Scenario: Binary updated by user
- **WHEN** user reinstalls Tillandsias: `curl https://installer.tillandsias.dev/install.sh | sh`
- **THEN** the binary is updated in place (`~/.local/bin/tillandsias`)
- **AND** on next run, the tray detects that the binary version has changed

#### Scenario: Container recreation on version mismatch
- **WHEN** the tray detects that the running binary version does not match the container image version
- **THEN** the tray stops all running containers gracefully
- **AND** removes the old container images
- **AND** rebuilds them from the new binary's embedded definitions
- **AND** user sees "Updating your development environment..." on the tray
- **AND** the process completes without manual intervention

#### Scenario: Update with running forge
- **WHEN** user updates the binary while a forge container is actively running
- **THEN** the tray waits for the user to close/stop the active environment OR allows graceful shutdown on next tray interaction
- **AND** does NOT force-kill user containers
- **AND** on next forge launch, the new container version is used

### Requirement: Image Sources — Containerfiles Embedded, Built On-Demand
All container images are built from Containerfiles at user first-launch using only `podman build` (no external downloads, no Nix dependency). Zero image downloads at runtime from external registries.

#### Scenario: Containerfiles embedded in binary
- **WHEN** the binary initializes on first launch
- **THEN** container images are built from Containerfiles included in the AppImage:
  1. Binary contains: `images/proxy/Containerfile`, `images/git/Containerfile`, etc. (KB-level)
  2. Binary contains: Source code needed by images (entrypoints, configs, scripts)
  3. Tray runs: `podman build -f images/proxy/Containerfile -t tillandsias-proxy:v0.1.37.25 .`
  4. Images are built locally, stored in podman local storage (`~/.local/share/containers/`)
  5. Subsequent launches reuse cached images (if version matches) for bandwidth optimization
- **AND** NO images are pulled from docker.io, quay.io, or any external registry
- **AND** NO external dependencies (no Nix, no compilation tools on host, only podman)
- **AND** host's network state is irrelevant; build succeeds offline if Containerfile sources are complete

#### Scenario: No registry configuration required
- **WHEN** the user's host podman has any registries.conf configuration
- **THEN** Tillandsias does NOT modify it, does NOT rely on it, and does NOT require it
- **AND** registries.conf (if present) has zero effect on Tillandsias container creation
- **AND** Tillandsias never writes to `~/.config/containers/registries.conf` or system paths

### Requirement: Three-Runtime Isolation
Developer Runtime (toolbox), Cloud Runtime (CI), and User Runtime (installed binary) are completely isolated with separate source-of-truth and host mutation boundaries.

#### Scenario: Developer builds, Cloud CI validates, User runs
- **WHEN** developer runs `./build.sh` in repository
- **THEN** images built in toolbox podman storage only; host untouched
- **WHEN** cloud CI runs GitHub Actions
- **THEN** builds are for verification; images are not persisted to user deployment
- **WHEN** user runs installed AppImage
- **THEN** only Containerfiles from binary matter; Cloud runtime images are discarded
- **AND** each runtime's image sources are idempotent from its own boundary

#### Scenario: No runtime bleeds into another
- **WHEN** developer deletes `tillandsias` toolbox
- **THEN** user runtime is unaffected; images remain in user's podman storage
- **WHEN** user updates binary
- **THEN** developer toolbox unaffected; old images not modified
- **WHEN** Cloud CI builds fail
- **THEN** user runtime defaults to locally rebuilding from Containerfiles (fallback guaranteed)

### Requirement: Host System Remains Pristine
The host filesystem is never polluted with Tillandsias configuration, state, or permanent artifacts outside the cache directory.

#### Scenario: Only cache and podman storage are modified
- **WHEN** Tillandsias runs
- **THEN** files are written only to:
  1. `~/.cache/tillandsias/` — ephemeral build cache, logs, metadata (safe to delete anytime)
  2. `~/.local/share/containers/` — podman local storage (ephemeral, cleaned by `podman system prune`)
- **AND** no files are written to:
  - `~/.config/tillandsias/` (no configuration files)
  - `~/.local/bin/` (except the binary itself)
  - `/etc/containers/` or system paths
  - Any project directories (`.tillandsias/`, `.git/`, user sources untouched)

#### Scenario: Uninstall removes all artifacts
- **WHEN** user runs an uninstall script or manual removal
- **THEN** only the binary (`~/.local/bin/tillandsias`) is removed from the permanent filesystem
- **AND** the cache directory can be safely deleted: `rm -rf ~/.cache/tillandsias/`
- **AND** container images and podman data remain (user can clean separately with `podman system prune`)
- **AND** zero Tillandsias artifacts remain on the host

### Requirement: Developer Runtime ≠ User Runtime
The Developer Runtime (where `./build.sh` runs in a toolbox) is completely isolated from the User Runtime.

#### Scenario: Developer toolbox is ephemeral
- **WHEN** developer runs `./build.sh` in the tillandsias directory
- **THEN** a `tillandsias` toolbox is created (if not present)
- **AND** all builds happen inside the toolbox
- **AND** images built in the toolbox stay in the toolbox's podman storage
- **AND** the host's podman storage is NOT affected

#### Scenario: Built images available for deployment
- **WHEN** developer builds images in the toolbox and wishes to test as a user would
- **THEN** images are exported from the toolbox or embedded in the AppImage
- **AND** the AppImage is the deployment artifact that includes those images
- **AND** the user installs the AppImage and gets the developer's images automatically

#### Scenario: No shared state between runtimes
- **WHEN** developer runs `./build.sh` and simultaneously user runs the installed tray
- **THEN** the two are completely isolated
- **AND** they do not interfere with each other's podman storage, containers, or state

## Behavior After Implementation

### Timeline: Fresh User Install + First Launch
```
1. User: curl install
   → Binary installed to ~/.local/bin/

2. User: tillandsias
   → Tray appears, tray: "Initializing..."

3. Binary detects first launch
   → Runs automatic --init internally
   → Builds/loads proxy, git, inference, forge images
   → Creates containers in podman storage
   → Caches metadata to ~/.cache/tillandsias/

4. Tray: Status transitions to ready
   → Tray icon shows bloom state
   → "Ready. Click to attach."

5. User: Clicks "Attach Here" on project
   → Forge container starts
   → User works inside

6. User: Closes terminal
   → Tray stays running, containers idle

7. User: Opens terminal again, runs tillandsias /path
   → Tray re-launches, reuses cached containers
   → Forge starts immediately (seconds, not minutes)
```

### Timeline: Binary Update
```
1. User: curl install (updated binary)
   → Binary updated to ~/.local/bin/

2. User: tillandsias
   → Tray starts, detects version mismatch
   → Tray: "Updating your development environment..."
   → Old container images removed
   → New images built/loaded
   → Containers recreated

3. Tray: Status transitions to ready
   → New containers are available
```

### Timeline: Host Cache Cleared
```
1. User: podman system prune -a
   → Container images and podman storage cleaned

2. User: tillandsias
   → Tray starts, detects missing images
   → Tray: "Setting up your development environment..."
   → Images rebuilt from binary's definitions
   → Containers recreated (same as first launch)

3. Zero manual intervention required
```

## Validation Scenarios

### Litmus Test: Host Pristineness
- **Setup**: Fresh Fedora Silverblue system
- **Action**: Install and run Tillandsias, create and stop containers
- **Verify**: `find ~ -name "*.tillandsias*" -o -path "*/.config/tillandsias/*"` returns NO results in home directory
- **Expected**: Only cache in `~/.cache/tillandsias/` and podman storage exist

### Litmus Test: Idempotent Init
- **Setup**: First launch creates containers
- **Action**: Launch tray 10 times in succession
- **Verify**: Each launch reuses cached containers, takes <3 seconds after first
- **Expected**: No rebuild, no errors, containers reused

### Litmus Test: Update Cycle
- **Setup**: Binary v0.1.37.25, containers cached
- **Action**: Update binary to v0.1.37.26, launch tray
- **Verify**: Version mismatch detected, containers rebuilt, new version running
- **Expected**: No manual step required

### Litmus Test: Cache Recovery
- **Setup**: Containers cached and running
- **Action**: `podman system prune -a` (delete all images/containers)
- **Action**: Launch tray
- **Verify**: Images rebuilt and running
- **Expected**: Automatic recovery, user sees "Setting up..." message

## Measurability and Convergence

### Observable Signals
User Runtime convergence can be measured by:
- **Image build operator**: Single canonical `ensure_user_runtime_images(binary_version, embedded_manifest_hash)` function, invoked from first-launch, binary-update, and cache-eviction paths with only `build_reason` differing
- **Runtime traces**: Every image event includes `runtime_model` (developer|cloud|user), `manifest_hash`, `binary_version`, `image_tag`, `build_reason`, `cache_hit|miss`, `registry_attempt_count`
- **Cache counters**: `cache_hit`, `cache_miss`, `rebuild_by_binary_version`, `rebuild_by_manifest_hash`, `rebuild_by_missing_image`, `registry_network_attempts`, `host_config_writes`
- **Negative litmus**: Any User Runtime registry pull, Nix invocation, embedded OCI load, or host config write is a signal for bounded uncertainty review
- **Three-runtime obligation matrix**: Rows (Developer, Cloud, User) × columns (source_of_truth, dependency_boundary, cache_semantics, host_mutation_boundary, version_signal, litmus_positive, litmus_negative, trace_coverage, residual_cc)
- **Minimax residual scoring**: Report per-runtime residual CentiColon separately; aggregate score is max of three, not sum

### Validation Metrics
- **Binary size**: Should remain <100 MB (no embedded images, only Containerfiles + source)
- **User first-launch time**: Predictable from Containerfile build time (typical: 3-10 minutes)
- **Cache hit ratio**: Tracks bandwidth optimization effectiveness
- **Host pristineness**: Zero files in ~/.config/tillandsias/, ~/.local/share/tillandsias/ (besides podman storage)
- **Rebuild determinism**: Same binary + manifest hash always produces identical image bytes (or if not, evidence cites the intentional difference)

## Sources of Truth

- `cheatsheets/runtime/container-image-tagging.md` — Container image versioning and staleness detection
- `cheatsheets/build/container-image-building.md` — Containerfiles embedded in binary, built on-demand
- `cheatsheets/runtime/ephemeral-lifecycle.md` — Ephemeral principle and bandwidth-transparent caching
- `cheatsheets/runtime/podman.md` — Podman local storage and cleanup

## Related Specs

- `spec:init-command` — Explicit `--init` command behavior
- `spec:app-lifecycle` — Container orchestration and state machine
- `spec:appimage-build-pipeline` — Binary creation and image embedding
- `spec:environment-runtime` — Per-project configuration and agent dispatch

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:user-runtime-lifecycle" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
