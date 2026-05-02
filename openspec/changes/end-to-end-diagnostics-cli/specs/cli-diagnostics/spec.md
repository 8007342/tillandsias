<!-- @trace spec:cli-diagnostics -->

# cli-diagnostics Specification

## Purpose

Define the `--diagnostics` command-line flag for real-time inspection of Tillandsias container logs. Enables troubleshooting of container lifecycle, build failures, and runtime issues without requiring manual `podman logs` commands.

## ADDED Requirements

### Requirement: Diagnostics flag streams container logs to terminal

The `tillandsias --diagnostics <project-path>` command SHALL spawn live `podman logs -f` processes for all running Tillandsias-managed containers (shared infra + project-specific) and aggregate their output to the user's terminal with clear source labeling.

#### Scenario: User invokes diagnostics for a project
- **WHEN** user runs `tillandsias --diagnostics /path/to/project`
- **THEN** the command tails logs from proxy, git, inference (shared infra) + forge, browser-core, browser-framework (project-specific) containers
- **AND** each log line is prefixed with `[container_name]` for clarity
- **AND** output streams to stderr so it's not captured by pipes (unless explicitly redirected)

#### Scenario: Diagnostics shows real-time events
- **WHEN** containers emit log events (e.g., "Started listening on :4096")
- **THEN** those events appear in the diagnostics output within 1 second
- **AND** user can Ctrl+C to stop tailing

#### Scenario: Container doesn't exist
- **WHEN** user runs diagnostics for a project with no running containers
- **THEN** the command prints a clear message: "No running Tillandsias containers found for project: /path/to/project"
- **AND** exits gracefully with code 0

#### Scenario: Diagnostics respects project-specific containers
- **WHEN** user runs `tillandsias --diagnostics /project-a` while containers for /project-b are also running
- **THEN** only containers for /project-a are tailed (not /project-b's containers)
- **AND** shared infrastructure containers (proxy, git, inference) are always included

### Requirement: Container source labels are consistent and scannable

Every log line SHALL be prefixed with a source label in format `[<container-type>:<project-name-or-shared>]` for easy scanning and filtering.

#### Scenario: Log prefix format
- **WHEN** forge container for "visual-chess" project logs "OpenCode Web listening on :4096"
- **THEN** the output shows: `[forge:visual-chess] OpenCode Web listening on :4096`

#### Scenario: Shared infrastructure labels
- **WHEN** proxy container (shared across all projects) logs "CONNECT example.com:443"
- **THEN** the output shows: `[proxy:shared] CONNECT example.com:443`

#### Scenario: User can grep for container source
- **WHEN** user pipes diagnostics to grep: `tillandsias --diagnostics /project | grep '\[forge'`
- **THEN** only forge container logs are shown

### Requirement: Diagnostics command is non-blocking and user-interruptible

The diagnostics process SHALL run indefinitely until the user presses Ctrl+C, allowing continuous monitoring of container lifecycle.

#### Scenario: Clean interrupt
- **WHEN** user runs `tillandsias --diagnostics /project` and presses Ctrl+C after 5 seconds
- **THEN** all `podman logs -f` processes are terminated immediately
- **AND** command exits cleanly with code 0 (SIGINT received)

#### Scenario: Error handling during streaming
- **WHEN** a container is stopped or removed while diagnostics is running
- **THEN** the corresponding `podman logs -f` process exits gracefully
- **AND** diagnostics continues tailing other containers
- **AND** does not crash or hang

## Sources of Truth

- `docs/cheatsheets/podman-logging.md` — `podman logs` options, filtering, timestamp formats
- `docs/cheatsheets/container-lifecycle.md` — container state transitions and cleanup
