## ADDED Requirements

### Requirement: Git service container managed per-project
The system SHALL manage one git service container per project with the name `tillandsias-git-<project>`. The container SHALL be attached to the enclave network with the network alias `git-service`. The mirror volume SHALL be bind-mounted from `~/.cache/tillandsias/mirrors/<project>/`.

@trace spec:podman-orchestration, spec:git-mirror-service

#### Scenario: Git service container started
- **WHEN** a git service container is started for project "myapp"
- **THEN** the container name SHALL be `tillandsias-git-myapp`
- **AND** it SHALL be on network `tillandsias-enclave` with alias `git-service`
- **AND** the mirror SHALL be mounted at `/srv/git/<project>`

#### Scenario: Git service container stopped
- **WHEN** the last forge container for "myapp" stops
- **THEN** `tillandsias-git-myapp` SHALL be stopped
