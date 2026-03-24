## ADDED Requirements

### Requirement: --bash launches fish with welcome
The `--bash` CLI flag SHALL launch fish (not bash) with the welcome message.

#### Scenario: CLI bash mode shows welcome
- **WHEN** `tillandsias ../project/ --bash` is run
- **THEN** fish starts with the welcome message, landing in the project directory

#### Scenario: Host OS passed to container
- **WHEN** the container starts
- **THEN** the host OS info is available via `TILLANDSIAS_HOST_OS` environment variable for the welcome script to display
