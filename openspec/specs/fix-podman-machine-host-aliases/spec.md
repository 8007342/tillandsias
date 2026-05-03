<!-- @trace spec:fix-podman-machine-host-aliases -->
# fix-podman-machine-host-aliases Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-16-fix-podman-machine-host-aliases/
annotation-count: 0
implementation-complete: false

## Purpose

Fix enclave service discovery on Windows/macOS podman-machine by routing container-to-host aliases through the gateway IP instead of hardcoded `127.0.0.1`, which resolves to the container's own loopback.

## Requirements

### Requirement: Enclave Alias Resolution via host-gateway

The podman container argument that maps enclave service aliases (proxy, git-service, inference) MUST use `host-gateway` as the IP address.

#### Scenario: Forge container on podman-machine
- **WHEN** a forge container is started on Windows or macOS with podman-machine
- **WHEN** the podman arguments include `--add-host <alias>:IP`
- **THEN** `IP` MUST be `host-gateway` (not `127.0.0.1` or `localhost`)

#### Magic Value Semantics

The `host-gateway` value is a magic constant that podman/docker resolve at container runtime to the gateway IP of the container. On a podman-machine WSL setup, this resolves to the WSL VM's gateway and is reachable from inside the container.

#### Scenario: Services are reachable by alias from forge
- **WHEN** code inside the forge container connects to `proxy:3128`, `git-service:9418`, or `inference:11434`
- **THEN** the DNS resolution succeeds via the `--add-host` entry
- **WHEN** the connection attempts to route
- **THEN** the traffic routes through the gateway to the actual service on the host/WSL machine

### Requirement: Environment Variables Use Service Aliases

The environment variables rewritten for container use MUST use the service alias names (not `localhost`).

#### Scenario: HTTP proxy env vars
- **WHEN** the forge environment is constructed
- **THEN** `HTTP_PROXY` and `HTTPS_PROXY` are set to `http://proxy:3128` (not `http://localhost:3128`)

#### Scenario: Git service env vars
- **WHEN** the forge environment is constructed
- **THEN** `TILLANDSIAS_GIT_SERVICE` is set to `git-service` (not `localhost`)

#### Scenario: Inference service env vars
- **WHEN** the forge environment is constructed
- **THEN** `OLLAMA_HOST` is set to `http://inference:11434` (not `http://localhost:11434`)

### Requirement: rewrite_enclave_env Hook Remains

The `rewrite_enclave_env` hook in the code MUST be preserved (as a no-op if not needed on the current platform).

#### Scenario: Future platform-specific rewrites
- **WHEN** a future platform or setup requires different enclave env-var values
- **THEN** the hook is available for implementation without refactoring

### Requirement: Tests Assert Correct Flags

Tests covering the port-mapping mode (Windows/macOS) MUST assert:
- The `--add-host alias:host-gateway` flags appear in podman args
- The friendly-alias environment variables (`proxy`, `git-service`, `inference`) are used instead of `localhost`

## Rationale

The previous fix used `--add-host alias:127.0.0.1` with the assumption that `127.0.0.1` would route to the host. On podman-machine, `127.0.0.1` inside the container is the container's own loopback, not the host. The magic `host-gateway` value correctly resolves at container runtime to the reachable gateway IP. Using the alias names in environment variables allows containers to use the same service naming scheme as on Linux (where the real enclave network exists) while the `--add-host` entries redirect those names to the correct IP.

## Sources of Truth

- `docs/cheatsheets/runtime/enclave-network.md` — enclave architecture and service discovery
- `docs/cheatsheets/runtime/container-networking.md` — podman machine networking and aliases
