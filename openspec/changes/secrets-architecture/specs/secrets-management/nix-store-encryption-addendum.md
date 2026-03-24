## ADDED Requirements

### Requirement: Nix store integrity for image builds
The Nix store used by the tillandsias-builder toolbox SHALL be protected against tampering at rest.

#### Scenario: Builder toolbox Nix store isolation
- **WHEN** the tillandsias-builder toolbox builds a container image via `nix build`
- **THEN** the Nix store used is inside the builder toolbox, not shared with the host or other toolboxes

#### Scenario: Encrypted Nix store at rest (Phase 2)
- **GIVEN** tillandsias has migrated to Phase 2 encrypted storage
- **WHEN** the builder toolbox is not actively building
- **THEN** the Nix store at `~/.nix` or the builder toolbox's `/nix/store` is encrypted at rest
- **AND** it is only decrypted during active build operations

#### Scenario: Nix content-addressed verification
- **WHEN** `nix build` runs to produce a container image
- **THEN** Nix's content-addressed store verifies all inputs match their expected hashes
- **AND** any tampered store path causes the build to fail with a hash mismatch

### Requirement: Build artifact chain of trust
Container images built by Tillandsias SHALL have a verifiable chain from source to image.

#### Scenario: Source integrity via embedded scripts (Phase 1)
- **GIVEN** the `embed-scripts-in-binary` change is implemented
- **WHEN** the binary builds a container image
- **THEN** the image sources (flake.nix, entrypoint, configs) come from the signed binary, not from userspace files

#### Scenario: Image hash verification
- **WHEN** a container image is built and loaded into podman
- **THEN** the image hash is recorded
- **AND** subsequent runs verify the image hash hasn't changed since build

### Requirement: Encrypted secrets cache at rest (Phase 2)
The entire secrets cache directory SHALL be encrypted at rest using the system keyring for key management.

#### Scenario: Secrets encrypted when not in use
- **GIVEN** no forge container is running
- **WHEN** the host filesystem is inspected
- **THEN** `~/.cache/tillandsias/secrets/` is an encrypted volume (gocryptfs or LUKS)
- **AND** the encryption key is stored in the system keyring (GNOME Keyring, macOS Keychain, Windows Credential Manager)

#### Scenario: Transparent unlock on first container start
- **WHEN** the first forge container starts in a session
- **THEN** the secrets volume is unlocked via the system keyring (no password prompt if already unlocked by session login)
- **AND** secrets are available to mount into containers

#### Scenario: Lock on last container stop
- **WHEN** the last forge container stops
- **THEN** the secrets volume is locked (unmounted/encrypted)
