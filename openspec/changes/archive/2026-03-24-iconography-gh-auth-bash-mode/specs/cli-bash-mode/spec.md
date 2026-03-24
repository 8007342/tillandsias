## ADDED Requirements

### Requirement: Bash troubleshooting mode
The CLI SHALL accept a `--bash` flag that overrides the container entrypoint with `/bin/bash` for troubleshooting.

#### Scenario: Attach with bash
- **WHEN** `tillandsias ../project/ --bash` is run
- **THEN** a container starts for the project with `/bin/bash` as the entrypoint instead of the default

#### Scenario: Bash mode with other flags
- **WHEN** `tillandsias ../project/ --bash --debug` is run
- **THEN** the container starts with `/bin/bash` and debug output is shown

#### Scenario: Help includes bash flag
- **WHEN** `tillandsias --help` is run
- **THEN** the `--bash` flag is listed with a description like "Drop into bash shell for troubleshooting"
