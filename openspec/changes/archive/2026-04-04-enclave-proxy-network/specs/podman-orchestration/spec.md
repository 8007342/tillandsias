## MODIFIED Requirements

### Requirement: Security-hardened container defaults
Every Tillandsias-managed container SHALL be launched with non-negotiable security flags that cannot be overridden by profiles, config, or any external source. The flags SHALL include `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--security-opt=label=disable`, `--rm`, `--init`, and `--stop-timeout=10`. Additionally, all containers SHALL be attached to the `tillandsias-enclave` internal network. The proxy container SHALL additionally be attached to the default bridge network.

@trace spec:podman-orchestration, spec:enclave-network

#### Scenario: Default container launch
- **WHEN** a container is launched by Tillandsias
- **THEN** the command SHALL include `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--security-opt=label=disable`, `--rm`, `--init`, `--stop-timeout=10`
- **AND** the command SHALL include `--network=tillandsias-enclave`

#### Scenario: Proxy container launch
- **WHEN** the proxy container is launched
- **THEN** it SHALL include all non-negotiable security flags
- **AND** it SHALL include `--network=tillandsias-enclave,bridge` for dual-homed access

#### Scenario: Attempting to weaken security
- **WHEN** a profile or config attempts to override security flags
- **THEN** the hardcoded flags SHALL take precedence and the override SHALL be ignored

### Requirement: Volume mount strategy
Containers SHALL mount project directories, cache directories, and secrets directories as volumes with appropriate permissions. The proxy container SHALL additionally mount a persistent cache volume for squid's disk cache.

@trace spec:podman-orchestration

#### Scenario: Default mounts
- **WHEN** a forge container is launched
- **THEN** the project directory SHALL be mounted at `/home/forge/src/<project-name>:rw`
- **AND** the cache directory SHALL be mounted at `/home/forge/.cache/tillandsias:rw`
- **AND** the gh config SHALL be mounted at `/home/forge/.config/gh:ro`
- **AND** the git config SHALL be mounted at `/home/forge/.config/tillandsias-git:rw`

#### Scenario: Proxy cache mount
- **WHEN** the proxy container is launched
- **THEN** the proxy cache directory SHALL be mounted at `/var/spool/squid:rw`
- **AND** the host path SHALL be `~/.cache/tillandsias/proxy-cache/`

#### Scenario: Custom mounts
- **WHEN** a project config defines additional mounts
- **THEN** they SHALL be appended after the profile mounts

#### Scenario: Shared Nix cache
- **WHEN** the nix builder toolbox is used
- **THEN** the nix store cache SHALL be mounted at the nix store location inside the container

#### Scenario: SELinux relabeling not required
- **WHEN** containers run with `--userns=keep-id`
- **THEN** SELinux relabeling (`:Z` suffix) SHALL NOT be used because `--security-opt=label=disable` is already applied
