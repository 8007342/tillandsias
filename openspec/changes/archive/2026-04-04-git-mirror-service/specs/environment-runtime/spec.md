## MODIFIED Requirements

### Requirement: Attach Here launches container and opens terminal
When the user triggers "Attach Here" for a project, the system SHALL ensure the enclave network exists, the proxy is running, the git mirror is initialized, and the git service is running. The forge container SHALL clone from the git mirror instead of mounting the project directory directly. The terminal SHALL open with the selected agent.

@trace spec:environment-runtime, spec:git-mirror-service

#### Scenario: First Attach Here (full initialization)
- **WHEN** the user clicks "Attach Here" for a new project
- **THEN** the system SHALL ensure enclave network, proxy, git mirror, and git service
- **AND** launch the forge container on the enclave network
- **AND** the forge entrypoint SHALL run `git clone git://git-service/<project>` into the ephemeral filesystem

#### Scenario: Subsequent Attach Here (services already running)
- **WHEN** the user clicks "Attach Here" and all services are running
- **THEN** the system SHALL launch the forge container directly
- **AND** the forge SHALL clone from the existing mirror (instant, local)

#### Scenario: Multiple containers for same project
- **WHEN** the user launches a second forge container for the same project
- **THEN** both containers SHALL have independent working trees
- **AND** both SHALL clone from the same git mirror
- **AND** the git service SHALL already be running (started by first container)

## ADDED Requirements

### Requirement: Forge entrypoint clones from git mirror
The forge container entrypoint SHALL clone the project from the git mirror via `git clone git://git-service/<project>` into `/home/forge/src/<project>`. The `TILLANDSIAS_GIT_SERVICE` environment variable SHALL contain the git service hostname. Uncommitted changes are ephemeral — lost when the container stops.

@trace spec:environment-runtime, spec:git-mirror-service

#### Scenario: Forge clones on startup
- **WHEN** a forge container starts
- **THEN** the entrypoint SHALL run `git clone git://git-service/$TILLANDSIAS_PROJECT /home/forge/src/$TILLANDSIAS_PROJECT`
- **AND** set the working directory to the cloned project

#### Scenario: Clone fails (git service not ready)
- **WHEN** the git clone fails (e.g., git service not yet listening)
- **THEN** the entrypoint SHALL retry up to 5 times with 1-second delays
- **AND** if all retries fail, print an error and drop to a shell
