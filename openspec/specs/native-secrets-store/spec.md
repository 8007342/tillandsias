# native-secrets-store Specification

## Purpose

Store the GitHub OAuth token in the host OS's native secret service (GNOME Keyring, macOS Keychain, Windows Credential Manager) instead of relying on the plain text `~/.cache/tillandsias/secrets/gh/hosts.yml` file.

## Requirements

### Requirement: Store GitHub token in native keyring

The application SHALL store the GitHub OAuth token in the OS native secret service under service name `tillandsias` with key `github-oauth-token`.

#### Scenario: Token stored after authentication
- **WHEN** `gh auth login` completes successfully via the GitHub Login flow
- **THEN** the OAuth token is read from `hosts.yml` and stored in the native keyring

#### Scenario: Keyring unavailable
- **WHEN** the native keyring is not available (no D-Bus, headless, locked)
- **THEN** the application logs a warning and falls back to reading `hosts.yml` directly
- **AND** no error is shown to the user

### Requirement: Retrieve token for container launch

The application SHALL retrieve the GitHub token from the native keyring and write a `hosts.yml` file before launching any container that needs GitHub credentials.

#### Scenario: Token available in keyring
- **WHEN** a container launch is requested and a token exists in the keyring
- **THEN** the token is written to `~/.cache/tillandsias/secrets/gh/hosts.yml` before `podman run`

#### Scenario: Token not in keyring, hosts.yml exists
- **WHEN** a container launch is requested and the keyring has no token but `hosts.yml` exists
- **THEN** the existing `hosts.yml` is used as-is (fallback behavior)

#### Scenario: No token anywhere
- **WHEN** a container launch is requested and neither the keyring nor `hosts.yml` has a token
- **THEN** the container launches without GitHub credentials (gh CLI will prompt if needed)

### Requirement: Auto-migrate existing tokens

The application SHALL automatically migrate an existing plain text token from `hosts.yml` into the native keyring on first run after this change.

#### Scenario: First run with existing credentials
- **WHEN** the application starts and `hosts.yml` contains a token but the keyring entry is empty
- **THEN** the token is stored in the keyring silently

#### Scenario: First run without existing credentials
- **WHEN** the application starts and no `hosts.yml` exists
- **THEN** no migration occurs and no error is raised

#### Scenario: Keyring already has token
- **WHEN** the application starts and both `hosts.yml` and keyring have tokens
- **THEN** no migration occurs (keyring takes precedence)
