<!-- @trace spec:native-secrets-store -->
# native-secrets-store Specification

## Status

active

## Purpose

Store and retrieve the GitHub OAuth token in the host OS's platform-native secret service. The host Rust process is the sole consumer of the keyring; containers never call any keyring API. This is the source of truth for GitHub credentials — no plaintext credential files live on persistent disk.

## Requirements

### Requirement: Platform-native keyring backend

The application MUST use the platform-native secret service exclusively, accessed in-process via the `keyring` crate.

@trace spec:native-secrets-store

#### Scenario: Linux backend
- **WHEN** the application runs on Linux
- **THEN** the keyring MUST be accessed via libsecret against the Secret Service D-Bus API (GNOME Keyring, KDE Wallet, or any compatible Secret Service implementation)

#### Scenario: macOS backend
- **WHEN** the application runs on macOS
- **THEN** the keyring MUST be accessed via Keychain Services (Security framework, Generic Password class)

#### Scenario: Windows backend
- **WHEN** the application runs on Windows
- **THEN** the keyring MUST be accessed via Credential Manager (Wincred, `CredWriteW` / `CredReadW` / `CredDeleteW`)

### Requirement: Single keyring entry for the GitHub token

The GitHub OAuth token MUST be stored under a single, fixed keyring entry shared by all platforms.

@trace spec:native-secrets-store

#### Scenario: Canonical entry coordinates
- **WHEN** any of `store_github_token`, `retrieve_github_token`, or `delete_github_token` is invoked
- **THEN** the keyring entry MUST be created with service name `tillandsias` and key `github-oauth-token`
- **AND** these constants MUST match `SERVICE` and `GITHUB_TOKEN_KEY` in `src-tauri/src/secrets.rs`

### Requirement: Host-only keyring API surface

The functions `store_github_token`, `retrieve_github_token`, and `delete_github_token` MUST be the sole APIs for accessing the GitHub OAuth token, and MUST execute exclusively in the host Rust process. No container, entrypoint script, or subprocess MUST call the keyring directly.

@trace spec:native-secrets-store, spec:secrets-management

#### Scenario: Store after successful authentication
- **WHEN** the `--github-login` flow successfully extracts a token via `gh auth token`
- **THEN** the host Rust process MUST call `store_github_token(token)`
- **AND** the function MUST return `Err` if the keyring is unreachable, causing the login flow to abort with no token written to disk

#### Scenario: Retrieve at container launch
- **WHEN** a container with `SecretKind::GitHubToken` is about to launch
- **THEN** the host MUST call `retrieve_github_token()` in-process
- **AND** on `Ok(Some(token))` the host MUST write it to the per-container ephemeral file defined in `spec:secrets-management`
- **AND** on `Ok(None)` the host MUST skip the bind mount and proceed with launch
- **AND** on `Err` the host MUST surface the error to the user (no fallback path)

#### Scenario: Logout removes the entry
- **WHEN** `delete_github_token()` is invoked
- **THEN** the keyring entry MUST be removed
- **AND** the function MUST return `Ok(())` even if no entry existed (idempotent)

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:credential-isolation` — Verify token is stored in native keyring and never written to disk outside keyring
- `litmus:socket-cleanup` — Verify D-Bus sockets are cleaned up after keyring operations

Gating points:
- `store_github_token(token)` writes to OS native keyring (GNOME Keyring on Linux, Keychain on macOS, Credential Manager on Windows)
- Token stored with service name `tillandsias` and username `github`
- `retrieve_github_token()` reads from keyring; returns `None` if no entry exists
- `delete_github_token()` removes entry from keyring; idempotent (no error if missing)
- No token file written to `~/.config/` or `~/.ssh/` or any host filesystem
- D-Bus/IPC sockets used for keyring access are cleaned up after operation
- Container cannot access host keyring directly; only via D-Bus bridge

## Sources of Truth

- `cheatsheets/runtime/unix-socket-ipc.md` — Unix Socket Ipc reference and patterns
- `cheatsheets/security/owasp-top-10-2021.md` — Owasp Top 10 2021 reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:native-secrets-store" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
