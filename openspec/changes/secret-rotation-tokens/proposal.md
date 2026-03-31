## Why

Today, Tillandsias injects GitHub credentials into containers by writing the user's full OAuth token to `~/.cache/tillandsias/secrets/gh/hosts.yml` and bind-mounting it read-only at `/home/forge/.config/gh/`. This token has `repo`, `read:org`, and `gist` scopes -- full read/write access to every repository the user owns, plus organization data.

The existing `fine-grained-pat-rotation` OpenSpec change designs a long-term solution using GitHub App installation tokens. That change is correct but complex: it requires a one-time GitHub App registration flow, JWT signing infrastructure, and a rotation daemon. It is the right destination but represents months of implementation work.

This change designs an **intermediate step** that dramatically improves security with much less complexity: move the OAuth token from an environment variable / hosts.yml mount to a tmpfs-backed token file at `/run/secrets/github_token`, served via `GIT_ASKPASS`. The token itself doesn't change (it's still the OAuth token), but the delivery mechanism eliminates several attack vectors.

**Why this is better than the current approach:**

| Attack vector | Current (hosts.yml mount) | After (tmpfs token file) |
|---------------|--------------------------|--------------------------|
| `/proc/*/environ` reads token | Yes (if passed as env var) | No (token is in a file, not env) |
| Token persists on disk | Yes (`hosts.yml` in `~/.cache`) | No (tmpfs = RAM only, never written to disk) |
| Token survives container stop | Yes (file persists on host) | No (file deleted on container stop, immediately) |
| Token survives app exit | Yes (file persists on host) | No (all token files deleted on app exit) |
| Other processes see token | Yes (`/proc/*/environ` or file read) | Harder (file at `/run/secrets/` with 0600 perms on tmpfs) |

This change is a stepping stone toward the full `fine-grained-pat-rotation` design. It implements Phase 1 of that design (GIT_ASKPASS + token file infrastructure) with the addition of tmpfs-backed storage and aggressive cleanup.

## What Changes

- **Token file on tmpfs**: Before container launch, write the OAuth token to `$XDG_RUNTIME_DIR/tillandsias/tokens/<container-id>/github_token` (RAM-backed tmpfs on Linux, equivalent on macOS/Windows). Never written to persistent storage.
- **Read-only mount at `/run/secrets/github_token`**: The token file is bind-mounted into the container read-only.
- **GIT_ASKPASS helper**: A script baked into the forge image reads `/run/secrets/github_token` and provides it to git as a password. Username is `x-access-token` (works for both OAuth and future App tokens).
- **Host-side refresh task**: A tokio task writes a fresh copy of the token every 55 minutes (same token, rotation signal for future App token integration). This is a no-op for OAuth tokens but establishes the infrastructure.
- **Aggressive cleanup**: Token file deleted on container stop. All token files deleted on app exit. `Drop` guard ensures cleanup even on panic.
- **Accountability logging**: Every token operation is logged to the accountability window (`--log-secret-management`) with spec links and cheatsheet references.

## Capabilities

### New Capabilities
- `secret-rotation`: Host-side token file management with tmpfs storage, mount, refresh, and cleanup
- `git-askpass`: Container-side credential helper reading from mounted token file

### Modified Capabilities
- `environment-runtime`: Container launch adds token file mount + `GIT_ASKPASS` env var
- `secrets-management`: Token delivery moves from `hosts.yml` to `/run/secrets/` tmpfs file

## Impact

- **New files**: `src-tauri/src/token_file.rs` (token file write/delete/cleanup), forge image `git-askpass-tillandsias` script
- **Modified files**: `src-tauri/src/handlers.rs` (add token file mount), `src-tauri/src/launch.rs` (new mount source), `src-tauri/src/runner.rs` (CLI mode token file), `src-tauri/src/event_loop.rs` (cleanup on container stop), `src-tauri/src/main.rs` (cleanup on exit), `crates/tillandsias-core/src/container_profile.rs` (new `SecretKind::GitHubToken` variant), `flake.nix` (bake GIT_ASKPASS script into image)
- **User-visible change**: None (containers work identically). The `--log-secret-management` accountability window reveals the new mechanism.
- **Dependency on**: `logging-accountability-framework` (for accountability-tagged logging). Can be implemented without it, but accountability output will be absent until the logging change lands.
