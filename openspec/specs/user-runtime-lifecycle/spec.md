# user-runtime-lifecycle Specification

@trace spec:user-runtime-lifecycle

## Status

active

## Requirements

### Requirement: User runtime images are reproducible release artifacts

User runtime images MUST be built from versioned image sources shipped with the release binary. A normal installed runtime MUST NOT require a Tillandsias source checkout, Rust/Cargo, Nix, toolbox, or host-side image source files. The binary MAY materialize its embedded runtime assets into a versioned user data directory before invoking Podman. The images are cache artifacts and MUST be rebuildable without durable project data loss.

#### Scenario: Runtime image cache is missing

- **WHEN** a required user runtime image is absent
- **THEN** the build path MUST rebuild it from the release-shipped runtime asset tree
- **AND** user project state MUST not be treated as part of the image cache

#### Scenario: Installed runtime has no source checkout

- **WHEN** an installed user runs `tillandsias --init --debug`, `tillandsias --debug --tray`, or `tillandsias --headless /path/to/project` from a directory outside the Tillandsias repository
- **THEN** the command MUST NOT fail because a Tillandsias checkout is missing
- **AND** the runtime MUST resolve image contexts from embedded/materialized release assets
- **AND** `TILLANDSIAS_ROOT` MUST be treated only as an explicit developer override

### Requirement: Host prerequisites are explicit

The lifecycle MUST treat Podman and normal shell/user-session facilities as explicit prerequisites. Missing prerequisites MUST produce user-facing diagnostics instead of hidden auto-install attempts in normal runtime paths.

#### Scenario: Podman is unavailable

- **WHEN** a runtime image build or launch requires Podman and Podman is unavailable
- **THEN** the command MUST fail with a prerequisite diagnostic
- **AND** it MUST not claim that the runtime image was built or launched

## Sources of Truth

- `cheatsheets/runtime/container-lifecycle.md` - Container lifecycle behavior
- `cheatsheets/runtime/image-lifecycle.md` - Image lifecycle behavior
- `cheatsheets/runtime/container-image-tagging.md` - Image tag semantics
- `cheatsheets/runtime/linux-user-session-podman.md` - Host prerequisite context
- `cheatsheets/runtime/user-runtime-install.md` - Checkout-free installer/runtime contract
