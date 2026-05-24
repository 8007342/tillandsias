<!-- @trace spec:secrets-management -->
# secrets-management Specification

## Status

superseded (Phase 6 — see `tillandsias-vault` spec)

Phase 6 promoted the in-enclave HashiCorp Vault container to be the default
Linux secrets backend. The OS-native-keyring path described below is retained
for one release behind the deprecated `--legacy-keyring-secrets` flag and
will be removed in v0.3. New work should follow
`openspec/specs/tillandsias-vault/spec.md`.

## Purpose

Credential handling for Tillandsias. The host Rust process is the only process
that talks to the OS native keyring. GitHub credentials are stored in the host
keyring, converted into a podman secret for the git service container, and
never exposed to forge or terminal containers. Git identity is cached locally
as non-secret metadata.

## Requirements

### Requirement: Native keyring owns the GitHub token

The host SHALL store and retrieve the GitHub OAuth token through the OS native
keyring only. No container, entrypoint, or shell helper SHALL call the keyring
directly.

#### Scenario: GitHub Login stores token
- **WHEN** the user completes `--github-login`
- **THEN** the host SHALL capture the token with `gh auth token` inside an
  ephemeral git-image container
- **AND** SHALL store the token in the native keyring
- **AND** SHALL tear the container down after capture

#### Scenario: No keyring access in containers
- **WHEN** a container is running
- **THEN** it SHALL NOT receive D-Bus, Secret Service, Keychain, or Credential Manager access

### Requirement: GitHub token is delivered as a podman secret

The host SHALL create the `tillandsias-github-token` podman secret from the
keyring token when the git service needs it. The git service SHALL read the
token from `/run/secrets/tillandsias-github-token`. No bind-mounted token file
or `GIT_ASKPASS` helper SHALL be used.

#### Scenario: Git service receives podman secret
- **WHEN** the git service container starts and a token exists in the keyring
- **THEN** the host SHALL create `tillandsias-github-token`
- **AND** SHALL launch the container with `--secret=tillandsias-github-token`
- **AND** the container SHALL read `/run/secrets/tillandsias-github-token`

#### Scenario: No token available
- **WHEN** the keyring has no GitHub token
- **THEN** the git service container SHALL launch without the secret
- **AND** authenticated pushes SHALL fail until the user runs GitHub Login

### Requirement: Git identity is cached as local metadata

The host SHALL persist git author name and email in `~/.cache/tillandsias/secrets/git/.gitconfig`.
This file contains only identity metadata. It SHALL NOT contain tokens.

#### Scenario: Identity is reused
- **WHEN** the user launches another container after saving git identity
- **THEN** the launcher SHALL inject `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
  `GIT_COMMITTER_NAME`, and `GIT_COMMITTER_EMAIL`

### Requirement: Secrets lifecycle is logged and cleaned up

The system SHALL log secret creation and cleanup events without revealing the
token value. The podman secret SHALL be removed during tray shutdown.

#### Scenario: Secret cleanup on shutdown
- **WHEN** the tray exits
- **THEN** it SHALL remove `tillandsias-github-token` if present

#### Scenario: No secret values in logs
- **WHEN** any secret operation is logged
- **THEN** the log SHALL include the operation name and secret name only
- **AND** SHALL NOT include the token value

## Sources of Truth

- `openspec/specs/native-secrets-store/spec.md`
- `openspec/specs/podman-secrets-integration/spec.md`
- `openspec/specs/git-mirror-service/spec.md`
