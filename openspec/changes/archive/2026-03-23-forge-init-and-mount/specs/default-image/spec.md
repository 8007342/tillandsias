## ADDED Requirements

### Requirement: Idempotent tool initialization
The entrypoint SHALL install OpenCode and OpenSpec to the persistent cache on first run and skip installation on subsequent runs.

#### Scenario: First run installs tools
- **WHEN** the container starts with an empty cache
- **THEN** OpenCode and OpenSpec are downloaded/installed to the cache directory

#### Scenario: Subsequent runs skip install
- **WHEN** the container starts with cached tools
- **THEN** no downloads occur and the container starts immediately
