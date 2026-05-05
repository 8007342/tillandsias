## ADDED Requirements

### Requirement: Multi-container log streaming

The system SHALL support a --diagnostics flag that spawns parallel tails of `/strategic/service.log` from all running containers in a project stack, streaming output directly to the calling terminal for real-time visibility.

#### Scenario: Diagnostics flag spawns log tails
- **WHEN** user runs tillandsias with --diagnostics flag (e.g., `tillandsias tetris --opencode --diagnostics`)
- **THEN** system discovers all containers tagged with `tillandsias-<project>-*` that are currently running
- **AND** for each container, spawns an async process: `podman exec <container_id> tail -f /strategic/service.log`
- **AND** prefixes output from each container with `[<service_name>]` for disambiguation

#### Scenario: Container offline handling
- **WHEN** a container does not have `/strategic/service.log` or exits before tail starts
- **THEN** system emits `[<service_name>] [offline]` message and continues tailing other containers
- **AND** periodically re-discovers containers to detect new ones joining the stack

#### Scenario: User exits diagnostics
- **WHEN** user presses Ctrl+C while diagnostics mode is active
- **THEN** system terminates all tail processes cleanly and exits
- **AND** logs diagnostic session end time for troubleshooting

### Requirement: Log content conventions

All containers running as part of a Tillandsias stack SHALL create `/strategic/service.log` and write diagnostic-level logs (initialization, health checks, critical errors) to this file.

#### Scenario: Proxy container logs to strategic log
- **WHEN** proxy container starts entrypoint
- **THEN** proxy writes initialization status and incoming request summary to `/strategic/service.log`
- **AND** updates log at startup completion and periodically during operation

#### Scenario: Forge container logs to strategic log
- **WHEN** forge container starts via entrypoint
- **THEN** forge writes initialization, user setup, and readiness indicators to `/strategic/service.log`
- **AND** updates log when ready to accept connections

#### Scenario: Git service logs to strategic log
- **WHEN** git-service container starts
- **THEN** git-service writes startup status and authenticated push events to `/strategic/service.log`

#### Scenario: Inference container logs to strategic log
- **WHEN** inference (ollama) container starts
- **THEN** inference writes ollama initialization, health check status, and model loading progress to `/strategic/service.log`

### Requirement: Log rotation

Containers SHALL implement log rotation on `/strategic/service.log` to prevent unbounded growth on long-running stacks.

#### Scenario: Log file rotation at size limit
- **WHEN** `/strategic/service.log` reaches 100MB
- **THEN** system rotates file: `mv /strategic/service.log /strategic/service.log.1`
- **AND** creates new empty `/strategic/service.log` and continues writing
- **AND** older rotated files (service.log.2+) are discarded

#### Scenario: Custom log size via environment
- **WHEN** container starts with TILLANDSIAS_LOG_SIZE=<bytes> set
- **THEN** system uses specified byte limit instead of default 100MB for rotation threshold

## Sources of Truth

- `cheatsheets/runtime/podman.md` — podman exec and container lifecycle management
- `cheatsheets/utils/logging.md` — log rotation and diagnostic logging best practices
