<!-- @trace spec:enclave-network -->
# enclave-network Specification

## Status

status: active

## Purpose

Internal podman network that isolates forge, git, inference, and proxy containers. Only the proxy container has external access (dual-homed). All other containers communicate exclusively through the enclave.

## Requirements

### Requirement: Internal podman network for container isolation
The system SHALL create and manage a podman internal network named `tillandsias-enclave` that prevents containers attached to it from reaching external networks directly. The network SHALL be created on first container launch and persist until the application exits. The network SHALL be reused if already present.

@trace spec:enclave-network

#### Scenario: First container launch creates enclave network
- **WHEN** a container is launched and the `tillandsias-enclave` network does not exist
- **THEN** the system SHALL create it with `podman network create tillandsias-enclave --internal`
- **AND** log the creation via `--log-enclave` with `@trace spec:enclave-network`

#### Scenario: Enclave network already exists
- **WHEN** a container is launched and the `tillandsias-enclave` network already exists
- **THEN** the system SHALL reuse the existing network without error

#### Scenario: Enclave network cleanup on app exit
- **WHEN** the Tillandsias application exits
- **AND** no containers are attached to the `tillandsias-enclave` network
- **THEN** the system SHALL remove the network with `podman network rm tillandsias-enclave`

#### Scenario: Enclave network cleanup skipped when containers active
- **WHEN** the Tillandsias application exits
- **AND** containers are still attached to the `tillandsias-enclave` network
- **THEN** the system SHALL log a warning and leave the network in place

### Requirement: Container attachment to enclave network
The system SHALL attach all Tillandsias-managed containers (proxy, forge, git, inference) to the `tillandsias-enclave` network. Only the proxy container SHALL additionally be attached to the default bridge network for external access.

@trace spec:enclave-network

#### Scenario: Forge container attached to enclave only
- **WHEN** a forge container is launched
- **THEN** it SHALL be attached to the `tillandsias-enclave` network via `--network=tillandsias-enclave`
- **AND** it SHALL NOT have access to the default bridge network

#### Scenario: Proxy container is dual-homed
- **WHEN** the proxy container is launched
- **THEN** it SHALL be attached to both the `tillandsias-enclave` network and the default bridge network
- **AND** it SHALL be reachable from enclave containers at hostname `proxy`

### Requirement: Enclave lifecycle telemetry
All enclave network operations SHALL be logged to the `--log-enclave` accountability window with lifecycle events only (no secrets, no context params). Each event SHALL include a clickable `@trace` link.

@trace spec:enclave-network

#### Scenario: Network creation logged
- **WHEN** the enclave network is created
- **THEN** the system SHALL log `[enclave] Network created: tillandsias-enclave` with `@trace spec:enclave-network`

#### Scenario: Container attachment logged
- **WHEN** a container is attached to the enclave network
- **THEN** the system SHALL log `[enclave] Container attached: <name>` with `@trace spec:enclave-network`

## Sources of Truth

- `cheatsheets/runtime/networking.md` — Networking reference and patterns
- `cheatsheets/runtime/podman.md` — Podman reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:enclave-network" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
