## MODIFIED Requirements

### Requirement: Event-driven container status
Container state changes SHALL be detected via `podman events --format json` as a long-running subprocess feeding the event loop. The application MUST NOT poll for container status.

#### Scenario: Container died with --rm flag
- **WHEN** a `--rm` container dies and is automatically removed by podman
- **THEN** the event stream detects the `died` or `cleanup` status and emits a Stopped event

#### Scenario: Podman event JSON parsing
- **WHEN** a podman event is received as JSON
- **THEN** the parser reads Podman-native fields (`Name`, `Status`) not Docker fields (`Actor.Attributes.name`, `Action`)

#### Scenario: Event stream filtering
- **WHEN** the event stream is started
- **THEN** it listens for all container events (no name-based filter on the podman command) and filters by the `tillandsias-` prefix in-process

#### Scenario: Podman events unavailable with --rm containers
- **WHEN** podman events are not available and the fallback exponential backoff is active
- **AND** a previously-running `--rm` container has died and been removed
- **THEN** the fallback detects the container's absence from `podman ps` output and emits a Stopped event
