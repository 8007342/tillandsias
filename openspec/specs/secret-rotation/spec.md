<!-- @trace spec:secret-rotation -->
## Status

status: active

## Requirements

### Requirement: Token files on tmpfs
- **ID**: secret-rotation.token.tmpfs-storage@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [secret-rotation.invariant.tokens-never-persistent-storage, secret-rotation.invariant.atomic-token-writes]
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
- **ID**: secret-rotation.credential.git-askpass-delivery@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [secret-rotation.invariant.git-askpass-immutable, secret-rotation.invariant.token-via-file-not-env]
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
- **ID**: secret-rotation.token.no-environ-exposure@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [secret-rotation.invariant.token-via-file-not-env, secret-rotation.invariant.environ-no-github-token]
Tokens SHALL NOT be passed as environment variables visible in `/proc/*/environ`.

#### Scenario: Token absent from container environment
- **WHEN** a forge container is running
- **THEN** no environment variable contains the GitHub OAuth token
- **AND** `cat /proc/1/environ | tr '\0' '\n' | grep -i token` returns no GitHub token
- **AND** the token is only accessible via the file at `/run/secrets/github_token`

### Requirement: Token file mount in containers
- **ID**: secret-rotation.container.token-mount-delivery@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [secret-rotation.invariant.token-mount-ro, secret-rotation.invariant.web-container-no-token]
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
- **ID**: secret-rotation.token.cleanup-on-stop@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [secret-rotation.invariant.token-deleted-on-container-stop, secret-rotation.invariant.token-cleanup-guard-drop]
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
- **ID**: secret-rotation.token.periodic-refresh@v1
- **Modality**: SHOULD
- **Measurable**: true
- **Invariants**: [secret-rotation.invariant.refresh-interval-55min, secret-rotation.invariant.keyring-fallback-preserve]
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
- **ID**: secret-rotation.logging.accountability-instrumentation@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [secret-rotation.invariant.token-value-never-logged, secret-rotation.invariant.operations-logged-with-spec-field]
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

### Requirement: Container volume mounts (updated)
- **ID**: secret-rotation.mounts.credential-delivery-via-tmpfs@v2
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [secret-rotation.invariant.token-file-sole-mount, secret-rotation.invariant.git-askpass-configured]
Container volume mounts SHALL deliver GitHub credentials exclusively through the tmpfs token file — no directory-level credential mounts.

#### Scenario: Token file is the sole credential mount
- **WHEN** a forge or terminal container is launched with `SecretKind::GitHubToken`
- **THEN** the container has `-v <tmpfs_path>:/run/secrets/github_token:ro`
- **AND** `GIT_ASKPASS` is set so git operations read the tmpfs token file
- **AND** `gh` CLI operations use the same token via `gh auth login --with-token` at entrypoint, or via the credential helper configured by `gh auth setup-git`

### Requirement: Container profile secrets (updated)
- **ID**: secret-rotation.profile.secrets-declaration@v2
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [secret-rotation.invariant.forge-terminal-have-github-secret, secret-rotation.invariant.web-has-no-github-secret]
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

## Invariants

### Invariant: Tokens are never stored on persistent storage
- **ID**: secret-rotation.invariant.tokens-never-persistent-storage
- **Expression**: `token_write() => tmpfs_only && NOT(/persistent/mnt, /home, /root, /var/lib) && tmpfs_cleared_on_reboot`
- **Measurable**: true

### Invariant: Token writes are atomic
- **ID**: secret-rotation.invariant.atomic-token-writes
- **Expression**: `write_to_tmpfile() THEN rename_to_target() && NOT(partial_reads_possible)`
- **Measurable**: true

### Invariant: GIT_ASKPASS script is immutable
- **ID**: secret-rotation.invariant.git-askpass-immutable
- **Expression**: `/usr/local/bin/git-askpass-tillandsias IS_IN_IMAGE && owned_by_root && mode_0755`
- **Measurable**: true

### Invariant: Token via file, never environment
- **ID**: secret-rotation.invariant.token-via-file-not-env
- **Expression**: `credential_delivery ALWAYS_uses(/run/secrets/github_token) && NEVER(environ, cmdline)`
- **Measurable**: true

### Invariant: /proc/*/environ contains no GitHub token
- **ID**: secret-rotation.invariant.environ-no-github-token
- **Expression**: `cat /proc/*/environ | tr '\\0' '\\n' | grep -i token => empty_result`
- **Measurable**: true

### Invariant: Token mount is read-only
- **ID**: secret-rotation.invariant.token-mount-ro
- **Expression**: `container_mount INCLUDES -v <path>:/run/secrets/github_token:ro`
- **Measurable**: true

### Invariant: Web containers have no token
- **ID**: secret-rotation.invariant.web-container-no-token
- **Expression**: `web_container.mounts NOT_CONTAINS /run/secrets/github_token && NOT_CONTAINS GIT_ASKPASS`
- **Measurable**: true

### Invariant: Token deleted on container stop
- **ID**: secret-rotation.invariant.token-deleted-on-container-stop
- **Expression**: `container_stopped => token_file_deleted && container_directory_removed_from_tmpfs`
- **Measurable**: true

### Invariant: TokenCleanupGuard Drop removes files
- **ID**: secret-rotation.invariant.token-cleanup-guard-drop
- **Expression**: `Drop::drop(TokenCleanupGuard) => best_effort_removal(<base>/...)`
- **Measurable**: true

### Invariant: Token refresh interval is 55 minutes
- **ID**: secret-rotation.invariant.refresh-interval-55min
- **Expression**: `refresh_task.interval == 55m && periodic_token_rewrite()`
- **Measurable**: true

### Invariant: Keyring unavailable, preserve existing token
- **ID**: secret-rotation.invariant.keyring-fallback-preserve
- **Expression**: `keyring_unavailable => existing_token_left_unchanged && warning_logged`
- **Measurable**: true

### Invariant: Token value never in logs
- **ID**: secret-rotation.invariant.token-value-never-logged
- **Expression**: `accountability_log NEVER_CONTAINS(actual_token_value) && CONTAINS(operation, container, mechanism)`
- **Measurable**: true

### Invariant: Operations logged with spec field
- **ID**: secret-rotation.invariant.operations-logged-with-spec-field
- **Expression**: `log_event(token_operation) INCLUDES spec="secret-rotation" && cheatsheet="..."`
- **Measurable**: true

### Invariant: Token file is sole credential mount
- **ID**: secret-rotation.invariant.token-file-sole-mount
- **Expression**: `forge_container.credential_mounts ONLY(/run/secrets/github_token) && NOT(credential_dirs)`
- **Measurable**: true

### Invariant: GIT_ASKPASS is configured
- **ID**: secret-rotation.invariant.git-askpass-configured
- **Expression**: `container.env INCLUDES GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias`
- **Measurable**: true

### Invariant: Forge and terminal have GitHub secret
- **ID**: secret-rotation.invariant.forge-terminal-have-github-secret
- **Expression**: `[forge_opencode_profile(), forge_claude_profile(), terminal_profile()].secrets CONTAINS GitHubToken`
- **Measurable**: true

### Invariant: Web profile has no GitHub secret
- **ID**: secret-rotation.invariant.web-has-no-github-secret
- **Expression**: `web_profile().secrets NOT_CONTAINS GitHubToken`
- **Measurable**: true

## Litmus Tests

The following litmus tests validate secret-rotation requirements:

- `litmus-credential-isolation.yaml` — Validates token files on tmpfs and GIT_ASKPASS delivery (Req: secret-rotation.token.tmpfs-storage@v1, secret-rotation.credential.git-askpass-delivery@v1)
- `litmus-token-file-cleanup.yaml` — Validates token cleanup on container stop (Req: secret-rotation.token.cleanup-on-stop@v1)
- `litmus-no-environ-token.yaml` — Validates token not exposed in /proc/*/environ (Req: secret-rotation.token.no-environ-exposure@v1)
- `litmus-token-mount-isolation.yaml` — Validates token mount and web container isolation (Req: secret-rotation.container.token-mount-delivery@v1)

See `openspec/litmus-bindings.yaml` for full binding definitions.

## Sources of Truth

- `cheatsheets/runtime/unix-socket-ipc.md` — Unix Socket Ipc reference and patterns
- `cheatsheets/security/owasp-top-10-2021.md` — Owasp Top 10 2021 reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:secret-rotation" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
