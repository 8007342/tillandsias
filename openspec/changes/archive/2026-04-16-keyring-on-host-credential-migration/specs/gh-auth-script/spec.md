## MODIFIED Requirements

### Requirement: Unified login entry point

The GitHub login flow SHALL have exactly one implementation, exposed as both `tillandsias --github-login` (CLI) and tray > Settings > GitHub Login (GUI). The tray path SHALL spawn the CLI path in a new terminal; there is no separate tray-specific credential code.

#### Scenario: CLI invocation
- **WHEN** the user runs `tillandsias --github-login`
- **THEN** `runner::run_github_login` SHALL execute directly in-process

#### Scenario: Tray menu invocation
- **WHEN** the user clicks tray > Settings > GitHub Login
- **THEN** `handlers::handle_github_login` SHALL call `open_terminal` to spawn `<own-exe-path> --github-login` in a new terminal window
- **AND** it SHALL NOT execute any gh commands directly — the spawned CLI process owns the flow

### Requirement: Ephemeral container for every login

The login flow SHALL always start a fresh ephemeral `tillandsias-gh-login` container. It SHALL NOT exec into any long-running per-project git-service container.

#### Scenario: Defensive cleanup
- **WHEN** the flow begins
- **THEN** it SHALL first run `podman rm -f tillandsias-gh-login` to clear any leftover container from an aborted prior run (errors ignored — harmless if not present)

#### Scenario: Keep-alive container pattern
- **WHEN** ready to authenticate
- **THEN** the flow SHALL `podman run -d` with `--entrypoint sleep` and `infinity` arg to start a detached keep-alive container
- **AND** all subsequent `gh auth login` / `gh auth token` / `gh api user` calls SHALL run via `podman exec` against the same container

#### Scenario: Drop-guard teardown
- **WHEN** the flow returns for any reason (success, error, panic)
- **THEN** a `LoginContainerGuard` (implements `Drop`) SHALL run `podman rm -f` to destroy the container and its ephemeral state

### Requirement: Git identity prompt

The flow SHALL prompt the user for `user.name` and `user.email` during every login, using the tillandsias cache gitconfig values as defaults (falling back to `~/.gitconfig` host values).

#### Scenario: First-time login
- **WHEN** the cache gitconfig is empty
- **THEN** `read_git_identity` SHALL fall back to the host `~/.gitconfig`
- **AND** the prompt SHALL use those values as defaults
- **AND** the user pressing Enter SHALL accept the defaults and persist them to the cache gitconfig

#### Scenario: Name or email empty
- **WHEN** either prompt returns an empty string after default substitution
- **THEN** the flow SHALL abort with a user-facing error message "Name and email are required"

### Requirement: Token extraction + keyring persistence

After successful `gh auth login`, the flow SHALL extract the token from the container and persist it to the host OS keyring.

#### Scenario: Extraction
- **WHEN** `gh auth login` returns success
- **THEN** `podman exec <container> gh auth token` SHALL run with `stdin=null, stdout=piped, stderr=piped`
- **AND** the captured stdout SHALL be `trim()`-ed and wrapped in `zeroize::Zeroizing<String>`
- **AND** an empty token SHALL abort with "extracted empty token from gh — aborting"

#### Scenario: Username fetch (advisory)
- **WHEN** the token is non-empty
- **THEN** `podman exec <container> gh api user --jq .login` SHALL run to fetch the authenticated GitHub username
- **AND** failure SHALL be non-fatal (username is used only in the success message)

#### Scenario: Keyring write
- **WHEN** a valid token is extracted
- **THEN** `secrets::store_github_token(&token)` SHALL be called
- **AND** a failure SHALL abort the flow with a user-facing error

## REMOVED Requirements

### Requirement: `gh-auth-login.sh` host wrapper script

**Reason**: Replaced by the in-process Rust flow. The shell wrapper was a legacy hand-off from before the Rust binary existed as a full CLI.

**Migration**: The script file `gh-auth-login.sh` was deleted from the repository root. Users invoke `tillandsias --github-login` directly.

### Requirement: Host-native gh CLI strategy

**Reason**: Previously the spec listed three strategies in priority order: (1) run host gh, (2) run in-container gh with D-Bus, (3) no fallback. The host-gh strategy coupled Tillandsias's credential behavior to whatever `gh` the user had installed (potentially stale, wrong scope, non-existent), and meant the keyring entry could be written by a different process than the one that reads it. Single-strategy (ephemeral container only) makes the flow deterministic.

**Migration**: All logins go through the ephemeral container. Users without `gh` on the host are unaffected (gh is bundled in the git service image).

### Requirement: "Exec into running git service" shortcut

**Reason**: The shortcut tried to skip the ephemeral-container setup when a per-project `tillandsias-git-<project>` was already running. It caused two failures: (a) the long-running git service is `--read-only` with no tmpfs for `/home/git/.config`, so `gh auth login` hit `mkdir: read-only file system`, and (b) even when writes succeeded, the subsequent host-side `gh auth token` extraction + keyring store was skipped, leaving the token only inside the per-project container (lost on stop).

**Migration**: Removed entirely. Every login starts its own container regardless of other running git services.
