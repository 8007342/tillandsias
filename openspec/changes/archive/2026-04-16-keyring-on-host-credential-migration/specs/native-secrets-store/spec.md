## MODIFIED Requirements

### Requirement: Platform-native keyring backend

The host Rust process SHALL use the `keyring` crate (v3) with all three per-platform backends enabled so writes reach the OS-native vault on every supported platform. The `Cargo.toml` dependency SHALL declare features `sync-secret-service`, `crypto-rust`, `apple-native`, and `windows-native`. Without these features the crate compiles to a no-op mock on macOS and Windows; writes silently succeed against nothing.

#### Scenario: Linux backend
- **WHEN** the binary is built on Linux
- **THEN** `keyring::Entry::new(service, user)` SHALL route to the Secret Service D-Bus API via `dbus-secret-service`
- **AND** the target is stored with attributes `service=<SERVICE>`, `username=<USER>`, `application="rust-keyring"`

#### Scenario: macOS backend
- **WHEN** the binary is built on macOS
- **THEN** `keyring::Entry::new(service, user)` SHALL route to Keychain Services via the `security-framework` crate
- **AND** the Generic Password item SHALL have `kSecAttrService=<SERVICE>` and `kSecAttrAccount=<USER>`

#### Scenario: Windows backend
- **WHEN** the binary is built on Windows
- **THEN** `keyring::Entry::new(service, user)` SHALL route to Credential Manager via `CredWriteW`/`CredReadW`
- **AND** the target name SHALL be `<USER>.<SERVICE>` (literal `{user}.{service}` format in the keyring crate's Windows backend)
- **AND** the credential type SHALL be `CRED_TYPE_GENERIC` with `CRED_PERSIST_ENTERPRISE`

### Requirement: Single hardcoded keyring entry

Tillandsias SHALL use exactly one keyring entry, identified by compile-time constants. The binary SHALL be structurally incapable of reading or writing any other app's entries (the `keyring` crate v3 has no enumeration API; `Entry::new` requires exact `(service, user)` at call time).

#### Scenario: Entry identity is hardcoded
- **WHEN** any code calls into `secrets.rs`
- **THEN** the service and key SHALL come from `const SERVICE: &str = "tillandsias"` and `const GITHUB_TOKEN_KEY: &str = "github-oauth-token"`
- **AND** no dynamic service/key construction SHALL exist anywhere in the binary

#### Scenario: Namespace isolation from other apps
- **GIVEN** the host OS keyring contains entries for other apps (`git:https://github.com`, `gh:github.com`, etc.)
- **WHEN** Tillandsias runs
- **THEN** it SHALL NOT read, modify, or delete any entry other than its own
- **AND** its own entry SHALL NOT collide with any other app's target naming

### Requirement: Host-only API surface

The following functions SHALL exist in `src-tauri/src/secrets.rs` and SHALL run exclusively in the host Rust process. No container ever invokes these APIs or has access to the underlying keyring.

#### Scenario: `store_github_token(token: &str) -> Result<(), String>`
- **WHEN** called with a non-empty token
- **THEN** it SHALL construct `keyring::Entry::new(SERVICE, GITHUB_TOKEN_KEY)` and call `set_password(token)`
- **AND** on success SHALL emit an `info!` event with `accountability=true, category="secrets"` and the `safety` field "Token stored in OS keyring, not written to disk"
- **AND** on failure SHALL return `Err(String)` with a platform-specific error (the caller must refuse to proceed)

#### Scenario: `retrieve_github_token() -> Result<Option<String>, String>`
- **WHEN** called
- **THEN** it SHALL attempt `entry.get_password()`
- **AND** return `Ok(Some(token))` on success, `Ok(None)` for `keyring::Error::NoEntry`, `Err(String)` otherwise

#### Scenario: `delete_github_token() -> Result<(), String>`
- **WHEN** called
- **THEN** it SHALL attempt `entry.delete_credential()`
- **AND** return `Ok(())` on success or `NoEntry` (idempotent), `Err(String)` on other failures

## ADDED Requirements

### Requirement: Ephemeral token file delivery helpers

The host SHALL provide `prepare_token_file(container_name)`, `cleanup_token_file(container_name)`, and `cleanup_all_token_files()` for materializing and reaping the per-container tmpfs bind-mount target. These are the sole mechanism by which the token reaches a container.

#### Scenario: `prepare_token_file` returns None when no token
- **WHEN** the keyring has no token for Tillandsias
- **THEN** `prepare_token_file(container)` SHALL return `Ok(None)` (not `Err`)
- **AND** the caller SHALL construct `LaunchContext.token_file_path = None`, which causes the mount to be skipped at `build_podman_args` time

#### Scenario: `prepare_token_file` atomic write on success
- **WHEN** the keyring has a token
- **THEN** `prepare_token_file(container)` SHALL write `<tokens-root>/<container>/github_token.tmp`, `fsync`, then rename to `github_token`
- **AND** return `Ok(Some(final_path))`

#### Scenario: `cleanup_token_file` is idempotent
- **WHEN** called multiple times for the same container
- **THEN** the first call SHALL unlink the file and its parent dir
- **AND** subsequent calls SHALL return silently (no error on missing path)

#### Scenario: `cleanup_all_token_files` recursive sweep
- **WHEN** called at tray startup or on shutdown
- **THEN** it SHALL `remove_dir_all` the entire tokens-root
- **AND** log an accountability event if the root existed and was removed

### Requirement: Token-bytes hardening in the extraction path

The `gh auth token` extraction in `runner::run_github_login_git_service` SHALL never allow the token bytes to reach a terminal device, a tracing message body, or the host process's own environment.

#### Scenario: Explicit Stdio on extraction
- **WHEN** `podman exec <container> gh auth token` is spawned
- **THEN** its `Command` SHALL be configured with `stdin(Stdio::null())`, `stdout(Stdio::piped())`, `stderr(Stdio::piped())`
- **AND** the parent process SHALL consume stdout via `.output().stdout` into an in-memory buffer only

#### Scenario: Zeroized heap
- **WHEN** the extracted token is held in a local variable
- **THEN** it SHALL be wrapped in `zeroize::Zeroizing<String>` so the heap allocation is overwritten on Drop

#### Scenario: Error-path redaction
- **WHEN** `gh auth token` exits non-zero
- **THEN** its raw stderr SHALL NOT be echoed to the user's terminal
- **AND** a generic error message SHALL be printed pointing the user at `--log-secrets-management`
- **AND** the exit code SHALL be logged via tracing (no token bytes in the log line)

## REMOVED Requirements

### Requirement: `migrate_token_to_keyring()` hosts.yml import

**Reason**: `hosts.yml` is gone from the architecture. No file to migrate from.

**Migration**: Users whose prior-version keyring entries exist at `github-oauth-token.tillandsias` continue to work without action. Users whose prior versions had no working keyring backend (macOS/Windows pre-feature-fix) will be prompted to re-authenticate via `--github-login`.

### Requirement: `write_hosts_yml_from_keyring()` container-side materialization

**Reason**: Container never consumes `hosts.yml`. Runtime credential delivery is the `/run/secrets/github_token` bind-mount only.

**Migration**: Replaced by `secrets::prepare_token_file` / `cleanup_token_file` / `cleanup_all_token_files` — see "Ephemeral token file delivery helpers" above.
