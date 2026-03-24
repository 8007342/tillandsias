## MODIFIED Requirements

### Requirement: Credential persistence across container lifecycles
Forge containers SHALL mount persistent git configuration and GitHub CLI credentials from the host cache so that authentication survives container recreation.

#### Scenario: Git identity persists
- **WHEN** a user configures `git config --global user.name` inside a forge container, then stops and re-attaches
- **THEN** the git identity is preserved in the new container without reconfiguration

#### Scenario: GitHub CLI auth persists
- **WHEN** a user runs `gh auth login` inside a forge container, then stops and re-attaches
- **THEN** the GitHub CLI session is preserved and `gh auth status` reports authenticated

#### Scenario: First run with empty credentials
- **WHEN** a forge container starts and the host secrets directory has no prior credentials
- **THEN** the container starts without errors and tools prompt for authentication as normal

#### Scenario: Credential storage location
- **WHEN** credentials are persisted from a forge container
- **THEN** they are stored under `~/.cache/tillandsias/secrets/` on the host filesystem
