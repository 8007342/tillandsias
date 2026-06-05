<!-- @trace spec:gh-auth-script -->
# gh-auth-script Specification

## Status

status: active

## Purpose

The interactive GitHub Login user experience. Both the CLI entry point (`tillandsias --github-login`) and the tray menu item ("GitHub Login") drive the same single Rust implementation: spin up an ephemeral container from the git service image, run and verify `gh auth login` interactively, extract the resulting OAuth token on the host, persist it in Vault, and tear the container down. There is no external shell script; the flow lives in `crates/tillandsias-headless/src/main.rs::run_github_login`.

## Requirements

### Requirement: Single implementation behind tray and CLI entry points

The CLI flag `--github-login` and the tray menu item "GitHub Login" MUST invoke the same `runner::run_github_login` function. The tray handler MUST spawn a terminal that re-executes the Tillandsias binary with `--github-login`; it MUST NOT reimplement the flow.

@trace spec:gh-auth-script, spec:git-mirror-service, spec:secrets-management

#### Scenario: Tray dispatches to the CLI flow
- **WHEN** the user clicks "GitHub Login" in the tray
- **THEN** `handlers::handle_github_login` MUST locate `std::env::current_exe()` and spawn it in a new terminal with `--github-login`
- **AND** the terminal session MUST execute `runner::run_github_login` exactly as the CLI does

#### Scenario: CLI flag triggers the flow directly
- **WHEN** the user runs `tillandsias --github-login`
- **THEN** `runner::run_github_login` MUST be invoked in the current terminal

### Requirement: Interactive login uses an ephemeral git-service-image container

The login flow MUST run `gh auth login` inside a dedicated, short-lived container started from the git service image. It MUST NOT exec into a long-lived per-project git service container.

@trace spec:gh-auth-script, spec:git-mirror-service, spec:secrets-management

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

### Requirement: Host verifies the session, extracts the token, and persists it in Vault

After interactive `gh auth login` succeeds, the host MUST verify the session, extract the OAuth token from inside the container, and store it in Vault at `secret/github/token` as defined by `spec:tillandsias-vault`.

@trace spec:gh-auth-script, spec:tillandsias-vault, spec:secrets-management

#### Scenario: Session verification
- **WHEN** the interactive `gh auth login` exits successfully
- **THEN** the host MUST run `podman exec tillandsias-gh-login gh auth status --hostname github.com`
- **AND** MUST abort before token persistence if verification fails

#### Scenario: Token extraction
- **WHEN** the interactive `gh auth login` exits successfully
- **THEN** the host MUST run `podman exec tillandsias-gh-login gh auth token` and capture stdout
- **AND** MUST abort with an error if the output is empty or the command fails

#### Scenario: Username extraction (advisory)
- **WHEN** the token has been captured
- **THEN** the host MUST run `podman exec tillandsias-gh-login gh api user --jq .login` to capture the GitHub username for confirmation messages
- **AND** failure MUST be non-fatal (the username is advisory only)

#### Scenario: Persist in Vault
- **WHEN** the token has been captured
- **THEN** the host MUST write the token to Vault at `secret/github/token`
- **AND** MUST verify the Vault write by reading the token back
- **AND** MUST abort the flow with an error if either operation fails
- **AND** MUST NOT create the deprecated `tillandsias-github-token` Podman secret

### Requirement: Drop guard tears down the login container on every exit path

The login container MUST be destroyed on every exit path so no `gh` on-disk state survives the flow.

@trace spec:gh-auth-script, spec:secrets-management

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
