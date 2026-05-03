<!-- @trace spec:cli-diagnostics -->

# cli-diagnostics Specification

## Status

status: active

## Purpose

Define the `--diagnostics` command-line flag for real-time inspection of Tillandsias container logs. Enables troubleshooting of container lifecycle, build failures, and runtime issues without requiring manual `podman logs` commands.

## ADDED Requirements

### Requirement: Diagnostics flag streams container logs to terminal

The `tillandsias --diagnostics <project-path>` command SHALL spawn live `podman logs -f` processes for all running Tillandsias-managed containers (shared infra + project-specific) and aggregate their output to the user's terminal with clear source labeling.

#### Scenario: User invokes diagnostics for a project
- **WHEN** user runs `tillandsias --diagnostics /path/to/project`
- **THEN** the command tails logs from proxy, git, inference (shared infra) + forge, browser-core, browser-framework (project-specific) containers
- **AND** each log line is prefixed with `[container_type:project_name]` for clarity
- **AND** output streams to stderr so it's not captured by pipes (unless explicitly redirected)

#### Scenario: Diagnostics shows real-time events
- **WHEN** containers emit log events (e.g., "Started listening on :4096")
- **THEN** those events appear in the diagnostics output within 1 second
- **AND** user can Ctrl+C to stop tailing

#### Scenario: Container doesn't exist
- **WHEN** user runs diagnostics for a project with no running containers
- **THEN** the command prints a clear message: "ERROR: no containers found for project: /path/to/project"
- **AND** exits with code 1

#### Scenario: Diagnostics respects project-specific containers
- **WHEN** user runs `tillandsias --diagnostics /project-a` while containers for /project-b are also running
- **THEN** only containers for /project-a are tailed (not /project-b's containers)
- **AND** shared infrastructure containers (proxy, git, inference) are always included

### Requirement: Exit code contract for diagnostics

The diagnostics command SHALL exit with code 0 only when containers exist and logs are being streamed; code 1 when containers are not found or cannot be accessed.

#### Scenario: Containers exist
- **WHEN** `tillandsias /path --diagnostics` is run and containers are running
- **THEN** the command exits with code 0 (when user presses Ctrl+C)
- **AND** safe to chain: `tillandsias /path --diagnostics && echo "stack ready"`

#### Scenario: No containers found
- **WHEN** `tillandsias /path --diagnostics` is run and no containers exist for that project
- **THEN** the command prints error message to stderr and exits with code 1
- **AND** safe for error handling: `! tillandsias /path --diagnostics || echo "stack broken"`

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

### Requirement: Debug mode verbose output

When `--diagnostics --debug` is passed, the command SHALL emit verbose discovery information to stdout before streaming logs.

#### Scenario: Debug mode lists containers
- **WHEN** `tillandsias /path --diagnostics --debug` is run
- **THEN** the command prints `[diagnostics:debug] monitoring: <container_name>` for each discovered running container
- **AND** container startup parameters are logged (e.g., image, mount points)

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

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:cli-diagnostics" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
