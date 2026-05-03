<!-- @trace spec:artifact-detection -->
# artifact-detection Specification

## Status

status: active

## Purpose
TBD - created by archiving change tillandsias-bootstrap. Update Purpose after archive.
## Requirements
### Requirement: Standard file detection
Artifact detection SHALL rely exclusively on existing standard files (Containerfile, Dockerfile, package.json, Cargo.toml, etc.) and MUST NOT introduce proprietary file formats, custom extensions, or custom manifests.

#### Scenario: Containerfile present
- **WHEN** a project directory contains a `Containerfile` or `Dockerfile`
- **THEN** the project is marked as having a buildable artifact

#### Scenario: No recognized files
- **WHEN** a project directory contains no recognized artifact files
- **THEN** the project is still available for "Attach Here" but shows no Start action

#### Scenario: Multiple artifact types
- **WHEN** a project directory contains both a `Containerfile` and a `package.json`
- **THEN** the Containerfile takes precedence as the buildable artifact definition

### Requirement: Transparent over existing infrastructure
The artifact system SHALL build entirely on existing container infrastructure. Container definitions (Containerfiles) ARE the artifact definitions — they are themselves reproducible, correct, and secure.

#### Scenario: Standard Containerfile
- **WHEN** a project has a standard Containerfile with no tillandsias-specific modifications
- **THEN** Tillandsias can detect, build, and run it without any changes to the Containerfile

#### Scenario: Multi-stage Containerfile
- **WHEN** a project has a multi-stage Containerfile
- **THEN** Tillandsias builds it using standard podman build semantics with no special handling

### Requirement: Nix build artifact support
The artifact system SHALL recognize Nix build definitions (`flake.nix`, `default.nix`) as buildable artifacts, leveraging the shared Nix cache for reproducible builds.

#### Scenario: Nix flake present
- **WHEN** a project directory contains a `flake.nix`
- **THEN** the project is marked as having a Nix-buildable artifact

#### Scenario: Nix build uses shared cache
- **WHEN** a Nix build is triggered
- **THEN** the build uses the shared Nix cache at `~/.cache/tillandsias/nix/` enabling artifact reuse across projects and rebuilds

### Requirement: Runtime metadata detection
The artifact detection system SHALL detect runtime configuration from per-project `.tillandsias/config.toml` when present, providing explicit control over how the project is run.

#### Scenario: Explicit runtime config
- **WHEN** a project has `.tillandsias/config.toml` with a `[runtime]` section
- **THEN** the runtime configuration takes precedence over heuristic detection

#### Scenario: No explicit config
- **WHEN** a project has no `.tillandsias/config.toml`
- **THEN** the artifact detection falls back to heuristic file-based detection

### Requirement: Built image detection
> **Status: Future** — Not yet implemented. All projects show "Attach Here" regardless of image state.
The artifact system SHALL check for previously built container images to enable instant start without rebuilding.

#### Scenario: Image already built
- **WHEN** a container image matching the project name exists in the local podman image store
- **THEN** the project shows a Start action that launches the existing image without rebuilding

#### Scenario: Image outdated
- **WHEN** the project's Containerfile has been modified after the last image build
- **THEN** the project shows a Rebuild option alongside the Start action

### Requirement: Convention-based project type detection
The artifact system SHALL detect project types from standard project files to inform default build and run strategies.

#### Scenario: Node.js project
- **WHEN** a project directory contains `package.json`
- **THEN** it is detected as a Node.js project type

#### Scenario: Rust project
- **WHEN** a project directory contains `Cargo.toml`
- **THEN** it is detected as a Rust project type

#### Scenario: Python project
- **WHEN** a project directory contains `pyproject.toml` or `requirements.txt`
- **THEN** it is detected as a Python project type

#### Scenario: Go project
- **WHEN** a project directory contains `go.mod`
- **THEN** it is detected as a Go project type

#### Scenario: Unknown project type
- **WHEN** a project directory contains no recognized project files
- **THEN** it is classified as unknown but still eligible for "Attach Here" with the generic forge environment


## Sources of Truth

- `cheatsheets/build/cargo.md` — Cargo reference and patterns
- `cheatsheets/utils/gh-cli.md` — Gh Cli reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Observable ephemeral guarantee: resources created during initialization are destroyed on shutdown
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked resources, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:artifact-detection" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
