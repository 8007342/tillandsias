## Phase 1: GIT_ASKPASS + Token File Infrastructure

This phase changes the credential delivery mechanism without changing what credentials are delivered. Containers switch from reading `hosts.yml` to reading a token file via `GIT_ASKPASS`. The token content is still the OAuth token.

- [ ] 1.1 Add `git-askpass-tillandsias` script to forge image (`images/default/git-askpass-tillandsias`). Script reads `/run/secrets/github_token` and returns username=`x-access-token`, password=`<token>`. Must be executable, owned by root, not writable by forge user.
- [ ] 1.2 Update Nix image build (`flake.nix`) to include the `git-askpass-tillandsias` script at `/usr/local/bin/git-askpass-tillandsias`.
- [ ] 1.3 Create `token_file.rs` module with functions: `token_dir(project: &str) -> PathBuf` (returns `~/.cache/tillandsias/secrets/<project>/`), `write_token_file(project: &str, token: &str) -> Result<()>` (atomic write-then-rename), `delete_token_file(project: &str)`.
- [ ] 1.4 Update `handlers.rs` `build_run_args()` to add: `-v <host_token_path>:/run/secrets/github_token:ro` and `-e GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias`. Write the OAuth token (from keyring) to the token file before container launch.
- [ ] 1.5 Update `runner.rs` `build_run_args()` with the same token file mount and GIT_ASKPASS env var for CLI mode.
- [ ] 1.6 Update `handlers.rs` maintenance terminal (`handle_terminal`, `handle_root_terminal`) podman command strings with the same mount and env var.
- [ ] 1.7 Keep existing `hosts.yml` mount alongside the new token file mount (dual-path: git uses GIT_ASKPASS, `gh` CLI uses hosts.yml).
- [ ] 1.8 Add unit tests for `token_file.rs`: atomic write creates file, write-then-rename leaves no .tmp files, delete removes file and parent dir if empty.
- [ ] 1.9 Manual test: build forge image, launch container, verify `git push` works via GIT_ASKPASS (check git trace output shows askpass being called).

## Phase 2: GitHub App Registration + Token Minting

This phase adds the ability to register a GitHub App and mint real scoped installation tokens. The OAuth fallback remains for users who skip App setup.

- [ ] 2.1 Add `jsonwebtoken` and `ring` (or `rsa`) crate dependencies to `src-tauri/Cargo.toml` for RS256 JWT signing.
- [ ] 2.2 Create `github_app.rs` module with: `generate_jwt(app_id: u64, private_key_pem: &str) -> Result<String>` -- signs a JWT with iat, exp (10 min), iss (app_id) claims using RS256.
- [ ] 2.3 Add to `github_app.rs`: `mint_installation_token(installation_id: u64, jwt: &str, repo_name: &str) -> Result<InstallationToken>` -- calls `POST /app/installations/{id}/access_tokens` with `repositories: [repo_name]` and `permissions: { contents: "write", metadata: "read" }`. Returns token string and expiry timestamp.
- [ ] 2.4 Add to `github_app.rs`: `list_installations(jwt: &str) -> Result<Vec<Installation>>` -- calls `GET /app/installations` to discover installation IDs. Needed for initial setup and when installation ID is not cached.
- [ ] 2.5 Add to `github_app.rs`: `resolve_repo_name(project_path: &Path) -> Option<String>` -- reads `.git/config`, parses `origin` remote URL, extracts `owner/repo`. Handles both HTTPS (`https://github.com/owner/repo.git`) and SSH (`git@github.com:owner/repo.git`) formats.
- [ ] 2.6 Create `github_app_setup.rs` module with the App manifest registration flow: build manifest JSON, open browser to `https://github.com/settings/apps/new`, handle redirect callback (local HTTP server on ephemeral port), exchange temporary code via `POST /app-manifests/{code}/conversions`, store App ID + private key.
- [ ] 2.7 Add keyring entries in `secrets.rs`: `store_github_app_key(pem: &str)`, `retrieve_github_app_key() -> Result<Option<String>>`. Key: `tillandsias/github-app-private-key`.
- [ ] 2.8 Add config fields to `config.toml` schema in `tillandsias-core`: `[github_app]` section with `app_id`, `installation_id` (optional, auto-discovered), `enabled` (bool, default false).
- [ ] 2.9 Add "Set Up GitHub App" menu item to tray Settings submenu. Triggers the manifest flow. On success, sets `github_app.enabled = true` and `github_app.app_id`.
- [ ] 2.10 Update container launch path: if GitHub App is configured (`enabled = true`, private key in keyring), mint a scoped installation token instead of writing the OAuth token to the token file. Fall back to OAuth on any error.
- [ ] 2.11 Add integration test (requires GitHub App credentials, can be skipped in CI): mint token, verify it can access the target repo, verify it cannot access other repos.

## Phase 3: Rotation Daemon

This phase adds automatic token refresh so long-running containers always have valid credentials.

- [ ] 3.1 Create `token_rotation.rs` module with `TokenCommand` enum (`Track { project, repo_full_name }`, `Untrack { project }`), `TokenEvent` enum (`Minted { project }`, `Failed { project, reason }`), and `TokenState` struct.
- [ ] 3.2 Implement `run_rotation_daemon(cmd_rx, event_tx, app_id, installation_id)` async function: maintains `HashMap<String, TokenState>`, checks token ages every 60 seconds via `tokio::time::interval`, mints new tokens when age > 55 minutes.
- [ ] 3.3 Add exponential backoff retry logic: on mint failure, retry at 5s, 10s, 20s, 40s, 60s intervals. After 5 consecutive failures for a project, send `TokenEvent::Failed` and stop retrying until the next interval tick.
- [ ] 3.4 Implement atomic token file write in the daemon: write to `<path>.tmp`, `tokio::fs::rename` to final path. Handle rename failure (log, retry next cycle).
- [ ] 3.5 Add `token_cmd_tx` channel to `event_loop.rs`. On `MenuCommand::AttachHere` success, send `TokenCommand::Track`. On container stop (podman event), send `TokenCommand::Untrack`.
- [ ] 3.6 Add `token_event_rx` to the `tokio::select!` loop in `event_loop.rs`. Log minted/failed events. Optionally update `TrayState` with per-project token health for future status display.
- [ ] 3.7 Spawn the rotation daemon in `main.rs` alongside scanner and podman event tasks. Pass the `app_id` and `installation_id` from config (or `None` if App not configured -- daemon is a no-op).
- [ ] 3.8 Handle the first-mint-before-launch synchronization: when `TokenCommand::Track` is received for a new project, the daemon mints the token immediately (not waiting for the next interval tick). The `Track` command includes a oneshot channel for the caller to await the result before proceeding with container launch.
- [ ] 3.9 Add token file cleanup on Untrack: delete `~/.cache/tillandsias/secrets/<project>/github_token`. Best-effort, don't fail if file is already gone.
- [ ] 3.10 Add unit tests: mock the GitHub API (or use a trait-based HTTP client), verify rotation timing, verify backoff behavior, verify Track/Untrack lifecycle.

## Phase 4: Remove OAuth Mount + Migration

This phase removes the legacy `hosts.yml` mount and completes the transition to scoped tokens.

- [ ] 4.1 Remove `hosts.yml` mount (`-v secrets/gh:/home/forge/.config/gh:ro`) from `handlers.rs` `build_run_args()` for projects with active scoped tokens.
- [ ] 4.2 Remove `hosts.yml` mount from `runner.rs` `build_run_args()` (CLI mode).
- [ ] 4.3 Remove `hosts.yml` mount from maintenance terminal podman command strings in `handlers.rs`.
- [ ] 4.4 Add `-e GH_TOKEN=$(cat /run/secrets/github_token)` to container launch args so the `gh` CLI inside containers uses the scoped token instead of `hosts.yml`. (Note: `GH_TOKEN` env var takes precedence over `hosts.yml` in the gh CLI.)
- [ ] 4.5 Keep the OAuth token in the host keyring for host-side operations: `github.rs` `fetch_repos()` and `clone_repo()` still use it (they run containers that need broad repo access for listing/cloning).
- [ ] 4.6 Update `github.rs` `clone_repo()` to use a scoped installation token for the specific repository being cloned (instead of the full OAuth token). The `fetch_repos()` operation still needs the OAuth token since it lists all repos.
- [ ] 4.7 Remove `crate::secrets::write_hosts_yml_from_keyring()` calls from container launch paths (keep it for `github.rs` operations that still need it).
- [ ] 4.8 Add version migration: on first launch after upgrade, detect `github_app.enabled = true` and log that OAuth mount has been removed. No user action needed.
- [ ] 4.9 Final manual test: launch forge container, verify git push/pull work, verify `gh` CLI works with scoped token, verify no `hosts.yml` is mounted (check with `mount` or `df` inside container).
