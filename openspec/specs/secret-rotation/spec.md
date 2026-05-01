<!-- @trace spec:secret-rotation -->
## ADDED Requirements

### Requirement: Token files on tmpfs
GitHub tokens SHALL be stored on tmpfs (RAM-backed filesystem), never on persistent storage.

#### Scenario: Token file written to XDG_RUNTIME_DIR
- **GIVEN** `$XDG_RUNTIME_DIR` is set and writable (Linux with systemd)
- **WHEN** a container is about to be launched
- **THEN** the OAuth token is written to `$XDG_RUNTIME_DIR/tillandsias/tokens/<container-name>/github_token`
- **AND** the directory has mode 0700
- **AND** the file has mode 0600
- **AND** the write is atomic (write to `.tmp`, rename to final path)

#### Scenario: Fallback to TMPDIR
- **GIVEN** `$XDG_RUNTIME_DIR` is not set or not writable
- **WHEN** a container is about to be launched
- **THEN** the token is written to `$TMPDIR/tillandsias/tokens/<container-name>/github_token`
- **AND** a warning is logged: "XDG_RUNTIME_DIR unavailable, using TMPDIR for token storage"

#### Scenario: No writable tmpfs available
- **GIVEN** neither `$XDG_RUNTIME_DIR` nor `$TMPDIR` is writable
- **WHEN** a container is about to be launched
- **THEN** the launch SHALL abort with a user-facing error
- **AND** no token SHALL be written to persistent storage

### Requirement: GIT_ASKPASS credential delivery
Containers SHALL use a GIT_ASKPASS helper script for git authentication via the mounted token file.

#### Scenario: Git push uses GIT_ASKPASS with token file
- **WHEN** a user runs `git push origin main` inside a forge container
- **THEN** git invokes the `GIT_ASKPASS` script at `/usr/local/bin/git-askpass-tillandsias`
- **AND** the script returns username `x-access-token`
- **AND** the script reads the password from `/run/secrets/github_token`
- **AND** the push succeeds

#### Scenario: GIT_ASKPASS script is immutable
- **WHEN** any process inside the container attempts to modify `/usr/local/bin/git-askpass-tillandsias`
- **THEN** the write fails (script is baked into the image, owned by root, mode 0755)

#### Scenario: Token file not present
- **GIVEN** the token file mount is absent (e.g., no GitHub credentials configured)
- **WHEN** git invokes the GIT_ASKPASS script
- **THEN** the script returns an empty password
- **AND** git prompts for credentials interactively (or fails in non-interactive mode)

### Requirement: Token not in process environment
Tokens SHALL NOT be passed as environment variables visible in `/proc/*/environ`.

#### Scenario: Token absent from container environment
- **WHEN** a forge container is running
- **THEN** no environment variable contains the GitHub OAuth token
- **AND** `cat /proc/1/environ | tr '\0' '\n' | grep -i token` returns no GitHub token
- **AND** the token is only accessible via the file at `/run/secrets/github_token`

### Requirement: Token file mount in containers
Container launch SHALL include a read-only mount of the token file at `/run/secrets/github_token`.

#### Scenario: Forge container has token mount
- **WHEN** a forge container (OpenCode or Claude) is launched
- **THEN** the container has `-v <tmpfs_path>:/run/secrets/github_token:ro` in its mount list
- **AND** the container has `-e GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias` in its environment
- **AND** the token file at `/run/secrets/github_token` inside the container is readable

#### Scenario: Terminal container has token mount
- **WHEN** a maintenance terminal container is launched
- **THEN** the container has the same token file mount and GIT_ASKPASS env var

#### Scenario: Web container has NO token mount
- **WHEN** a web container is launched
- **THEN** the container does NOT have a token file mount
- **AND** the container does NOT have a GIT_ASKPASS env var
- **AND** no GitHub credentials are accessible inside the web container

### Requirement: Token cleanup on container stop
Token files SHALL be deleted immediately when the associated container stops.

#### Scenario: Token deleted on container stop
- **WHEN** a container stops (exit, user stop, or destroy)
- **THEN** the token file at `<base>/<container-name>/github_token` is deleted
- **AND** the container-specific directory `<base>/<container-name>/` is removed
- **AND** the deletion is logged to the accountability window

#### Scenario: Token deleted on app exit
- **WHEN** the Tillandsias application exits (graceful shutdown)
- **THEN** the entire `<base>/` directory tree is removed (all container token files)
- **AND** the count of deleted files is logged

#### Scenario: Token cleaned up on panic
- **WHEN** the Tillandsias application panics
- **THEN** the `TokenCleanupGuard`'s `Drop` implementation removes the token directory tree
- **AND** best-effort cleanup occurs (may not succeed for all files)

#### Scenario: Token survives only until session end
- **GIVEN** the app is killed with SIGKILL (cannot catch)
- **WHEN** the user's session ends or the system reboots
- **THEN** tmpfs is cleared and the token files are gone

### Requirement: Host-side token refresh
A background task SHALL periodically rewrite token files to prepare for future rotation.

#### Scenario: Token refreshed every 55 minutes
- **GIVEN** a container has been running for 55 minutes
- **WHEN** the refresh task fires
- **THEN** the token is re-read from the keyring
- **AND** the token file is atomically rewritten
- **AND** the refresh is logged to the accountability window

#### Scenario: Keyring unavailable during refresh
- **GIVEN** the OS keyring becomes unavailable during a session (e.g., screen lock on some systems)
- **WHEN** the refresh task attempts to read the token
- **THEN** the existing token file is left unchanged
- **AND** a warning is logged: "Keyring unavailable during token refresh, existing token preserved"

### Requirement: Accountability logging for token operations
All token lifecycle events SHALL be logged to the accountability window when `--log-secrets-management` is active.

#### Scenario: Token write logged
- **WHEN** a token file is written
- **THEN** the accountability log shows:
  ```
  [secrets] v0.1.97.76 | Token written for <container> -> /run/secrets/... (tmpfs, ro mount)
    Spec: secret-rotation
    Cheatsheet: docs/cheatsheets/token-rotation.md
  ```

#### Scenario: Token refresh logged
- **WHEN** a token file is refreshed by the 55-minute task
- **THEN** the accountability log shows:
  ```
  [secrets] v0.1.97.76 | Token refreshed for <container> (55min rotation)
    Spec: secret-rotation
    Cheatsheet: docs/cheatsheets/token-rotation.md
  ```

#### Scenario: Token revocation logged
- **WHEN** a token file is deleted on container stop
- **THEN** the accountability log shows:
  ```
  [secrets] v0.1.97.76 | Token revoked for <container> (container stopped)
    Spec: secret-rotation
    Cheatsheet: docs/cheatsheets/token-rotation.md
  ```

#### Scenario: No secrets in accountability output
- **WHEN** any token operation is logged
- **THEN** the actual token value NEVER appears in the log
- **AND** only the operation, target container, and mechanism are shown

## MODIFIED Requirements

### Requirement: Container volume mounts (updated)
Container volume mounts SHALL deliver GitHub credentials exclusively through the tmpfs token file — no directory-level credential mounts.

#### Scenario: Token file is the sole credential mount
- **WHEN** a forge or terminal container is launched with `SecretKind::GitHubToken`
- **THEN** the container has `-v <tmpfs_path>:/run/secrets/github_token:ro`
- **AND** `GIT_ASKPASS` is set so git operations read the tmpfs token file
- **AND** `gh` CLI operations use the same token via `gh auth login --with-token` at entrypoint, or via the credential helper configured by `gh auth setup-git`

### Requirement: Container profile secrets (updated)
The container profile system SHALL support GitHub token as a secret kind.

#### Scenario: Forge profiles declare GitHubToken secret
- **WHEN** `forge_opencode_profile()` or `forge_claude_profile()` is called
- **THEN** the profile's secrets list includes `SecretKind::GitHubToken`

#### Scenario: Terminal profile declares GitHubToken secret
- **WHEN** `terminal_profile()` is called
- **THEN** the profile's secrets list includes `SecretKind::GitHubToken`

#### Scenario: Web profile has NO GitHubToken secret
- **WHEN** `web_profile()` is called
- **THEN** the profile's secrets list does NOT include `SecretKind::GitHubToken`
