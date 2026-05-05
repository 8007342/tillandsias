# Codex Container Image

@trace spec:codex-container-image, spec:forge-hot-cold-split

**Purpose**: Define the container image requirements for running Codex agent in the Tillandsias enclave, with Codex pre-baked into the forge image for zero-startup-latency launch.

## ADDED Requirements

### Requirement: Codex binary pre-installed in forge image

The forge image SHALL include the Codex binary/tooling baked into the image during build time via the "cold layer" (Nix `flake.nix` build system).

#### Scenario: Codex binary is present in built image
- **WHEN** the forge image build completes
- **THEN** the Codex binary is available at `/opt/codex` (or the expected entrypoint path)
- **AND** Codex dependencies (if any) are also present in the image
- **AND** no runtime pull is required when a Codex container launches

#### Scenario: Image size impact is acceptable
- **WHEN** the forge image is built with Codex pre-installed
- **THEN** the total image size increase is ≤ 100 MB (acceptable per design trade-off analysis)

#### Scenario: Codex entrypoint is executable
- **WHEN** a Codex container starts with the image
- **THEN** the entrypoint successfully launches Codex without missing dependencies
- **AND** Codex is ready to accept input (confirmed by health checks)

### Requirement: Codex container inherits forge enclave environment

The Codex container SHALL inherit the standard forge entrypoint, environment variables, network setup, and security policies from the forge image.

#### Scenario: Codex container joins enclave
- **WHEN** a Codex container is launched via tillandsias-<project>-codex
- **THEN** it runs on the enclave network (same network as proxy, git service, inference)
- **AND** it inherits security flags: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--rm`
- **AND** it receives NO credentials (forge containers are fully offline)

#### Scenario: Codex accesses enclave services
- **WHEN** Codex needs external connectivity (GitHub API, PyPI, etc.)
- **THEN** it routes through the proxy container (enclave-local caching HTTP/S proxy)
- **AND** the proxy allowlist permits Codex egress (see enclave-network spec)

### Requirement: Container naming and metadata

Codex containers SHALL follow the standard Tillandsias naming convention and include appropriate metadata for lifecycle tracking.

#### Scenario: Container is named consistently
- **WHEN** a user launches Codex for project "my-app"
- **THEN** the container is named `tillandsias-my-app-codex`
- **AND** it is tagged with labels for project, genus (codex), and version

#### Scenario: Logs are prefixed for filtering
- **WHEN** Codex stdout/stderr is piped to the tray log
- **THEN** each line is prefixed with `[codex]` for easy filtering and identification
- **AND** the tray progress chip shows "🏗 Codex — <project>" during execution

## Sources of Truth

- `cheatsheets/runtime/container-lifecycle.md` — Container orchestration patterns and security policies
- `cheatsheets/runtime/enclave-network.md` — Enclave topology and proxy routing
- `cheatsheets/build/nix-image-builds.md` — Nix flake.nix patterns for image layer composition
