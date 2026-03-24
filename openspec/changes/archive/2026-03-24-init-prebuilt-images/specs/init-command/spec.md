## ADDED Requirements

### Requirement: Init CLI command
The application SHALL provide a `tillandsias init` command that pre-builds all container images.

#### Scenario: First run
- **WHEN** `tillandsias init` is run and no forge image exists
- **THEN** the forge image is built, progress is shown on stdout, and the command exits with code 0

#### Scenario: Images already exist
- **WHEN** `tillandsias init` is run and the forge image already exists
- **THEN** the command prints "Images up to date" and exits immediately

#### Scenario: Build in progress
- **WHEN** `tillandsias init` is run and another init process is already building
- **THEN** the command waits for the existing build to complete instead of starting a duplicate

#### Scenario: Help text
- **WHEN** `tillandsias --help` is run
- **THEN** the `init` subcommand is listed with description "Pre-build container images"
