## ADDED Requirements

### Requirement: Terminal log output when launched from CLI
The application SHALL output structured logs to stderr when launched from a terminal.

#### Scenario: CLI launch
- **WHEN** tillandsias is launched from a terminal (stderr is a TTY)
- **THEN** log events are printed to stderr in human-readable format

### Requirement: File log output always
The application SHALL always write logs to a file at the platform-appropriate state directory.

#### Scenario: Log file location
- **WHEN** the application starts
- **THEN** logs are written to `~/.local/state/tillandsias/tillandsias.log` (Linux)

#### Scenario: Logs are ephemeral
- **WHEN** the user deletes the log file
- **THEN** the application creates a new one on next run with no data loss or errors

### Requirement: Modular log filtering via environment variable
The application SHALL support `TILLANDSIAS_LOG` environment variable for module-level log filtering.

#### Scenario: Default log level
- **WHEN** `TILLANDSIAS_LOG` is not set
- **THEN** the default filter is `tillandsias=info`

#### Scenario: Custom log level
- **WHEN** `TILLANDSIAS_LOG=tillandsias_podman=debug` is set
- **THEN** only the podman crate logs at debug level

### Requirement: Container lifecycle logging
All container lifecycle operations SHALL emit structured log events with relevant context fields.

#### Scenario: Container start logged
- **WHEN** a container is launched via "Attach Here"
- **THEN** an info-level event is emitted with container name, project, genus, port range, and image tag

#### Scenario: Container stop logged
- **WHEN** a container is stopped
- **THEN** an info-level event is emitted with container name and stop duration

#### Scenario: Error logged with context
- **WHEN** a container operation fails
- **THEN** an error-level event is emitted with the operation, container name, and error details
