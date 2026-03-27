## Why

Today, every forge and maintenance terminal container gets the user's full GitHub OAuth token (with `repo`, `read:org`, and `gist` scopes) mounted as `~/.config/gh/hosts.yml:ro`. This token grants unrestricted read/write access to **all** of the user's repositories, plus organization data and gist management.

Any process running inside the container -- the coding agent, language servers, build tools, arbitrary npm/pip dependencies -- can read that file and exfiltrate the token. A compromised or malicious tool gains access to the user's entire GitHub account, not just the project the container was created for.

The risk is concrete: AI coding agents execute arbitrary code suggested by LLMs, install packages from public registries, and run user-authored scripts. The blast radius of a compromised container should be **one repository**, not the entire account.

## What Changes

- **GitHub App-based token minting on host** -- The tray app (running on the host with the user's GitHub App private key in the OS keyring) mints short-lived installation access tokens scoped to a single repository. These tokens replace the full OAuth token inside containers.
- **Per-project tokens** -- Each running container receives a token scoped to only its project's repository. If `tetris` and `cool-app` are running simultaneously, each has a different token that can only access its own repo.
- **Token rotation daemon** -- A tokio task on the host mints tokens when containers start, refreshes them every 55 minutes (installation tokens expire after 1 hour), and lets them expire naturally when containers stop.
- **GIT_ASKPASS injection** -- Containers use a `GIT_ASKPASS` helper script that reads from `/run/secrets/github_token` instead of relying on `gh auth setup-git` and the `hosts.yml` mount.
- **Fallback** -- If token minting fails (no internet, no GitHub App configured, API error), the current OAuth mount approach is used with a warning logged.

## Capabilities

### New Capabilities
- `token-rotation`: Host-side daemon that mints, rotates, and expires per-project GitHub tokens
- `git-askpass`: Container-side credential helper reading from mounted token file

### Modified Capabilities
- `environment-runtime`: Container launch uses token file mount + GIT_ASKPASS instead of hosts.yml mount
- `tray-app`: GitHub App registration flow replaces or supplements current `gh auth login` flow

## Impact

- **New files**: `src-tauri/src/token_rotation.rs` (rotation daemon), `src-tauri/src/github_app.rs` (App registration + token minting), container-side `git-askpass.sh` script baked into forge image
- **Modified files**: `src-tauri/src/handlers.rs` (mount token file instead of hosts.yml), `src-tauri/src/runner.rs` (same), `src-tauri/src/secrets.rs` (App private key storage alongside OAuth token), `src-tauri/src/event_loop.rs` (new select branch for rotation timer), `src-tauri/src/github.rs` (use App token for repo list/clone operations)
- **User-visible change**: One-time GitHub App installation flow (browser-based, similar to current `gh auth login`). After that, containers get scoped tokens automatically.
- **Migration**: Existing users keep working via fallback. The old OAuth mount is removed only in Phase 4, after the GitHub App flow is proven stable.
