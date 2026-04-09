# layered-tools-overlay Specification

## Purpose

Pre-built tools overlay that decouples AI coding tool lifecycle (OpenCode, Claude Code, OpenSpec) from the forge base image lifecycle. Tools are installed once into a host directory, mounted read-only into all forge containers, and updated in the background. Eliminates the 15-60 second per-launch install delay.

## Requirements

### Requirement: Tools overlay directory structure
The system SHALL maintain a tools overlay directory at `~/.cache/tillandsias/tools-overlay/` with versioned subdirectories and a `current` symlink pointing to the active version.

@trace spec:layered-tools-overlay

#### Layout
| Path | Purpose |
|------|---------|
| `tools-overlay/current` | Symlink to active version directory |
| `tools-overlay/v<N>/claude/` | Claude Code npm prefix (bin/, lib/node_modules/) |
| `tools-overlay/v<N>/opencode/` | OpenCode binary (bin/opencode) |
| `tools-overlay/v<N>/openspec/` | OpenSpec npm prefix (bin/, lib/node_modules/) |
| `tools-overlay/v<N>/.manifest.json` | Version stamps and metadata |

#### Scenario: First launch creates overlay
- **WHEN** `ensure_tools_overlay()` is called and no `current` symlink exists
- **THEN** a builder container SHALL be launched to install all tools
- **AND** the resulting directory SHALL be versioned as `v1`
- **AND** the `current` symlink SHALL point to `v1`
- **AND** this operation SHALL block until complete (one-time cost)

#### Scenario: Subsequent launches use existing overlay
- **WHEN** `ensure_tools_overlay()` is called and `current` is a valid symlink
- **THEN** the system SHALL proceed to container launch immediately
- **AND** SHALL NOT block on tool installation

### Requirement: Tools overlay mounted read-only into forge containers
All forge container profiles (opencode, claude, terminal) SHALL mount the tools overlay directory at `/home/forge/.tools` with read-only permissions.

@trace spec:layered-tools-overlay

#### Scenario: Overlay mount present in podman args
- **WHEN** a forge container is launched
- **THEN** the podman args SHALL include `-v <overlay-path>:/home/forge/.tools:ro`
- **AND** the entrypoint SHALL find tool binaries at `/home/forge/.tools/<tool>/bin/`

#### Scenario: Overlay absent -- graceful fallback
- **WHEN** a forge container is launched but the overlay directory does not exist
- **THEN** the overlay mount SHALL be omitted from podman args
- **AND** the entrypoint SHALL fall back to inline installation (current behavior)

### Requirement: Entrypoints detect pre-installed tools
Each forge entrypoint SHALL check for pre-installed tool binaries at `/home/forge/.tools/` before attempting to download and install.

@trace spec:layered-tools-overlay

#### Scenario: Claude Code from overlay
- **WHEN** the Claude entrypoint runs and `/home/forge/.tools/claude/bin/claude` is executable
- **THEN** the entrypoint SHALL use that binary directly
- **AND** SHALL skip `install_claude()` and `update_claude()`
- **AND** SHALL add `/home/forge/.tools/claude/bin` to PATH

#### Scenario: OpenCode from overlay
- **WHEN** the OpenCode entrypoint runs and `/home/forge/.tools/opencode/bin/opencode` is executable
- **THEN** the entrypoint SHALL use that binary directly
- **AND** SHALL skip `ensure_opencode()`

#### Scenario: OpenSpec from overlay
- **WHEN** any entrypoint runs and `/home/forge/.tools/openspec/bin/openspec` is executable
- **THEN** the entrypoint SHALL use that binary directly
- **AND** SHALL skip `install_openspec()`
- **AND** SHALL add `/home/forge/.tools/openspec/bin` to PATH

### Requirement: Builder container populates overlay
The overlay SHALL be populated by running a temporary container from the current forge image, ensuring binary compatibility between the build environment and runtime environment.

@trace spec:layered-tools-overlay

#### Scenario: Builder container installs tools
- **WHEN** a new overlay version is being built
- **THEN** the system SHALL run `podman run --rm` with the forge image
- **AND** the builder SHALL install Claude Code, OpenCode, and OpenSpec into the mounted output directory
- **AND** the builder SHALL use the enclave proxy if available
- **AND** npm install paths inside the builder SHALL match the mount paths inside forge containers (`/home/forge/.tools/`)

#### Scenario: Builder container security
- **WHEN** the builder container runs
- **THEN** it SHALL use the same security flags as forge containers (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`)

### Requirement: Background version checking and updates
The system SHALL check for tool version updates in the background, without blocking container launches. Updates SHALL be applied by building a new overlay version and atomically swapping the symlink.

@trace spec:layered-tools-overlay

#### Scenario: Version check on launch
- **WHEN** a container is launched and the overlay exists
- **THEN** the system SHALL spawn a background task to check tool versions
- **AND** the container launch SHALL NOT wait for the check to complete
- **AND** version checks SHALL be rate-limited to once per 24 hours

#### Scenario: Update available
- **WHEN** a version check detects newer tool versions
- **THEN** the system SHALL build a new overlay version in the background
- **AND** atomically swap the `current` symlink when the build completes
- **AND** keep one previous version for rollback
- **AND** delete versions older than the previous version

#### Scenario: Update during active containers
- **WHEN** an overlay update completes while containers are running
- **THEN** running containers SHALL continue using the old overlay (they hold the bind-mount)
- **AND** the next container launch SHALL use the new overlay

### Requirement: Forge image version tracking
The overlay manifest SHALL record which forge image version was used to build it. If the forge image changes, the overlay SHALL be rebuilt automatically.

@trace spec:layered-tools-overlay

#### Scenario: Forge image upgrade triggers rebuild
- **WHEN** `ensure_tools_overlay()` detects that `manifest.forge_image` does not match the current forge image tag
- **THEN** the system SHALL trigger an overlay rebuild using the new forge image
- **AND** the rebuild SHALL block the container launch (like a first launch)

### Requirement: Cross-platform support
The tools overlay SHALL work on Linux (native podman), macOS (podman machine), and Windows (podman machine with WSL2).

@trace spec:layered-tools-overlay

#### Scenario: Linux
- **WHEN** running on Linux
- **THEN** the overlay directory lives on the native filesystem
- **AND** bind-mounts and symlinks work natively

#### Scenario: macOS
- **WHEN** running on macOS with podman machine
- **THEN** the overlay directory lives under `~/.cache/tillandsias/` which is mapped into the VM via virtiofs
- **AND** bind-mounts and symlinks work through the VM filesystem

#### Scenario: Windows
- **WHEN** running on Windows with podman machine
- **THEN** the overlay directory lives under `~/.cache/tillandsias/` which is mapped into the WSL2 VM
- **AND** POSIX symlinks work inside the VM natively
