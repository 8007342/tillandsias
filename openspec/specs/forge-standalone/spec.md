<!-- @trace spec:forge-standalone -->
# spec: forge-standalone

## Status

draft

## Purpose

Define the single-container forge troubleshooting path. This artifact lets an
operator launch only the forge image, mount one host project directory, and
enter an interactive bash session for local diagnosis or in-container
development. This is the canonical name for the standalone forge launcher and
supersedes the older `forge-standalone-runner` artifact set.

## Requirements

### Requirement: Standalone forge runner uses the forge image only

The standalone runner SHALL launch `tillandsias-forge:v<VERSION>` directly and
MUST NOT start the proxy, git, inference, or tray stack.

#### Scenario: Single-container debug launch
- **WHEN** `./run-forge-standalone.sh --src /path/to/project` is invoked
- **THEN** only the forge container is started
- **AND** no enclave orchestration script is executed
- **AND** no sidecar containers are created

### Requirement: Source mount is project-scoped

The runner SHALL mount exactly the basename of `--src` at
`/home/forge/src/<project>`.

#### Scenario: Project directory mount
- **WHEN** `--src /work/my-app` is provided
- **THEN** the container SHALL see `/home/forge/src/my-app`
- **AND** no other host directory SHALL be mounted for project content

### Requirement: Interactive bash session

The runner SHALL drop into an interactive bash session inside the forge image.

#### Scenario: Operator gets a shell
- **WHEN** the container starts successfully
- **THEN** the user lands in bash
- **AND** the forge tools baked into the image are available on PATH

### Requirement: Full network access without enclave wiring

The standalone runner SHALL not apply the enclave network, proxy chain, or git
mirror wiring. The container may use the normal Podman network so the operator
can reach external services while debugging.

#### Scenario: Internet access during troubleshooting
- **WHEN** a user runs package or model commands inside the shell
- **THEN** outbound network access remains available
- **AND** no proxy or git sidecars are required

### Requirement: Runner is fail-fast and explicit

The runner SHALL fail with a clear error if `--src` is missing, invalid, or the
forge image is absent.

#### Scenario: Missing source path
- **WHEN** the user omits `--src`
- **THEN** the runner exits with a usage error

#### Scenario: Missing forge image
- **WHEN** the forge image tag is not available locally
- **THEN** the runner exits with a build/setup error
- **AND** the message instructs the operator to build the forge image first
- **AND** the runner does not fall back to `:latest`

## Sources of Truth

- `images/default/Containerfile` - forge image contents and baked tooling
- `build-forge.sh` - host-level forge image build companion
- `run-forge-standalone.sh` - standalone troubleshooting shell launcher
- `cheatsheets/runtime/forge-container.md` - forge runtime boundaries and shell expectations
- `cheatsheets/runtime/forge-standalone.md` - operator-facing standalone troubleshooting guide
- `cheatsheets/build/container-image-building.md` - direct podman build model for image recipes

## Litmus Chain

The standalone forge path should be exercised in isolation before widening the
scope:

1. `./scripts/run-litmus-test.sh forge-standalone`
1. `./scripts/run-litmus-test.sh default-image`
1. `./scripts/run-litmus-test.sh podman-container-spec`
1. `./scripts/run-litmus-test.sh podman-container-handle`
1. `./build.sh --ci --strict --filter forge-standalone:default-image:podman-container-spec:podman-container-handle`
1. `./build.sh --ci-full --install --strict --filter forge-standalone:default-image:podman-container-spec:podman-container-handle:podman-orchestration`
1. `./run-forge-standalone.sh --src ../visual-chess`
