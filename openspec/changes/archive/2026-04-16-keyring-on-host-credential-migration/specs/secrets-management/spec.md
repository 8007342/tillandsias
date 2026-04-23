## MODIFIED Requirements

### Requirement: Token file infrastructure on tmpfs

The system SHALL write GitHub tokens to tmpfs-backed files for secure injection into containers via bind mount. Token files SHALL never persist beyond the consuming container's lifetime. The host process is the sole writer; no container ever writes to this path.

#### Scenario: Token file written before container launch
- **WHEN** a container with `SecretKind::GitHubToken` is about to launch and a token exists in the OS keyring
- **THEN** the token SHALL be read from the keyring in the host Rust process via `secrets::retrieve_github_token()`
- **AND** written atomically to `<runtime-root>/tillandsias-tokens/<container-name>/github_token` where `<runtime-root>` is `$XDG_RUNTIME_DIR` on Linux, `$TMPDIR` on macOS, or `%LOCALAPPDATA%\Temp` on Windows
- **AND** the parent directory SHALL have mode `0700` on Unix; NTFS per-user ACL inheritance on Windows
- **AND** the file SHALL have mode `0600` on Unix; NTFS per-user ACL inheritance on Windows
- **AND** the write SHALL be atomic (write to `<path>.tmp`, rename to final path)

#### Scenario: Token file bind-mounted read-only
- **WHEN** a container's profile includes `SecretKind::GitHubToken` and `LaunchContext.token_file_path` is `Some(path)`
- **THEN** the file SHALL be mounted at `/run/secrets/github_token:ro`
- **AND** `GIT_ASKPASS` SHALL be set to `/usr/local/bin/git-askpass-tillandsias.sh`

#### Scenario: Token file deleted on container stop
- **WHEN** `handlers::stop_git_service` completes
- **THEN** `secrets::cleanup_token_file(container_name)` SHALL unlink the file and its parent directory
- **AND** errors other than `NotFound` SHALL be logged as warnings

#### Scenario: All token files swept on app startup
- **WHEN** the Tillandsias tray starts
- **THEN** `secrets::cleanup_all_token_files()` SHALL recursively remove the entire tokens-root directory tree before any container work begins
- **AND** an accountability log entry SHALL record the sweep regardless of whether any files were present

### Requirement: git-askpass credential mechanism

The git image SHALL include `/usr/local/bin/git-askpass-tillandsias.sh` that reads the token from `/run/secrets/github_token` and returns it as the password when git requests credentials. The `GIT_ASKPASS` environment variable SHALL point to this script in containers with `SecretKind::GitHubToken`.

#### Scenario: git push uses askpass
- **WHEN** a git push is executed inside a container with `GIT_ASKPASS` set
- **THEN** git SHALL call the askpass script with a prompt argument
- **AND** for prompts matching `Username*` the script SHALL return `x-access-token`
- **AND** for prompts matching `Password*` the script SHALL return the contents of `/run/secrets/github_token` verbatim

#### Scenario: Token file missing at askpass time
- **WHEN** the askpass script is invoked and `/run/secrets/github_token` does not exist or is unreadable
- **THEN** the script SHALL print a clear error to stderr and exit non-zero
- **AND** the git operation SHALL fail with an authentication error (expected behavior — loud-fail, not silent empty password)

### Requirement: Authentication flow

The `--github-login` flow SHALL authenticate with GitHub using a single strategy: an ephemeral git-service container runs `gh auth login` interactively; the host extracts the token via `gh auth token` executed inside the same container; the host stores the token in the OS keyring via `secrets::store_github_token`; the container is destroyed via a `Drop`-guarded `podman rm -f` on every exit path.

#### Scenario: Strategy — ephemeral container
- **WHEN** the user runs `tillandsias --github-login` or clicks tray > Settings > GitHub Login
- **THEN** a fresh `tillandsias-gh-login` container SHALL be started from the git service image with `podman run -d --init --cap-drop=ALL --security-opt=no-new-privileges --userns=keep-id --security-opt=label=disable --entrypoint=sleep ... infinity`
- **AND** `gh auth login --git-protocol https` SHALL run interactively inside it via `podman exec -it`
- **AND** on success, `gh auth token` SHALL run inside the same container to extract the token
- **AND** the token SHALL be persisted via `secrets::store_github_token()` (keyring write)
- **AND** the container SHALL be removed via `podman rm -f` on every exit path (Drop guard)

#### Scenario: Keyring unavailable
- **WHEN** the keyring crate returns `Err` during `store_github_token` or `retrieve_github_token`
- **THEN** the authentication flow SHALL abort with a user-facing error
- **AND** no token SHALL be written to disk
- **AND** `--log-secrets-management` SHALL record the abort reason

### Requirement: Accountability logging

All credential operations SHALL be logged to the `--log-secrets-management` accountability window. Log entries SHALL include the `category = "secrets"` field and reference `spec:secrets-management` or `spec:native-secrets-store`. No token values SHALL appear in log output — neither in message bodies nor in structured fields.

#### Scenario: Token stored event
- **WHEN** `secrets::store_github_token` succeeds
- **THEN** an accountability log entry SHALL record "GitHub token stored in native keyring" with the `safety` field "Token stored in OS keyring, not written to disk"
- **AND** the log SHALL NOT contain the token value

#### Scenario: Token retrieved event
- **WHEN** `secrets::retrieve_github_token` returns `Ok(Some(_))`
- **THEN** an accountability log entry SHALL record "GitHub token retrieved from OS keyring" with the `safety` field "Retrieved from OS keyring in-process, never written to disk"

#### Scenario: Token file materialized event
- **WHEN** `secrets::prepare_token_file` succeeds
- **THEN** an accountability log entry SHALL record the container name and tmpfs path with the `safety` field "Token written to ephemeral per-container file for :ro bind-mount; unlinked on container stop"

#### Scenario: Orphan sweep event
- **WHEN** `handlers::sweep_orphan_containers` finds one or more `tillandsias-*` containers at startup
- **THEN** an accountability log entry SHALL record the `orphan_count`
- **AND** each orphan's stop + force-remove + token-file cleanup SHALL be attempted
- **AND** stop failures SHALL be logged at `debug` level (often the container has already exited)

## ADDED Requirements

### Requirement: Startup crash-recovery sweep

The tray SHALL unconditionally sweep orphan `tillandsias-*` containers and dangling token files on startup, before any new container is launched. This recovers from `TerminateProcess` / `SIGKILL` / crash scenarios where Rust `Drop` guards did not run.

#### Scenario: Clean prior exit
- **WHEN** the prior session exited cleanly (`EnclaveCleanupGuard` Drop ran)
- **THEN** `sweep_orphan_containers` SHALL find no running containers and be a no-op
- **AND** `cleanup_all_token_files` SHALL find the tokens-root absent and return silently

#### Scenario: Crashed prior session with orphans
- **WHEN** the prior session was killed (TerminateProcess / SIGKILL) and left `tillandsias-*` containers running
- **THEN** `sweep_orphan_containers` SHALL stop each via `ContainerLauncher::stop`, follow with `podman rm -f` (belt-and-suspenders for non-`--rm` containers), call `secrets::cleanup_token_file` per name, and then call `cleanup_enclave_network`
- **AND** `cleanup_all_token_files` SHALL recursively remove the entire tokens-root tree

## REMOVED Requirements

### Requirement: D-Bus session bus forwarding for keyring access

**Reason**: The host D-Bus session bus mount exposed the entire host keyring (browser passwords, SSH passphrases, WiFi PSKs) to any container that could `dbus-send`. Secret Service has no per-caller ACL, so the scope was "every unlocked collection" — disproportionate to the one credential the container actually needed. Additionally, Windows and macOS have no D-Bus on the host, so this requirement was dead on two out of three target platforms, with silent-fallback paths that claimed success without persisting anything.

**Migration**: Replaced by the combined keyring-on-host (see `native-secrets-store`) and ephemeral tmpfs token file (see "Token file infrastructure on tmpfs" above). The host reads the OS keyring in-process via the `keyring` crate; containers receive only a single `:ro` bind-mounted file containing the raw token bytes. No D-Bus socket crosses the enclave boundary on any platform.

### Requirement: hosts.yml migration and fallback

**Reason**: Half-removed architecture. References to `hosts.yml` ("fallback", "deprecated", "legacy migration") created false alternatives that masked real keyring failures and appeared throughout code/specs/docs as a ghost of a previous design.

**Migration**: All `hosts.yml` mentions purged from live code, specs, shell scripts, and docs. Archive-only historical record remains under `openspec/changes/archive/**`. Credentials flow exclusively through the OS keyring on the host.
