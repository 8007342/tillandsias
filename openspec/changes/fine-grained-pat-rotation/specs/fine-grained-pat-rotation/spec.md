## ADDED Requirements

### Requirement: Per-project scoped GitHub tokens
Containers SHALL receive a GitHub token scoped to only the project's repository, not the user's full OAuth token.

#### Scenario: Forge container receives scoped token
- **GIVEN** the user has completed GitHub App setup
- **AND** the project "tetris" has a git remote pointing to "alice/tetris" on GitHub
- **WHEN** the user clicks "Attach Here" for project "tetris"
- **THEN** the container is launched with a GitHub installation token scoped to only the "tetris" repository
- **AND** the token is mounted read-only at `/run/secrets/github_token`
- **AND** the token has `contents: write` and `metadata: read` permissions only

#### Scenario: Maintenance terminal receives scoped token
- **GIVEN** the user has completed GitHub App setup
- **WHEN** the user opens a maintenance terminal for project "tetris"
- **THEN** the terminal container receives the same scoped token as a forge container

#### Scenario: Multiple projects get independent tokens
- **GIVEN** the user has "tetris" and "cool-app" running simultaneously
- **WHEN** both containers are inspected
- **THEN** each container has a different token
- **AND** the "tetris" container's token cannot access the "cool-app" repository
- **AND** the "cool-app" container's token cannot access the "tetris" repository

### Requirement: GIT_ASKPASS credential delivery
Containers SHALL use a `GIT_ASKPASS` helper script for git authentication instead of the `gh` CLI credential helper.

#### Scenario: Git push uses GIT_ASKPASS
- **WHEN** a user runs `git push origin main` inside a forge container
- **THEN** git invokes the `GIT_ASKPASS` script at `/usr/local/bin/git-askpass-tillandsias`
- **AND** the script returns username `x-access-token` and the token from `/run/secrets/github_token`
- **AND** the push succeeds

#### Scenario: GIT_ASKPASS script is read-only
- **WHEN** a process inside the container attempts to modify `/usr/local/bin/git-askpass-tillandsias`
- **THEN** the write fails (script is owned by root, not writable by forge user)

### Requirement: Automatic token rotation
Scoped tokens SHALL be automatically rotated before expiry without user intervention.

#### Scenario: Token rotated before expiry
- **GIVEN** a forge container has been running for 55 minutes
- **WHEN** the rotation daemon checks token age
- **THEN** a new token is minted via the GitHub API
- **AND** the token file at `/run/secrets/github_token` is atomically replaced with the new token
- **AND** the old token remains valid for approximately 5 more minutes

#### Scenario: Token rotation is transparent to container
- **GIVEN** a forge container is running with an active git session
- **WHEN** a token rotation occurs on the host
- **THEN** the next git operation inside the container uses the new token automatically
- **AND** no container restart is needed

#### Scenario: Rotation failure with retry
- **GIVEN** the GitHub API is temporarily unreachable
- **WHEN** the rotation daemon attempts to mint a new token and fails
- **THEN** the daemon retries with exponential backoff (5s, 10s, 20s, 40s, 60s)
- **AND** the existing token continues to be used until it expires

#### Scenario: Sustained rotation failure falls back to OAuth
- **GIVEN** the GitHub API has been unreachable for 5 consecutive retry attempts
- **WHEN** the rotation daemon exhausts retries
- **THEN** an error is logged
- **AND** the container's existing token is used until expiry
- **AND** if the token expires, git operations fail with a credentials error (this is expected -- the API is unreachable)

### Requirement: GitHub App registration flow
Users SHALL be able to register a GitHub App for Tillandsias through a browser-based flow accessible from the tray menu.

#### Scenario: First-time App setup
- **WHEN** the user clicks "Set Up GitHub App" in the tray Settings menu
- **THEN** the default browser opens to GitHub's App registration page with a pre-filled manifest
- **AND** the manifest requests only `contents: write` and `metadata: read` permissions
- **AND** the App is registered as private (not visible to other users)

#### Scenario: App credentials stored securely
- **WHEN** the App registration completes
- **THEN** the App's private key (PEM) is stored in the OS native keyring
- **AND** the App ID and installation ID are stored in `~/.config/tillandsias/config.toml`
- **AND** no credentials are written to any container-accessible path

#### Scenario: App not configured falls back to OAuth
- **GIVEN** the user has NOT completed GitHub App setup
- **AND** the user has completed `gh auth login` (OAuth token in keyring)
- **WHEN** the user clicks "Attach Here"
- **THEN** the container receives the OAuth token via the legacy `hosts.yml` mount
- **AND** a log message indicates that scoped tokens are not active

### Requirement: Token file security
Token files on the host SHALL be protected from unauthorized access.

#### Scenario: Token file permissions
- **WHEN** a token file is written to `~/.cache/tillandsias/secrets/<project>/github_token`
- **THEN** the file has permissions 0600 (owner read/write only)
- **AND** the file is owned by the current user

#### Scenario: Atomic token write
- **WHEN** the rotation daemon writes a new token
- **THEN** the token is first written to a temporary file in the same directory
- **AND** the temporary file is renamed to the final path
- **AND** at no point is a partial token visible at the final path

#### Scenario: Token cleanup on container stop
- **WHEN** a container stops (exit, user stop, or destroy)
- **THEN** the token file for that project is deleted from the host
- **AND** the token expires naturally after its 1-hour lifetime (no API revocation call)

### Requirement: Repository name resolution
The system SHALL automatically determine the GitHub repository associated with a project directory.

#### Scenario: HTTPS remote URL
- **GIVEN** a project's `.git/config` has `url = https://github.com/alice/tetris.git` for the origin remote
- **WHEN** the repository name is resolved
- **THEN** the result is `alice/tetris`

#### Scenario: SSH remote URL
- **GIVEN** a project's `.git/config` has `url = git@github.com:alice/tetris.git` for the origin remote
- **WHEN** the repository name is resolved
- **THEN** the result is `alice/tetris`

#### Scenario: Non-GitHub remote
- **GIVEN** a project's `.git/config` has a remote URL pointing to GitLab or another host
- **WHEN** the repository name is resolved
- **THEN** the result is `None`
- **AND** the container falls back to the OAuth token

#### Scenario: No git repository
- **GIVEN** a project directory does not contain a `.git/` directory
- **WHEN** the repository name is resolved
- **THEN** the result is `None`
- **AND** the container is launched without any GitHub token (no git credentials needed)

## MODIFIED Requirements

### Requirement: Container volume mounts (updated)
Container volume mounts SHALL include a token file mount instead of (or in addition to) the `hosts.yml` mount.

#### Scenario: Container launched with token file mount (Phase 1+)
- **WHEN** a forge or maintenance container is launched
- **THEN** the container has `-v <host_path>/github_token:/run/secrets/github_token:ro` in its mount list
- **AND** the container has `-e GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias` in its environment

#### Scenario: hosts.yml mount removed (Phase 4)
- **GIVEN** the GitHub App is configured and working
- **WHEN** a container is launched after Phase 4 migration
- **THEN** the container does NOT have a `hosts.yml` mount at `/home/forge/.config/gh`
- **AND** the `gh` CLI inside the container uses the `GH_TOKEN` env var pointing to the scoped token
