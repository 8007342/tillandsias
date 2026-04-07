## NEW Requirements

### Requirement: Secrets filesystem layout
Tillandsias SHALL store credentials at `~/.cache/tillandsias/secrets/` organized by category.

#### Scenario: Shared credentials stored by category
- **GIVEN** a user has authenticated with GitHub and configured git identity
- **WHEN** the secrets directory is inspected
- **THEN** GitHub tokens exist under `secrets/gh/`, git config under `secrets/git/`, and SSH keys under `secrets/ssh/`

#### Scenario: Per-project secrets isolated
- **GIVEN** a project has project-specific API keys
- **WHEN** the project secrets are stored
- **THEN** they exist under `<project>/.tillandsias/secrets/` and are not visible to other projects

### Requirement: Transparent container mounting
Secrets SHALL be mounted into forge containers at standard paths so tools work without configuration.

#### Scenario: GitHub CLI works inside forge
- **GIVEN** a user has authenticated via `gh auth login` on the host
- **WHEN** a forge container starts
- **THEN** `gh auth status` succeeds inside the container without re-authentication

#### Scenario: Git identity available inside forge
- **GIVEN** git user.name and user.email are configured in `secrets/git/`
- **WHEN** a forge container starts
- **THEN** `git config user.name` and `git config user.email` return the configured values

#### Scenario: SSH keys available read-only
- **GIVEN** SSH keys exist in `secrets/ssh/`
- **WHEN** a forge container starts
- **THEN** the keys are available at `~/.ssh/` inside the container with read-only permissions

### Requirement: Agent isolation from secrets
The AI agent running inside forge containers SHALL NOT have access to read raw secret values.

#### Scenario: Agent cannot read auth tokens
- **GIVEN** GitHub tokens are mounted inside the container
- **WHEN** the agent attempts to read the token file
- **THEN** the read is blocked by permission controls or path restrictions

#### Scenario: Authentication flow is private
- **GIVEN** a user needs to authenticate with a service
- **WHEN** the authentication skill executes
- **THEN** credentials never appear in the AI conversation context

### Requirement: Phased encryption
Secret storage SHALL support a migration path from plain files to encrypted-at-rest storage.

#### Scenario: Phase 1 plain storage
- **GIVEN** tillandsias is in Phase 1 (MVP)
- **WHEN** secrets are stored
- **THEN** they exist as plain files with restrictive UNIX permissions (0600/0700)

#### Scenario: Phase 2 encrypted storage
- **GIVEN** tillandsias has migrated to Phase 2
- **WHEN** the host filesystem is inspected
- **THEN** `~/.cache/tillandsias/secrets/` contains only encrypted blobs
- **AND** inside running containers, secrets are available decrypted at standard paths
