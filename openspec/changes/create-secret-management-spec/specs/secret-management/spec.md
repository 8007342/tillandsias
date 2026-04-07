# secret-management Specification

## Purpose

Credential delivery pipeline for Tillandsias containers. Defines how GitHub tokens and git identity move from the host OS keyring into containers via D-Bus forwarding, hosts.yml bind mounts, tmpfs token files, and the git-askpass mechanism. Enforces the zero-credential security boundary: forge and terminal containers have ZERO credentials; only the git service container holds credentials, accessed via D-Bus from the enclave network.

## Requirements

### Requirement: Zero-credential boundary for forge and terminal containers

Forge containers (opencode, claude) and terminal containers SHALL have zero credentials mounted. No GitHub tokens, no hosts.yml, no API keys, no secret bind mounts. Code arrives from the git mirror service; packages arrive through the proxy. Git push operations go through the enclave-internal git service, which authenticates on behalf of the forge.

@trace spec:secret-management

#### Scenario: Forge container launched without credentials
- **WHEN** a forge container (opencode or claude) is launched
- **THEN** the container profile SHALL have an empty `secrets` list
- **AND** `token_file_path` SHALL be `None` in the launch context
- **AND** the accountability log SHALL record `credential-free (no token, no hosts.yml)`

#### Scenario: Terminal container launched without credentials
- **WHEN** a terminal or root terminal container is launched
- **THEN** the container profile SHALL have an empty `secrets` list
- **AND** no GitHub token or hosts.yml SHALL be bind-mounted

#### Scenario: Git service container holds credentials
- **WHEN** a git service container is launched
- **THEN** its profile SHALL include `SecretKind::DbusSession` for keyring access
- **AND** its profile SHALL include `SecretKind::GitHubToken` as a fallback
- **AND** these are the ONLY containers with credential access

### Requirement: D-Bus session bus forwarding for keyring access

The system SHALL forward the host D-Bus session bus socket into containers that need keyring access (git service, authentication containers). The socket SHALL be bind-mounted read-only. The `DBUS_SESSION_BUS_ADDRESS` environment variable SHALL be forwarded so that `gh` and `secret-tool` can reach the host's secret service.

@trace spec:secret-management

#### Scenario: D-Bus socket available
- **WHEN** `DBUS_SESSION_BUS_ADDRESS` is set and the socket file exists
- **THEN** the socket SHALL be mounted at its original path inside the container (`:ro`)
- **AND** `DBUS_SESSION_BUS_ADDRESS` SHALL be set to the same value inside the container
- **AND** `--userns=keep-id` SHALL ensure UID matches for D-Bus authentication

#### Scenario: D-Bus socket unavailable
- **WHEN** `DBUS_SESSION_BUS_ADDRESS` is not set or the socket does not exist
- **THEN** the D-Bus mount SHALL be skipped silently
- **AND** the system SHALL fall back to the hosts.yml plaintext token path
- **AND** a warning SHALL be logged noting the plaintext fallback

### Requirement: hosts.yml bind mount for gh CLI credentials

The system SHALL maintain a `hosts.yml` file at `~/.cache/tillandsias/secrets/gh/hosts.yml` containing GitHub authentication metadata (protocol, username) and optionally the OAuth token. This file SHALL be bind-mounted into containers that need `gh` CLI access at `/home/forge/.config/gh/`.

@trace spec:secret-management

#### Scenario: hosts.yml written from keyring before launch
- **WHEN** a container that needs GitHub credentials is about to launch
- **THEN** `secrets::write_hosts_yml_from_keyring()` SHALL refresh the file from the OS keyring
- **AND** the file SHALL be overwritten (not appended) on every launch

#### Scenario: Keyring unavailable, existing hosts.yml present
- **WHEN** the keyring is unavailable but `hosts.yml` exists on disk
- **THEN** the existing file SHALL be used as-is
- **AND** a warning SHALL be logged

#### Scenario: No credentials available
- **WHEN** neither the keyring nor `hosts.yml` contains a token
- **THEN** the container SHALL launch without GitHub credentials
- **AND** `gh` CLI operations inside the container will prompt for authentication

### Requirement: Token file infrastructure on tmpfs

The system SHALL write GitHub tokens to tmpfs-backed files for secure injection into containers via bind mount. Token files SHALL never touch persistent storage.

@trace spec:secret-management

#### Scenario: Token file written before container launch
- **WHEN** a container with `SecretKind::GitHubToken` is about to launch and a token exists
- **THEN** the token SHALL be written to `$XDG_RUNTIME_DIR/tillandsias/tokens/<container-name>/github_token`
- **AND** the directory SHALL have mode `0700`, the file SHALL have mode `0600`
- **AND** the write SHALL be atomic (write to `.tmp`, rename to final path)

#### Scenario: Token file bind-mounted read-only
- **WHEN** a container's profile includes `SecretKind::GitHubToken` and a token file exists
- **THEN** the file SHALL be mounted at `/run/secrets/github_token:ro`
- **AND** `GIT_ASKPASS` SHALL be set to `/usr/local/bin/git-askpass-tillandsias.sh`

#### Scenario: Token file deleted on container stop
- **WHEN** a container stops
- **THEN** its token file and directory SHALL be deleted from tmpfs
- **AND** an accountability log entry SHALL record the revocation

#### Scenario: All token files cleaned on app exit
- **WHEN** the Tillandsias application exits (including panic via Drop guard)
- **THEN** the entire `$XDG_RUNTIME_DIR/tillandsias/tokens/` tree SHALL be removed

### Requirement: git-askpass credential mechanism

The forge image SHALL include a `git-askpass-tillandsias.sh` script at `/usr/local/bin/` that reads the token from `/run/secrets/github_token` and returns it as the password when git requests credentials. The `GIT_ASKPASS` environment variable SHALL point to this script in containers with `SecretKind::GitHubToken`.

@trace spec:secret-management

#### Scenario: git push uses askpass
- **WHEN** a git push is executed inside a container with `GIT_ASKPASS` set
- **THEN** git SHALL call the askpass script
- **AND** the script SHALL return `x-access-token` as username and the token file contents as password

#### Scenario: Token file missing at askpass time
- **WHEN** the askpass script is called but `/run/secrets/github_token` does not exist
- **THEN** the script SHALL return an empty password
- **AND** the git operation SHALL fail with an authentication error (expected behavior)

### Requirement: gh auth setup-git bridge in container entrypoints

All forge and terminal container entrypoints SHALL run `gh auth setup-git` via `lib-common.sh` to register `gh` as the git credential helper. This enables git operations to use the `gh` CLI's token transparently. The command SHALL run non-interactively and fail silently if `gh` is not installed.

@trace spec:secret-management

#### Scenario: gh available in container
- **WHEN** a container starts and `gh` is installed in the image
- **THEN** `gh auth setup-git` SHALL be executed during entrypoint initialization
- **AND** git credential.helper SHALL be configured to use `gh`

#### Scenario: gh not available in container
- **WHEN** a container starts and `gh` is not installed
- **THEN** the `gh auth setup-git` step SHALL be skipped silently
- **AND** git SHALL fall back to `GIT_ASKPASS` if configured

### Requirement: Authentication flow with prioritized strategies

The `gh-auth-login.sh` script SHALL authenticate with GitHub using three strategies in priority order: (1) host-native `gh` CLI storing tokens directly in the OS keyring, (2) forge container with D-Bus forwarding storing tokens in the host keyring via the socket, (3) forge container with plaintext `hosts.yml` fallback when D-Bus is unavailable.

@trace spec:secret-management

#### Scenario: Strategy 1 — host gh CLI available
- **WHEN** `gh` is found on the host system
- **THEN** `gh auth login --git-protocol https` SHALL run directly on the host
- **AND** the token SHALL be stored in the OS native keyring by `gh` (v2.40+ default)
- **AND** `gh auth setup-git` SHALL configure the git credential helper

#### Scenario: Strategy 2 — forge container with D-Bus
- **WHEN** `gh` is not on the host but D-Bus is available
- **THEN** a temporary forge container SHALL be started with the D-Bus socket mounted
- **AND** `gh auth login` SHALL run inside the container
- **AND** the token SHALL be stored in the host's OS keyring via D-Bus

#### Scenario: Strategy 3 — forge container plaintext fallback
- **WHEN** neither host `gh` nor D-Bus is available
- **THEN** a temporary forge container SHALL be started with `hosts.yml` bind-mounted read-write
- **AND** `gh auth login` SHALL run inside the container
- **AND** the token SHALL be written to `hosts.yml` as plaintext
- **AND** `--log-secret-management` SHALL trace the plaintext storage prominently

### Requirement: Secrets directory structure

The system SHALL maintain a secrets directory at `~/.cache/tillandsias/secrets/` with subdirectories `gh/` (GitHub CLI metadata and hosts.yml) and `git/` (`.gitconfig` with user identity). These directories SHALL be created at launch time by `ensure_secrets_dirs()`. The `.gitconfig` file SHALL contain only `user.name` and `user.email` — no tokens.

@trace spec:secret-management

#### Scenario: First launch creates secrets directories
- **WHEN** the application launches and `~/.cache/tillandsias/secrets/` does not exist
- **THEN** the system SHALL create `secrets/gh/` and `secrets/git/` directories
- **AND** an empty `.gitconfig` file SHALL be created in `secrets/git/`

#### Scenario: Git identity persists across sessions
- **WHEN** a user provides their name and email during GitHub Login
- **THEN** the identity SHALL be written to `~/.cache/tillandsias/secrets/git/.gitconfig`
- **AND** subsequent container launches SHALL read this identity and inject it as `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` environment variables

### Requirement: Accountability logging for credential lifecycle

All credential operations SHALL be logged to the `--log-secret-management` accountability window. Log entries SHALL include the `category = "secrets"` field and reference `spec:secret-management` or the appropriate sub-spec. No token values or credentials SHALL appear in log output.

@trace spec:secret-management

#### Scenario: Credential-free launch logged
- **WHEN** a forge or terminal container is launched
- **THEN** an accountability log entry SHALL record `credential-free (no token, no hosts.yml)` with the container name

#### Scenario: Token injection logged
- **WHEN** a token file is written for a git service container
- **THEN** an accountability log entry SHALL record the tmpfs path and `ro mount` status

#### Scenario: Token revocation logged
- **WHEN** a token file is deleted on container stop or app exit
- **THEN** an accountability log entry SHALL record the revocation event with the container name

### Requirement: AppImage environment sanitization

The authentication script SHALL unset `LD_LIBRARY_PATH` and `LD_PRELOAD` before invoking podman. These variables are set by AppImage extraction and break podman's ability to launch containers.

@trace spec:secret-management

#### Scenario: Running from AppImage
- **WHEN** `gh-auth-login.sh` is invoked from an AppImage-extracted environment
- **THEN** `LD_LIBRARY_PATH` and `LD_PRELOAD` SHALL be unset before any podman command
- **AND** podman SHALL function correctly with the system's native libraries
