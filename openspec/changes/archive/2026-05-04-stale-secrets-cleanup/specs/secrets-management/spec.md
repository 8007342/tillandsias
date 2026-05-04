# Secrets Management (Delta Spec)

## MODIFIED Requirements

### Requirement: Secrets are refreshed on tray startup
The system SHALL make secret creation idempotent by checking for existing secrets, removing stale ones, and creating fresh copies. On each tray startup, CA secrets (tillandsias-ca-root, tillandsias-ca-cert, tillandsias-ca-key) are checked for existence. If found, they are removed and recreated with current certificate material.

#### Scenario: Stale secrets from unclean shutdown are refreshed
- **WHEN** tray starts after an unclean shutdown (no cleanup_all() call)
- **THEN** existing tillandsias-ca-* secrets are detected
- **AND** stale secrets are removed via podman secret rm
- **AND** fresh secrets are created with current ephemeral CA material
- **AND** containers launched immediately afterward receive up-to-date certificates

#### Scenario: Idempotent behavior on repeated startups
- **WHEN** tray is started, stopped cleanly (cleanup_all succeeds), and started again
- **THEN** secret creation succeeds without "secret name in use" errors
- **AND** no accumulation of stale secrets

#### Scenario: Secrets remain ephemeral
- **WHEN** tray is running and CA certificates are injected into containers
- **THEN** secrets are stored in podman's backend (tmpfs on Linux, secure system keyring on others)
- **AND** secrets are NOT persisted to disk or accessible via host filesystem
- **AND** secrets are cleaned up on tray shutdown via cleanup_all()
