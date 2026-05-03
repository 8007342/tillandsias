<!-- @trace spec:gh-auth-script -->
# gh-auth-script Specification

## Status

status: active

## Purpose

The interactive GitHub Login user experience. Both the CLI entry point (`tillandsias --github-login`) and the tray menu item ("GitHub Login") drive the same single Rust implementation: spin up an ephemeral container from the git service image, run `gh auth login` interactively, extract the resulting OAuth token on the host, persist it via the native keyring, and tear the container down. There is no external shell script — the flow lives entirely in `src-tauri/src/runner.rs::run_github_login`.

## Requirements

### Requirement: Single implementation behind tray and CLI entry points

The CLI flag `--github-login` and the tray menu item "GitHub Login" SHALL invoke the same `runner::run_github_login` function. The tray handler SHALL spawn a terminal that re-executes the Tillandsias binary with `--github-login`; it SHALL NOT reimplement the flow.

@trace spec:gh-auth-script, spec:git-mirror-service, spec:secrets-management

#### Scenario: Tray dispatches to the CLI flow
- **WHEN** the user clicks "GitHub Login" in the tray
- **THEN** `handlers::handle_github_login` SHALL locate `std::env::current_exe()` and spawn it in a new terminal with `--github-login`
- **AND** the terminal session SHALL execute `runner::run_github_login` exactly as the CLI does

#### Scenario: CLI flag triggers the flow directly
- **WHEN** the user runs `tillandsias --github-login`
- **THEN** `runner::run_github_login` SHALL be invoked in the current terminal

### Requirement: Interactive login uses an ephemeral git-service-image container

The login flow SHALL run `gh auth login` inside a dedicated, short-lived container started from the git service image. It SHALL NOT exec into a long-lived per-project git service container.

@trace spec:gh-auth-script, spec:git-mirror-service, spec:secrets-management

#### Scenario: Build image on demand
- **WHEN** the git service image is not present locally
- **THEN** the flow SHALL build it via `scripts/build-image.sh git` before proceeding

#### Scenario: Identity prompt before launch
- **WHEN** the flow starts
- **THEN** the user SHALL be prompted for git author name and email
- **AND** defaults SHALL be read from `<cache>/secrets/git/.gitconfig` first, falling back to the host `~/.gitconfig`
- **AND** the accepted values SHALL be written to `<cache>/secrets/git/.gitconfig`

#### Scenario: Ephemeral keep-alive container
- **WHEN** the flow needs to run the OAuth flow
- **THEN** it SHALL start a container named `tillandsias-gh-login` from the git service image with `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, and `--entrypoint sleep infinity` on the default bridge network (no enclave network, no host mounts)
- **AND** any pre-existing container with that name SHALL be removed first with `podman rm -f`
- **AND** `podman exec -it tillandsias-gh-login gh auth login --git-protocol https` SHALL inherit the real TTY for the interactive device-code flow

### Requirement: Host extracts the token and persists it in the native keyring

After interactive `gh auth login` succeeds, the host SHALL extract the OAuth token from inside the container and store it via `secrets::store_github_token` in the native keyring defined by `spec:native-secrets-store`.

@trace spec:gh-auth-script, spec:native-secrets-store, spec:secrets-management

#### Scenario: Token extraction
- **WHEN** the interactive `gh auth login` exits successfully
- **THEN** the host SHALL run `podman exec tillandsias-gh-login gh auth token` and capture stdout
- **AND** abort with an error if the output is empty or the command fails

#### Scenario: Username extraction (advisory)
- **WHEN** the token has been captured
- **THEN** the host SHALL run `podman exec tillandsias-gh-login gh api user --jq .login` to capture the GitHub username for confirmation messages
- **AND** failure SHALL be non-fatal (the username is advisory only)

#### Scenario: Persist in keyring
- **WHEN** the token has been captured
- **THEN** the host SHALL call `secrets::store_github_token(token)`
- **AND** abort the flow with an error if the keyring write fails

### Requirement: Drop guard tears down the login container on every exit path

The login container SHALL be destroyed on every exit path so no `gh` on-disk state survives the flow.

@trace spec:gh-auth-script, spec:secrets-management

#### Scenario: Successful completion
- **WHEN** the flow completes successfully
- **THEN** the Drop guard SHALL run `podman rm -f tillandsias-gh-login` before the function returns

#### Scenario: Failure or user cancellation
- **WHEN** any step fails (image build, container start, interactive login, token extraction, keyring write) or the user aborts
- **THEN** the Drop guard SHALL still run `podman rm -f tillandsias-gh-login`
- **AND** all on-disk `gh` state inside the container SHALL be destroyed with the container
- **AND** no token SHALL be written to any host file outside the keyring

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:gh-auth-script" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
