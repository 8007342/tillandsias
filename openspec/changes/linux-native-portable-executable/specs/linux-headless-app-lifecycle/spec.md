# Specification: linux-headless-app-lifecycle

@trace spec:linux-headless-app-lifecycle

## ADDED Requirements

### Requirement: Headless mode launch via --headless flag
The tillandsias binary SHALL support `--headless` runtime flag that launches the application in headless mode (no UI, no tray icon).

#### Scenario: Headless launch succeeds
- **WHEN** user runs `tillandsias --headless /path/to/project`
- **THEN** application starts, initializes containers, and blocks until shutdown signal

#### Scenario: Headless mode disables tray detection
- **WHEN** `--headless` flag is set
- **THEN** application does NOT attempt to spawn or connect to tray UI

### Requirement: Headless application lifecycle (launch → run → exit)
The tillandsias application in headless mode SHALL follow app-lifecycle semantics: start on launch, maintain containers for duration of run, stop and cleanup on exit. The application SHALL NOT daemonize or detach from terminal.

#### Scenario: Containers live during headless run
- **WHEN** headless tillandsias is running
- **THEN** all podman containers remain active and accessible

#### Scenario: Full cleanup on exit
- **WHEN** headless tillandsias receives SIGTERM or user closes stdin
- **THEN** containers stop gracefully (30s timeout), enclave network tears down, secrets are deleted, sockets are cleaned, process exits with code 0

#### Scenario: App does not detach from terminal
- **WHEN** user runs headless tillandsias in foreground
- **THEN** application blocks in terminal; CTRL-C sends SIGINT, triggers graceful shutdown

### Requirement: Headless state output
The headless application SHALL output machine-readable state (JSON or structured logs) so external tools (wrappers, monitoring scripts) can track status.

#### Scenario: State logged on startup and shutdown
- **WHEN** headless application starts
- **THEN** stdout includes JSON with `event: "app.started"`, container IDs, port mappings

- **WHEN** headless application shuts down
- **THEN** stdout includes JSON with `event: "app.stopped"`, exit code

