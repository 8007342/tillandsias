## ADDED Requirements

### Requirement: User-visible errors contain no internal implementation details
All error strings returned from handlers or printed to user-facing output SHALL be free of container image tags, internal script names, filesystem paths, shell commands, and exit codes.

#### Scenario: Build failure shown to user
- **WHEN** the development environment setup fails for any internal reason
- **THEN** the user sees: "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias"
- **AND** the detailed failure is logged via `tracing::error!` for developers

#### Scenario: Image not available after build attempt
- **WHEN** the environment image is not ready (build did not produce the image)
- **THEN** the user sees: "Development environment not ready yet. Tillandsias will set it up automatically — please try again in a few minutes."
- **AND** the internal image name and build context are logged via `tracing::error!`

#### Scenario: Embedded script cannot be extracted
- **WHEN** an embedded resource cannot be written to the runtime temp directory
- **THEN** the user sees: "Tillandsias installation may be incomplete. Please reinstall from https://github.com/8007342/tillandsias"
- **AND** the OS error is logged via `tracing::error!`

### Requirement: Detailed errors are preserved in structured logs
Sanitizing user-visible messages SHALL NOT remove diagnostic information from the logging layer.

#### Scenario: Error logged alongside sanitized message
- **WHEN** a handler returns a sanitized `Err()` string
- **THEN** the full technical error (exit code, script path, stderr) is emitted at `tracing::error!` level before returning
