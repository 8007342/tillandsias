<!-- @trace spec:gh-auth-script -->
# gh-auth-script Specification

## Status

status: active

## Purpose

The interactive GitHub Login user experience. Both the CLI entry point (`tillandsias --github-login`) and the tray menu item ("GitHub Login") drive the same single Rust implementation: spin up an ephemeral container from the git service image, run and verify `gh auth login` interactively, write the resulting OAuth token to Vault from inside the container, and tear the container down. There is no external shell script; the token is never extracted or stored on the host. The flow lives in `crates/tillandsias-headless/src/main.rs::run_github_login`.

## Requirements

### Requirement: Single implementation behind tray and CLI entry points

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

After interactive `gh auth login` succeeds, the git container MUST verify the session and write the OAuth token to Vault entirely inside the container — the token is never extracted or stored on the host.

@trace spec:gh-auth-script, spec:tillandsias-vault

#### Scenario: Session verification
- **WHEN** the interactive `gh auth login` exits successfully
- **THEN** the host MUST run `podman exec tillandsias-gh-login gh auth status --hostname github.com`
- **AND** MUST abort before Vault persistence if verification fails

#### Scenario: Vault write from inside the container
- **WHEN** the interactive `gh auth login` exits successfully
- **THEN** the host MUST exec `TOKEN=$(gh auth token --hostname github.com); vault-cli.sh write secret/github/token "token=$TOKEN"` inside the container via `podman exec`
- **AND** MUST abort with an error if the Vault write fails
- **AND** the token MUST NOT be captured or stored in host memory

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
