## MODIFIED Requirements

### Requirement: Security-hardened container defaults
Every Tillandsias-managed container SHALL have non-negotiable security flags. Forge containers SHALL additionally have zero credential mounts and enclave-only networking. The volume mount strategy for forge SHALL include only the cache directory (no project dir, no secrets dirs).

@trace spec:podman-orchestration, spec:forge-offline

#### Scenario: Forge container security posture
- **WHEN** a forge container is launched
- **THEN** it SHALL have `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`
- **AND** `--network=tillandsias-enclave` (no bridge)
- **AND** no `-v` mounts for tokens, gh config, git config, or project directory
- **AND** only cache mount and custom mounts (if configured)

### Requirement: Volume mount strategy
Forge containers SHALL mount only the cache directory. Project code comes from git clone. Secrets come from nowhere (forge has none). Git identity comes from environment variables.

@trace spec:podman-orchestration, spec:forge-offline

#### Scenario: Forge mounts (Phase 3)
- **WHEN** a forge container is launched
- **THEN** the only profile mount SHALL be the cache directory at `/home/forge/.cache/tillandsias:rw`
- **AND** no project directory mount SHALL be present
- **AND** no gh config or git config mounts SHALL be present
