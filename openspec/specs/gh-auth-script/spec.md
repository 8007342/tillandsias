<!-- @trace spec:gh-auth-script -->
# gh-auth-script Specification

## Status

status: active

## Purpose

The interactive GitHub Login user experience. Both the CLI entry point (`tillandsias --github-login`) and the tray menu item ("GitHub Login") drive the same single Rust implementation: spin up an ephemeral container from the git service image, run and verify `gh auth login` interactively, write the resulting OAuth token to Vault from inside the container, and tear the container down. There is no external shell script; the token is never extracted or stored on the host. The flow lives in `crates/tillandsias-headless/src/main.rs::run_github_login`.

## Requirements

### Requirement: Single implementation behind tray and CLI entry points
<!-- req-id: 4a8426ff -->

The CLI flag `--github-login` and the tray menu item "GitHub Login" MUST invoke the same `runner::run_github_login` function. The tray handler MUST spawn a terminal that re-executes the Tillandsias binary with `--github-login`; it MUST NOT reimplement the flow.

@trace spec:gh-auth-script, spec:git-mirror-service, spec:tillandsias-vault

#### Scenario: Tray dispatches to the CLI flow
- **WHEN** the user clicks "GitHub Login" in the tray
- **THEN** `handlers::handle_github_login` MUST locate `std::env::current_exe()` and spawn it in a new popup terminal window with `--github-login`
- **AND** the terminal session MUST execute `runner::run_github_login` exactly as the CLI does
- **AND** the launcher MUST try modern emulators first (ptyxis, gnome-terminal, kgx) before legacy ones (konsole, xterm)
- **AND** it MUST NOT fall back to running the flow inline in the tray's controlling terminal, because the tray may be started from a desktop shortcut with no such terminal

#### Scenario: No terminal emulator available
- **WHEN** the user clicks "GitHub Login" in the tray
- **AND** no supported terminal emulator is found on `PATH`
- **THEN** `launch_in_terminal` MUST return an error rather than executing the flow inline
- **AND** the tray MUST surface the failure via the status line so the click does not appear to silently do nothing

#### Scenario: CLI flag triggers the flow directly
- **WHEN** the user runs `tillandsias --github-login` from a terminal (including a headless SSH session)
- **THEN** `runner::run_github_login` MUST be invoked inline in the current terminal, with no popup

### Requirement: Non-interactive login is explicit and cannot hang on `/dev/tty`
<!-- req-id: a8878caa -->

The default GitHub login path MUST require a terminal. Automation MAY opt into
stdin token delivery with `--github-login --with-token`; the token MUST flow
directly from inherited stdin to the ephemeral container and MUST NOT be
placed in argv, an environment variable, a project file, or host memory.

@trace spec:gh-auth-script, spec:tillandsias-vault

#### Scenario: Piped invocation without opt-in fails loud
- **WHEN** stdin is not a terminal and the user runs `tillandsias --github-login` without `--with-token`
- **THEN** the command MUST exit non-zero before starting Podman infrastructure
- **AND** the error MUST name `--with-token` and the existing git identity prerequisite
- **AND** the command MUST NOT attempt to open or read `/dev/tty`

#### Scenario: Explicit stdin token delivery
- **WHEN** a caller pipes one token line to `tillandsias --github-login --with-token`
- **AND** git `user.name` and `user.email` already exist in the managed or host configuration
- **THEN** Podman exec MUST inherit stdin with `--interactive` and MUST NOT allocate `--tty`
- **AND** identity collection MUST use the existing values without consuming the token stream
- **AND** successful authentication MUST follow the same in-container Vault write and verification path as interactive login

### Requirement: Interactive login uses an ephemeral git-service-image container
<!-- req-id: ffb548a7 -->

The login flow MUST run `gh auth login` inside a dedicated, short-lived container started from the git service image. It MUST NOT exec into a long-lived per-project git service container.

@trace spec:gh-auth-script, spec:git-mirror-service, spec:tillandsias-vault

#### Scenario: Build image on demand
- **WHEN** the git service image is not present locally
- **THEN** the flow MUST build it via `scripts/build-image.sh git` before proceeding

#### Scenario: Identity prompt before launch
- **WHEN** the flow starts
- **THEN** the user MUST be prompted for git author name and email
- **AND** defaults MUST be read from `<cache>/secrets/git/.gitconfig` first, falling back to the host `~/.gitconfig`
- **AND** the accepted values MUST be written to `<cache>/secrets/git/.gitconfig`

#### Scenario: Ephemeral keep-alive container
- **WHEN** the flow needs to run the OAuth flow
- **THEN** it MUST start a container named `tillandsias-gh-login` from the git service image with `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, and `--entrypoint sleep infinity` on the default bridge network (no enclave network, no host mounts)
- **AND** any pre-existing container with that name MUST be removed first with `podman rm -f`
- **AND** `podman exec -it tillandsias-gh-login gh auth login --git-protocol https` MUST inherit the real TTY for the interactive device-code flow

### Requirement: Container verifies the session, writes the token to Vault, never reaches the host
<!-- req-id: 2458b36e -->

After interactive `gh auth login` succeeds, the git container MUST verify the session and write the OAuth token to Vault entirely inside the container — the token is never extracted or stored on the host.

@trace spec:gh-auth-script, spec:tillandsias-vault

#### Scenario: Session verification
- **WHEN** the interactive `gh auth login` exits successfully
- **THEN** the host MUST run `podman exec tillandsias-gh-login gh auth status --hostname github.com`
- **AND** MUST abort before Vault persistence if verification fails

#### Scenario: Vault write from inside the container
- **WHEN** the interactive `gh auth login` exits successfully
- **THEN** the host MUST exec an in-container command that requires
  `gh auth token --hostname github.com` to succeed and return a non-empty token,
  then streams that token to
  `vault-cli.sh write-stdin secret/github/token token` on stdin via `podman exec`
- **AND** MUST abort with an error if the Vault write fails
- **AND** the token MUST NOT be captured or stored in host memory
- **AND** token bytes MUST NOT enter the host/Podman command string or any
  external-process argv
- **AND** in-container shell-variable and shell-builtin staging MAY hold the
  token only to validate it and feed `write-stdin`.

#### Scenario: Vault write verification
- **WHEN** the Vault write completes
- **THEN** the host MUST exec `vault-cli.sh read -field=token secret/github/token` inside the container to verify the write
- **AND** MUST abort with an error if verification fails

#### Scenario: Username extraction (advisory)
- **WHEN** the Vault write is confirmed
- **THEN** the host MUST run `podman exec tillandsias-gh-login gh api user --jq .login` to capture the GitHub username for confirmation messages
- **AND** failure MUST be non-fatal (the username is advisory only)

#### Scenario: No host-side token extraction
- **WHEN** the flow completes
- **THEN** the host MUST NOT capture `gh auth token` stdout
- **AND** MUST NOT create the deprecated `tillandsias-github-token` Podman secret
- **AND** the token SHALL exist only inside the container and in Vault

### Requirement: Drop guard tears down the login container on every exit path
<!-- req-id: 98d98496 -->

The login container MUST be destroyed on every exit path so no `gh` on-disk state survives the flow.

@trace spec:gh-auth-script, spec:tillandsias-vault

#### Scenario: Successful completion
- **WHEN** the flow completes successfully
- **THEN** the Drop guard MUST run `podman rm -f tillandsias-gh-login` before the function returns

#### Scenario: Failure or user cancellation
- **WHEN** any step fails (image build, container start, interactive login, token extraction, keyring write) or the user aborts
- **THEN** the Drop guard MUST still run `podman rm -f tillandsias-gh-login`
- **AND** all on-disk `gh` state inside the container MUST be destroyed with the container
- **AND** no token MUST be written to any host file outside the keyring

### Requirement: Mobile QR Code Device Flow
<!-- req-id: 7a82bc19 -->

Interactive GitHub Login MUST use GitHub App OAuth Device Authorization Grant (RFC 8628) with high-contrast terminal QR code rendering, allowing operators to complete authentication entirely on a mobile device without local browser involvement.

@trace spec:gh-auth-script, spec:tillandsias-vault

#### Scenario: Mobile QR Code display
- **WHEN** the user initiates interactive `--github-login`
- **THEN** the flow MUST request a device code from GitHub using Client ID `Iv23liddVkg9ME6OB1K1`
- **AND** the terminal MUST render a QR code containing `https://github.com/login/device?user_code=<user_code>`
- **AND** the QR code MUST be formatted using Unicode block characters with ANSI high-contrast styling (`\x1b[47m\x1b[30m`) ensuring readability across both dark and light terminal emulators
- **AND** the flow MUST display the verification URL and user code as text fallback

#### Scenario: Mobile authorization polling and persistence
- **WHEN** the QR code is displayed
- **THEN** an in-container polling loop MUST poll GitHub until the device authorization is completed or expired
- **AND** the poll MUST run for the device code's full `expires_in`, not under a shorter generic budget
- **AND** the device code MUST NOT appear on any spawned process's argv (the poll script and curl's form body travel on stdin)
- **AND** once approved, the container MUST write Vault BEFORE anything uses the token: the refresh token and its expiry to `secret/github/refresh` first, then the access token, its expiry and the client ID to `secret/github/token`
- **AND** only then MUST the container authenticate the containerized `gh` session via `gh auth login --with-token`
- **AND** the git-mirror policy MUST NOT be able to read `secret/github/refresh` (the refresh token mints access tokens for months; git-mirror only needs the short-lived one)
- **AND** no token bytes SHALL enter the host process memory or host environment
- **AND** no error message SHALL contain any part of a GitHub response body
- **AND** test behaviour MUST be selected only by an environment switch, never by the content of a reply, and the switch MUST NOT reach an interactive `gh auth login` or any Vault write

### Requirement: Token Rotation and Expiration Management
<!-- req-id: 9c34ea81 -->

GitHub App user-to-server access tokens expire after 8 hours. The system MUST persist and manage refresh tokens in Vault, supporting automatic and explicit token rotation.

@trace spec:gh-auth-script, spec:secret-rotation, spec:tillandsias-vault

#### Scenario: Refresh token rotation
- **WHEN** an access token nears expiration (within 30 minutes) or has expired
- **AND** a valid refresh token exists in Vault
- **THEN** the system MUST exchange the refresh token at `https://github.com/login/oauth/access_token` for a new access token and rotated refresh token
- **AND** the rotation MUST hold an exclusive lock from reading the stored refresh token until the new pair is written (refresh tokens are single-use)
- **AND** the rotated refresh token MUST be written to `secret/github/refresh` BEFORE the new access token is written to `secret/github/token`, and a failed write MUST leave the previous records intact
- **AND** an accountability audit event MUST be recorded under `spec:secret-rotation`

#### Scenario: Explicit refresh is an operator action
- **WHEN** `tillandsias --refresh-github-token` runs without a desktop session
- **THEN** it MUST refuse with a non-zero exit and record the audit event
- **AND** when Vault holds no refresh token (or no token), the command MUST exit non-zero rather than report success

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:gh-auth-script-smoke` — Verify the fake login harness exercises the same ephemeral Podman flow

Gating points:
- The login harness runs the same ephemeral Podman flow as the CLI implementation
- The token capture and keyring write path remain observable in the fake harness
- Cleanup still removes the container on all exit paths

## Sources of Truth

- `crates/tillandsias-headless/src/main.rs` — the single Rust implementation for `--github-login`
- `scripts/test-support/github-login-fake.sh` — deterministic smoke harness for the login flow
- `crates/tillandsias-headless/src/vault_bootstrap.rs` — Vault write and read-back verification
- `openspec/specs/tillandsias-vault/spec.md` — exclusive secret-store contract
- `openspec/specs/git-mirror-service/spec.md` — ephemeral git-service container and gh auth integration

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:gh-auth-script" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
