## MODIFIED Requirements

### Requirement: Enclave service discovery is runtime-driven

Enclave service connectivity SHALL be resolved through `Runtime::service_address(service, port)`. Linux/macOS (PodmanRuntime) SHALL return `<service>:<port>` (the existing podman bridge DNS alias). Windows (WslRuntime) SHALL return `127.0.0.1:<port>` (the shared WSL2 Linux network namespace makes loopback the only correct address). Forge entrypoint scripts SHALL consult `tillandsias-services <service> <port>` (delegates to the runtime) rather than hardcoding alias names.

> Delta: today `proxy:3128`, `git-service:9418`, `inference:11434` are hardcoded in entrypoint scripts. After this change they are emitted by `tillandsias-services`, which the runtime crate populates per-platform.

#### Scenario: Linux enclave network keeps DNS aliases

- **GIVEN** Tillandsias running on Linux with podman
- **WHEN** the forge entrypoint runs `tillandsias-services proxy 3128`
- **THEN** it prints `proxy:3128`

#### Scenario: Windows enclave network is loopback

- **GIVEN** Tillandsias running on Windows with WSL
- **WHEN** the forge entrypoint runs `tillandsias-services proxy 3128`
- **THEN** it prints `127.0.0.1:3128`

#### Scenario: forge can reach proxy via the resolved address

- **WHEN** the forge entrypoint executes `curl --max-time 3 -fsS $(tillandsias-services proxy 3128)/health`
- **THEN** the request completes successfully on both Linux (podman) and Windows (WSL)
