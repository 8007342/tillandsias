## ADDED Requirements

### Requirement: CLI update flag
The binary SHALL accept a `--update` flag that checks for a newer version and applies it without starting the system tray.

#### Scenario: Already up to date
- **WHEN** `tillandsias --update` is run and the current version matches the latest release
- **THEN** stdout contains the current version, the endpoint URL, and the message "Already up to date."
- **AND** the process exits with code 0

#### Scenario: Update available and applied
- **WHEN** `tillandsias --update` is run and a newer version is available
- **THEN** stdout reports the available version, shows download progress, and prints "Restart the application to use the new version." after the update is applied
- **AND** the process exits with code 0

#### Scenario: Network or signature error
- **WHEN** `tillandsias --update` is run and the network request fails or signature verification fails
- **THEN** an error message is printed to stderr
- **AND** the process exits with code 1

#### Scenario: No Tauri event loop
- **WHEN** `tillandsias --update` is invoked
- **THEN** the Tauri builder is NOT constructed — the update check runs entirely in a plain tokio runtime
- **AND** the process exits after completion rather than remaining resident as a tray app

## MODIFIED Requirements

### Requirement: CLI help text
The `--help` output SHALL list `--update` alongside the other CLI flags.

#### Scenario: Help includes --update
- **WHEN** `tillandsias --help` is run
- **THEN** stdout includes a line describing `--update` and its purpose
