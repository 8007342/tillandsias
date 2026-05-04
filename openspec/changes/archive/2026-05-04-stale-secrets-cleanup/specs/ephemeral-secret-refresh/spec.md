# Ephemeral Secret Refresh

## Purpose

Tillandsias tray ensures podman secrets (CA certificates, tokens) are refreshed on each startup, preventing "secret name in use" errors from unclean shutdowns.

## Requirements

### Requirement: Stale secrets are automatically refreshed on startup
The system SHALL check for existing podman secrets before creation. If a secret exists from a prior unclean shutdown, it SHALL be removed and recreated with fresh content.

#### Scenario: Clean startup (no stale secrets)
- **WHEN** tray starts with no existing CA secrets
- **THEN** system creates three new secrets: tillandsias-ca-root, tillandsias-ca-cert, tillandsias-ca-key

#### Scenario: Stale secret from unclean shutdown
- **WHEN** tray starts and tillandsias-ca-root already exists in podman
- **THEN** system removes the stale secret
- **AND** creates a fresh tillandsias-ca-root secret with current CA certificate

#### Scenario: Secret refresh is idempotent
- **WHEN** tray is restarted multiple times (clean shutdowns between restarts)
- **THEN** each restart successfully refreshes secrets without error
- **AND** no accumulation of secret artifacts

### Requirement: Secret removal failures are reported and propagate
The system SHALL treat secret removal failures as configuration errors (not ignorable). If podman secret rm fails (e.g., permission denied), startup SHALL fail with a clear error message.

#### Scenario: Permission denied on secret removal
- **WHEN** tray attempts to remove stale secret but lacks permission
- **THEN** system logs error: "Failed to remove podman secret: permission denied"
- **AND** tray startup fails with exit code 1
- **AND** user must manually troubleshoot (e.g., run podman secret rm as correct user)

#### Scenario: Secret removal succeeds (normal case)
- **WHEN** stale secret is removed before creating fresh secret
- **THEN** no error is logged
- **AND** startup proceeds normally

## Sources of Truth

- `cheatsheets/utils/podman-secrets.md` — Podman secrets lifecycle and rootless mode
- `cheatsheets/utils/tillandsias-secrets-architecture.md` — Tillandsias secret naming and usage patterns
