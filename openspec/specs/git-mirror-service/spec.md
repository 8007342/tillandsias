# git-mirror-service Specification

## Purpose

Per-project bare mirror repositories with git daemon serving clones over the enclave network. Post-receive hooks auto-push to remote. D-Bus forwarding provides host keyring access for credentials.

## Requirements

### Requirement: Bare mirror repository management
The system SHALL create and maintain a bare mirror repository for each project at `~/.cache/tillandsias/mirrors/<project>/`. The mirror SHALL be initialized from the project directory on first launch and updated from remote (if configured) on subsequent launches.

@trace spec:git-mirror-service

#### Scenario: Project with remote origin
- **WHEN** a project directory is a git repo with a configured remote `origin`
- **AND** no mirror exists for this project
- **THEN** the system SHALL create a bare mirror via `git clone --mirror <remote-url>` into `~/.cache/tillandsias/mirrors/<project>/`

#### Scenario: Project with local-only git repo
- **WHEN** a project directory is a git repo without a remote `origin`
- **AND** no mirror exists for this project
- **THEN** the system SHALL create a bare mirror via `git clone --mirror <local-path>` into `~/.cache/tillandsias/mirrors/<project>/`

#### Scenario: Project directory is not a git repo
- **WHEN** a project directory does not contain a `.git` directory
- **THEN** the system SHALL run `git init` and create an initial commit in the project directory
- **AND** then create a bare mirror from the initialized repo

#### Scenario: Mirror already exists
- **WHEN** a mirror already exists for the project
- **THEN** the system SHALL fetch updates from remote (if configured) via `git fetch --all` in the mirror

### Requirement: Git daemon serves mirrors on enclave network
The git service container SHALL run `git daemon` with `--export-all --enable=receive-pack` on the enclave network. Forge containers SHALL clone from `git://git-service/<project>` where `git-service` resolves via the enclave network DNS.

@trace spec:git-mirror-service

#### Scenario: Forge container clones from mirror
- **WHEN** a forge container starts
- **THEN** it SHALL be able to run `git clone git://git-service/<project>` and receive a full working copy

#### Scenario: Forge container pushes to mirror
- **WHEN** a forge container runs `git push origin <branch>`
- **THEN** the push SHALL succeed against the git daemon's receive-pack
- **AND** the commits SHALL be persisted in the bare mirror on the host filesystem

#### Scenario: Multiple forge containers clone independently
- **WHEN** two forge containers clone the same project mirror
- **THEN** each SHALL have an independent working tree
- **AND** pushes from one SHALL be visible to the other after fetch

### Requirement: Post-receive hook auto-pushes to remote
The bare mirror SHALL contain a `post-receive` hook that automatically pushes to `origin` after receiving commits from forge containers. If no remote is configured, the hook SHALL be a no-op.

@trace spec:git-mirror-service

#### Scenario: Push triggers auto-push to remote
- **WHEN** a forge container pushes to the mirror
- **AND** the mirror has a remote `origin` configured
- **THEN** the post-receive hook SHALL run `git push --mirror origin`
- **AND** log the result via `--log-git`

#### Scenario: Push to local-only mirror
- **WHEN** a forge container pushes to the mirror
- **AND** the mirror has no remote `origin`
- **THEN** the post-receive hook SHALL log "no remote configured, skipping push" and exit cleanly

#### Scenario: Remote push fails (expired credentials)
- **WHEN** the post-receive hook attempts to push to remote
- **AND** the push fails (e.g., 401 Unauthorized)
- **THEN** the hook SHALL log the error via `--log-git`
- **AND** the commits SHALL remain safe in the local mirror
- **AND** the user can refresh credentials via "GitHub Login" in the tray

### Requirement: D-Bus forwarding for host keyring access
The git service container SHALL have the host's D-Bus session bus socket forwarded so that `gh` CLI can access the host OS keyring for GitHub credentials. Credentials SHALL never be written to disk inside the container.

@trace spec:git-mirror-service, spec:secrets-management

#### Scenario: gh auth uses host keyring
- **WHEN** the git service container runs `gh auth token`
- **THEN** it SHALL retrieve the token from the host OS keyring via D-Bus
- **AND** no token SHALL be written to any file inside the container

#### Scenario: D-Bus unavailable
- **WHEN** the D-Bus session bus is not available (headless/SSH)
- **THEN** the git service container SHALL start without credential access
- **AND** remote push operations SHALL fail with an authentication error until the user re-authenticates via "GitHub Login" in an environment with a reachable keyring
- **AND** the system SHALL log a warning via `--log-git`

### Requirement: Git service container lifecycle
The git service container SHALL be started per-project when the first forge container launches and stopped when all forge containers for that project stop. The container name SHALL be `tillandsias-git-<project>`.

@trace spec:git-mirror-service

#### Scenario: Git service starts with first forge
- **WHEN** a forge container is launched for a project
- **AND** no git service is running for that project
- **THEN** the system SHALL start `tillandsias-git-<project>` before launching the forge

#### Scenario: Git service stops when last forge stops
- **WHEN** the last forge container for a project stops
- **THEN** the system SHALL stop `tillandsias-git-<project>`

### Requirement: Git accountability window
All git mirror operations SHALL be logged to the `--log-git` accountability window. Events SHALL include mirror creation, fetch, clone, push, and remote push results. No credentials SHALL appear in logs.

@trace spec:git-mirror-service, spec:runtime-logging

#### Scenario: Mirror creation logged
- **WHEN** a mirror is created for a project
- **THEN** the system SHALL log `[git] Mirror created: <project>` with `@trace spec:git-mirror-service`

#### Scenario: Remote push result logged
- **WHEN** a post-receive hook pushes to remote
- **THEN** the system SHALL log `[git] Remote push: <project> → origin (<success|failure>)` with `@trace spec:git-mirror-service`
