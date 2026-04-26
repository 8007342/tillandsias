# secrets-management Specification

## Purpose

Credential delivery pipeline for Tillandsias containers. The host Rust process is the sole consumer of the OS native keyring; containers never see D-Bus, the keyring API, or any host credential beyond a single ephemeral token file this pipeline writes before launch and unlinks on stop. Enforces the zero-credential security boundary: forge and terminal containers have ZERO credentials; only the git service container receives a read-only token file via bind mount.
## Requirements
### Requirement: Zero-credential boundary for forge and terminal containers

Forge containers (opencode, claude) and terminal containers SHALL have zero credentials mounted: no GitHub tokens, no API keys, no secret bind mounts, no D-Bus socket. Code arrives from the git mirror service; packages arrive through the proxy. Git push operations go through the enclave-internal git service, which authenticates on behalf of the forge.

@trace spec:secrets-management

#### Scenario: Forge container launched without credentials
- **WHEN** a forge container (opencode or claude) is launched
- **THEN** the container profile SHALL have an empty `secrets` list
- **AND** `token_file_path` SHALL be `None` in the launch context
- **AND** the accountability log SHALL record `credential-free (no token mounts)`

#### Scenario: Terminal container launched without credentials
- **WHEN** a terminal or root terminal container is launched
- **THEN** the container profile SHALL have an empty `secrets` list
- **AND** no GitHub token SHALL be bind-mounted

#### Scenario: Git service container receives only the token file
- **WHEN** a git service container is launched
- **THEN** its profile SHALL include exactly one `SecretKind::GitHubToken` entry
- **AND** the host SHALL bind-mount the ephemeral token file at `/run/secrets/github_token:ro`
- **AND** no D-Bus socket, no keyring handle, and no other credential material SHALL be mounted

### Requirement: Token file infrastructure on per-user ephemeral storage

The host SHALL write GitHub tokens to per-container ephemeral files rooted in a per-user runtime directory, ready for read-only bind mount into containers that request `SecretKind::GitHubToken`. Token files SHALL never touch persistent storage and SHALL be unlinked when the container stops. The implementation lives in `src-tauri/src/secrets.rs::prepare_token_file` / `cleanup_token_file` / `cleanup_all_token_files`.

@trace spec:secrets-management

#### Scenario: Token file written before container launch
- **WHEN** a container with `SecretKind::GitHubToken` is about to launch and a token exists in the OS keyring
- **THEN** the host Rust process SHALL read the token from the keyring in-process (no IPC, no D-Bus forwarding)
- **AND** write the token to `<token_file_root>/<container-name>/github_token`
- **AND** `<token_file_root>` SHALL be `$XDG_RUNTIME_DIR/tillandsias/tokens/` on Linux, `$TMPDIR/tillandsias-tokens/` on macOS, and `%LOCALAPPDATA%\Temp\tillandsias-tokens\` on Windows
- **AND** the write SHALL be atomic: content goes to `<path>.tmp`, then `std::fs::rename` moves it onto the final path

#### Scenario: Token file permissions on Unix
- **WHEN** a token file is written on Linux or macOS
- **THEN** the parent directory SHALL have mode `0700`
- **AND** the file SHALL be created with mode `0600` via `OpenOptions::mode`

#### Scenario: Token file permissions on Windows
- **WHEN** a token file is written on Windows
- **THEN** the file SHALL inherit the per-user NTFS ACL of `%LOCALAPPDATA%` (no group or other access)
- **AND** no explicit mode bits SHALL be set

#### Scenario: Token file bind-mounted read-only
- **WHEN** a container's profile includes `SecretKind::GitHubToken` and `ctx.token_file_path` is `Some(path)`
- **THEN** `build_podman_args` SHALL append `-v <path>:/run/secrets/github_token:ro`
- **AND** SHALL set `GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias.sh`

#### Scenario: No token available in keyring
- **WHEN** a container requests `SecretKind::GitHubToken` but the keyring has no entry
- **THEN** `prepare_token_file` SHALL return `Ok(None)`
- **AND** the mount SHALL be skipped (no `/run/secrets/github_token` inside the container)
- **AND** an accountability warning SHALL record that authenticated git operations will fail

#### Scenario: Token file deleted on container stop
- **WHEN** a container with a prepared token file stops
- **THEN** the orchestrator SHALL call `cleanup_token_file(container_name)`
- **AND** the file and its parent directory SHALL be unlinked (idempotent if already gone)

#### Scenario: All token files cleaned on app exit
- **WHEN** the Tillandsias application exits (including panic via Drop guard)
- **THEN** `cleanup_all_token_files()` SHALL remove the entire `<token_file_root>` tree

### Requirement: git-askpass credential mechanism

The git service image SHALL include `/usr/local/bin/git-askpass-tillandsias.sh`. The script SHALL read the token from `/run/secrets/github_token` and return it as the password when git requests credentials. The `GIT_ASKPASS` environment variable SHALL point to this script in containers with `SecretKind::GitHubToken`. Forge and terminal entrypoints SHALL NOT run `gh auth setup-git` — forge is credential-free.

@trace spec:secrets-management

#### Scenario: git push uses askpass
- **WHEN** a git push is executed inside the git service container with `GIT_ASKPASS` set
- **THEN** git SHALL call the askpass script
- **AND** the script SHALL return `x-access-token` as username and the token file contents as password

#### Scenario: Token file missing at askpass time
- **WHEN** the askpass script is called but `/run/secrets/github_token` does not exist
- **THEN** the script SHALL return an empty password
- **AND** the git operation SHALL fail with an authentication error (expected behavior when the user has not run `--github-login`)

### Requirement: Single-strategy authentication flow

The `--github-login` flow SHALL authenticate by running `gh auth login` inside an ephemeral git-service-image container, extracting the token on the host, and storing it in the native keyring. There is no host-side `gh` fallback and no D-Bus-forwarded container path.

@trace spec:secrets-management

#### Scenario: Interactive login inside ephemeral container
- **WHEN** the user invokes `--github-login` (CLI) or clicks "GitHub Login" in the tray
- **THEN** the host SHALL prompt for git identity (name, email) with defaults read from the cached gitconfig or the host `~/.gitconfig`
- **AND** write the accepted identity to `<cache>/secrets/git/.gitconfig`
- **AND** start a keep-alive container from the git service image with the non-negotiable security flags (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`) on the default bridge network
- **AND** `podman exec -it <container> gh auth login --git-protocol https` with the real TTY inherited

#### Scenario: Token extraction and persistence
- **WHEN** the interactive `gh auth login` completes successfully
- **THEN** the host SHALL run `podman exec <container> gh auth token` to capture the token
- **AND** call `secrets::store_github_token(token)` which writes it into the OS keyring (Secret Service / Keychain / Credential Manager)
- **AND** the login container SHALL be removed via a Drop guard (`podman rm -f`), destroying all on-disk `gh` state

#### Scenario: Authentication aborts cleanly
- **WHEN** any step of the login flow fails (user cancels, network error, keyring rejects write)
- **THEN** the Drop guard SHALL tear down the login container regardless
- **AND** no token SHALL be written to any file on disk
- **AND** `--log-secrets-management` SHALL record the abort reason

### Requirement: Secrets directory structure

The host SHALL maintain a secrets directory at `~/.cache/tillandsias/secrets/` with a `git/` subdirectory containing `.gitconfig` for user identity. The directory SHALL be created at launch time by `ensure_secrets_dirs()`. The `.gitconfig` file SHALL contain only `user.name` and `user.email` — no tokens. GitHub tokens are NEVER written to this directory; they live exclusively in the OS keyring.

@trace spec:secrets-management

#### Scenario: First launch creates secrets directories
- **WHEN** the application launches and `~/.cache/tillandsias/secrets/` does not exist
- **THEN** the system SHALL create the `secrets/git/` directory
- **AND** an empty `.gitconfig` file SHALL be created in `secrets/git/`

#### Scenario: Git identity persists across sessions
- **WHEN** a user provides their name and email during GitHub Login
- **THEN** the identity SHALL be written to `~/.cache/tillandsias/secrets/git/.gitconfig`
- **AND** subsequent container launches SHALL read this identity and inject it as `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` environment variables

### Requirement: Accountability logging for credential lifecycle

All credential operations SHALL be logged to the `--log-secrets-management` accountability window. Log entries SHALL include the `category = "secrets"` field and reference `spec:secrets-management` or `spec:native-secrets-store`. No token values or credential material SHALL appear in log output.

@trace spec:secrets-management

#### Scenario: Credential-free launch logged
- **WHEN** a forge or terminal container is launched
- **THEN** an accountability log entry SHALL record `credential-free (no token mounts)` with the container name

#### Scenario: Token injection logged
- **WHEN** a token file is prepared and bind-mounted for a git service container
- **THEN** an accountability log entry SHALL record the host file path and the `:ro` mount status
- **AND** no entry SHALL contain the token value itself

#### Scenario: Token revocation logged
- **WHEN** a token file is deleted on container stop or app exit
- **THEN** an accountability log entry SHALL record the sweep event with the container name

### Requirement: Process isolation and hardening

Each container type SHALL have a `--pids-limit` matching its intended workload, preventing fork bombs and constraining process count. Service containers (git, web) SHALL run with `--read-only` root filesystems and explicit `--tmpfs` mounts for runtime directories.

@trace spec:secrets-management

#### Scenario: Git service process isolation
- **WHEN** a git service container is launched
- **THEN** it SHALL have `--pids-limit=64` (only git-daemon + git processes)
- **AND** it SHALL run with `--read-only` root filesystem and `--tmpfs=/tmp`
- **AND** it SHALL be the sole container receiving the `/run/secrets/github_token` bind mount

#### Scenario: Forge and terminal containers are credential-free
- **WHEN** a forge container (opencode, claude) or terminal container is launched
- **THEN** it SHALL have `--pids-limit=512` (compilers, language servers, AI tools)
- **AND** it SHALL have zero credential mounts and zero D-Bus access
- **AND** it SHALL NOT have `--read-only` (mutable workspace required)

#### Scenario: Proxy container has no credentials
- **WHEN** the proxy container is launched
- **THEN** it SHALL have `--pids-limit=32` (only squid + helpers)
- **AND** it SHALL have no credential mounts

#### Scenario: Inference container has no credentials
- **WHEN** the inference container is launched
- **THEN** it SHALL have `--pids-limit=128` (ollama server + model runners)
- **AND** it SHALL have no credential mounts

#### Scenario: Web container is maximally restricted
- **WHEN** a web container is launched
- **THEN** it SHALL have `--pids-limit=32` (only httpd)
- **AND** it SHALL run with `--read-only` root filesystem and `--tmpfs=/tmp --tmpfs=/var/run`

### Requirement: AppImage environment sanitization

The authentication flow SHALL unset `LD_LIBRARY_PATH` and `LD_PRELOAD` before invoking podman. These variables are set by AppImage extraction and break podman's ability to launch containers.

@trace spec:secrets-management

#### Scenario: Running from AppImage
- **WHEN** the `--github-login` flow is invoked from an AppImage-extracted environment
- **THEN** `LD_LIBRARY_PATH` and `LD_PRELOAD` SHALL be unset before any podman command
- **AND** podman SHALL function correctly with the system's native libraries

### Requirement: Control socket joins the managed-IPC class

The system SHALL treat the tray-host control socket at
`$XDG_RUNTIME_DIR/tillandsias/control.sock` (or `/tmp/tillandsias-$UID/control.sock`
fallback) as a managed credential-adjacent transport: it carries secret
material (per-window OTPs, future session bootstraps) between the tray and
bind-mounted consumer containers. The handling rules below MUST mirror the
`secrets-management` discipline already enforced for GitHub tokens.

1. **Loopback only.** The socket SHALL be a Unix-domain `SOCK_STREAM` node on
   the local filesystem. It MUST NOT be exposed via TCP, abstract namespace,
   D-Bus, or any cross-host transport. The kernel-enforced filesystem
   permission (`0600` on the node, `0700` on the parent directory) is the
   sole authentication mechanism.
2. **Never at rest.** Frame payloads SHALL exist only in process memory (tray,
   accepted-connection task buffers, consumer client buffers). Frames MUST
   NOT be written to disk, persisted to logs in cleartext, or copied into
   any cache directory. Postcard envelopes that carry secret material (e.g.,
   `IssueWebSession.cookie_value`) SHALL be redacted in any debug or
   accountability log.
3. **Lifetime bounded by tray lifetime.** The socket node SHALL exist only
   while the tray is running: bound at startup, unlinked at graceful
   shutdown, replaced at next-start stale-recovery if the tray crashed. No
   long-lived socket file SHALL persist across tray-down windows.
4. **Bind-mount surface is opt-in per container.** Containers SHALL receive
   the bind-mount only when their profile declares `mount_control_socket =
   true`. Forge containers SHALL default to `false`. The default-deny posture
   prevents a compromised forge from sending any control message — the same
   reasoning that keeps GitHub tokens off the forge.

@trace spec:secrets-management, spec:tray-host-control-socket

#### Scenario: Socket node permissions enforced at the OS layer

- **WHEN** the tray binds the control socket
- **THEN** the parent directory SHALL be mode `0700` and owned by the tray
  user
- **AND** the socket node SHALL be mode `0600` after the chmod step between
  `bind()` and `listen()`
- **AND** a `connect(2)` from a different UID SHALL fail with `EACCES` at
  the kernel layer, with no application code reached

#### Scenario: Frame contents redacted in accountability log

- **WHEN** the tray dispatches an `IssueWebSession { project_label, cookie_value }`
  frame to a consumer
- **THEN** the accountability log entry SHALL record
  `category = "secrets"`, `spec = "tray-host-control-socket"`, the
  `project_label`, and the `from` of the connected consumer
- **AND** the `cookie_value` field SHALL be absent from the log (replaced by
  `<redacted, 32 bytes>` or similar fixed-width sentinel)
- **AND** no debug-level log entry SHALL emit the cookie value either

#### Scenario: Forge container cannot reach the control socket by default

- **WHEN** an attacker who has compromised a forge container attempts to
  send any `ControlMessage` variant
- **THEN** `connect(2)` to `/run/host/tillandsias/control.sock` SHALL fail
  with `ENOENT` because the bind-mount is absent under the default forge
  profile
- **AND** the forge SHALL have no other channel to reach the tray's control
  plane (no TCP listener, no D-Bus access)

#### Scenario: Tray restart drops in-flight secret material

- **WHEN** the tray exits while a consumer holds an open connection mid-frame
- **THEN** the kernel SHALL close the connection on tray exit, dropping any
  buffered frame the tray had not yet read
- **AND** the consumer SHALL treat the disconnect as the cancellation of
  in-flight secret-bearing operations (no retry of the same `seq` against
  the new tray instance — the consumer SHALL re-handshake and re-issue
  fresh secrets)
- **AND** stale per-connection state (sequence numbers, pending acks) SHALL
  NOT survive the disconnect

