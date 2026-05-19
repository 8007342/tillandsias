# user-runtime-lifecycle Specification

@trace spec:user-runtime-lifecycle

## Status

active

## Requirements

### Requirement: User runtime images are reproducible local artifacts

User runtime images MUST be built from versioned repository image sources and local build context. The images are cache artifacts and MUST be rebuildable without durable project data loss.

#### Scenario: Runtime image cache is missing

- **WHEN** a required user runtime image is absent
- **THEN** the build path MUST rebuild it from the repository image source
- **AND** user project state MUST not be treated as part of the image cache

### Requirement: Host prerequisites are explicit

The lifecycle MUST treat Podman and required host tools as explicit prerequisites. Missing prerequisites MUST produce user-facing diagnostics instead of hidden auto-install attempts in normal runtime paths.

#### Scenario: Podman is unavailable

- **WHEN** a runtime image build or launch requires Podman and Podman is unavailable
- **THEN** the command MUST fail with a prerequisite diagnostic
- **AND** it MUST not claim that the runtime image was built or launched

## Sources of Truth

- `cheatsheets/runtime/container-lifecycle.md` - Container lifecycle behavior
- `cheatsheets/runtime/image-lifecycle.md` - Image lifecycle behavior
- `cheatsheets/runtime/container-image-tagging.md` - Image tag semantics
- `cheatsheets/runtime/linux-user-session-podman.md` - Host prerequisite context

