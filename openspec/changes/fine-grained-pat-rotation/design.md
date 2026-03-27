## Context

Tillandsias containers currently receive GitHub credentials via a read-only bind mount of `~/.cache/tillandsias/secrets/gh/hosts.yml` at `/home/forge/.config/gh/`. This file contains the user's full OAuth token (scopes: `repo`, `read:org`, `gist`) obtained via `gh auth login`. The `gh` CLI and git (via `gh auth setup-git`) use this token for all GitHub operations.

The problem: any process inside the container can read the mounted `hosts.yml` and obtain a token with full access to every repository the user owns. Coding agents, their tool calls, installed dependencies, and build scripts all run in the same container and can trivially read this file.

This design replaces the full OAuth token with short-lived, per-repository installation tokens minted by a GitHub App registered to the user's account.

## Goals / Non-Goals

**Goals:**
- Each container receives a GitHub token scoped to only its project's repository
- Tokens are short-lived (1 hour) and automatically rotated before expiry
- Token minting and rotation happen entirely on the host (never inside containers)
- Containers cannot escalate token scope or mint new tokens
- Existing users continue working via fallback if the GitHub App is not configured
- The user experience for setting up GitHub App auth is no harder than `gh auth login`

**Non-Goals:**
- Replacing the OAuth token for `gh` CLI operations on the host (that stays as-is)
- Supporting non-GitHub forges (GitLab, Bitbucket) in this change
- Encrypting tokens at rest on the host filesystem (the keyring already handles this for the App private key; the token files are ephemeral and scoped)
- Fine-grained PAT creation via API (not possible -- see API Research section)

## API Research

### Can fine-grained PATs be created programmatically?

**No.** GitHub does not expose a REST or GraphQL API endpoint for creating Personal Access Tokens (classic or fine-grained). PATs can only be created through the GitHub web UI at `github.com/settings/tokens`. The REST API endpoints under `/orgs/{org}/personal-access-tokens` are for organization admins to *review and revoke* tokens, not create them.

This rules out the original concept of the tray app minting fine-grained PATs via API.

**Source:** [Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens), [REST API endpoints for personal access tokens](https://docs.github.com/en/rest/orgs/personal-access-tokens), [Community discussion: Unable to create a Personal Access Token via API](https://github.com/orgs/community/discussions/148626)

### Can PATs be deleted/revoked programmatically?

**Partially.** The credential revocation endpoint (`POST /credentials/revoke`) accepts `ghp_` (classic) and `github_pat_` (fine-grained) token prefixes, but it is designed for third parties reporting exposed tokens, not for self-service lifecycle management. Organization admins can revoke member PATs via `POST /orgs/{org}/personal-access-tokens/{pat_id}` with `action: "revoke"`. There is no user-level self-revocation endpoint.

**Source:** [Revocation API](https://docs.github.com/en/rest/credentials/revoke)

### GitHub App installation tokens: the viable alternative

**Yes, fully programmable.** GitHub Apps can create installation access tokens via:

```
POST /app/installations/{installation_id}/access_tokens
Authorization: Bearer <JWT signed with App private key>
```

Key properties:
- **Expiry:** Fixed at **1 hour** (not configurable). After 1 hour the token returns HTTP 401.
- **Repository scoping:** The `repositories` or `repository_ids` body parameters restrict the token to specific repositories (up to 500).
- **Permission scoping:** The `permissions` body parameter restricts which permissions the token has. Cannot exceed what the App itself was granted during installation.
- **Creation rate limits:** Standard API rate limits apply (5,000 requests/hour for authenticated requests). Creating one token per project per hour is negligible.
- **No revocation needed:** Tokens expire automatically after 1 hour. There is a `DELETE /app/installations/{installation_id}/access_tokens` endpoint for early revocation if desired.

**Source:** [Generating an installation access token](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app), [REST API endpoints for GitHub Apps](https://docs.github.com/en/rest/apps/apps)

### GitHub App registration flow

Users can register a GitHub App from a manifest via a browser-based flow:

1. Tillandsias opens a browser to `https://github.com/settings/apps/new` with a POST body containing the App manifest (JSON with `name`, `permissions`, `default_events`, etc.)
2. The user reviews the manifest on GitHub and clicks "Create GitHub App"
3. GitHub redirects back to Tillandsias' local callback URL with a temporary `code`
4. Tillandsias exchanges the `code` via `POST /app-manifests/{code}/conversions` to receive the App ID, private key (PEM), webhook secret, and client secret
5. Tillandsias stores the private key in the OS keyring and the App ID in config

This is a one-time flow, similar in complexity to `gh auth login`. The App is registered to the user's personal account with minimal permissions (`contents: write`, `metadata: read`). The user then installs the App on their repositories (or all repositories).

**Source:** [Registering a GitHub App from a manifest](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest)

### gh CLI OAuth token scopes

The `gh auth login` flow requests these OAuth scopes by default:
- `repo` -- full control of all private and public repositories
- `read:org` -- read-only access to organization membership
- `gist` -- create and manage gists

The `repo` scope is the dangerous one: it grants read/write to every repository. This is what we want to avoid exposing to containers.

**Source:** [gh auth login manual](https://cli.github.com/manual/gh_auth_login), [Scopes for OAuth apps](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)

## Decisions

### D1: Use GitHub App installation tokens, not fine-grained PATs

**Choice:** GitHub App installation access tokens.

**Why:** Fine-grained PATs cannot be created via API (web UI only). GitHub App installation tokens can be created, scoped, and rotated programmatically. They expire after exactly 1 hour, which is ideal for our rotation model.

**Trade-off:** Requires a one-time GitHub App registration + installation flow. This adds UX complexity compared to the current `gh auth login`, but the security improvement is significant.

### D2: App manifest flow for registration

**Choice:** Use the GitHub App manifest flow to register a private GitHub App on the user's account.

The manifest requests minimal permissions:
```json
{
  "name": "Tillandsias Forge",
  "url": "https://github.com/8007342/tillandsias",
  "default_permissions": {
    "contents": "write",
    "metadata": "read"
  },
  "public": false
}
```

**Why:** The manifest flow is browser-based, requires no server infrastructure, and gives the user full visibility into what permissions the App requests. The App is private (only visible to the owner) and registered to their personal account.

### D3: Store App private key in OS keyring

**Choice:** The App's PEM private key is stored in the OS native keyring (same as the current OAuth token), keyed as `tillandsias/github-app-private-key`. The App ID and installation ID are stored in `~/.config/tillandsias/config.toml`.

**Why:** The private key is the root credential that can mint installation tokens. It must never be in a container-accessible path. The OS keyring (GNOME Keyring, macOS Keychain, Windows Credential Manager) provides encrypted-at-rest storage with session-locked access.

### D4: Token file at well-known path, mounted read-only

**Choice:** Each project's token is written to `~/.cache/tillandsias/secrets/<project>/github_token` on the host. This file is bind-mounted read-only into the container at `/run/secrets/github_token`.

**Why:**
- `/run/secrets/` is the conventional path for container secrets (Docker/Podman convention)
- Separate file per project prevents cross-project token access even if mounts leak
- Read-only mount prevents the container from modifying or deleting the token
- Atomic write-then-rename on the host ensures the container never reads a partial token

### D5: GIT_ASKPASS replaces gh auth setup-git

**Choice:** A shell script at `/usr/local/bin/git-askpass-tillandsias` inside the forge image that reads the token from `/run/secrets/github_token` and outputs it as a password. Git is configured via `GIT_ASKPASS` environment variable.

Script contents:
```bash
#!/bin/sh
# GIT_ASKPASS helper for Tillandsias forge containers.
# Reads a GitHub token from the mounted secrets path and returns it
# as the password when git asks for credentials.
case "$1" in
  *assword*) cat /run/secrets/github_token 2>/dev/null || echo "" ;;
  *sername*) echo "x-access-token" ;;
esac
```

**Why:**
- `GIT_ASKPASS` is a standard git mechanism, works with any git version
- `x-access-token` is the username GitHub expects for App installation tokens
- No dependency on `gh` CLI for git authentication (the `gh` CLI can still be used for non-git operations via separate auth)
- The script is baked into the image, not mounted -- containers cannot modify it

### D6: Rotation at 55 minutes, 1-hour token lifetime

**Choice:** Installation tokens have a fixed 1-hour expiry (set by GitHub, not configurable). The rotation daemon mints a new token at the 55-minute mark, giving a 5-minute overlap where both old and new tokens are valid.

**Why:** The 5-minute overlap ensures that any in-flight git operation (large push, clone) that started before rotation has time to complete with the old token while new operations use the new token. Because the token file is atomically replaced, new reads immediately get the new token.

### D7: Rotation daemon as a tokio task in the event loop

**Choice:** The rotation daemon is a `tokio::spawn`ed task that:
1. Maintains a `HashMap<String, TokenState>` mapping project names to their current token state (token string, minted_at timestamp, installation_id)
2. Uses `tokio::time::interval(Duration::from_secs(60))` to check all tracked projects every minute
3. Mints a new token when: (a) a project is newly tracked, or (b) the current token is older than 55 minutes
4. Writes the token to disk atomically (write to `.tmp`, rename to final path)
5. Removes tracking when notified that a container stopped

Communication with the main event loop uses an `mpsc` channel:
- Main loop sends `TokenCommand::Track { project_name, repo_full_name }` when a container starts
- Main loop sends `TokenCommand::Untrack { project_name }` when a container stops
- Rotation task sends `TokenEvent::Minted { project_name }` and `TokenEvent::Failed { project_name, reason }` back for logging/status

**Why:** Fits naturally into the existing event-driven architecture. The event loop already manages container lifecycle -- it simply sends Track/Untrack commands at the right moments. The rotation task is fully async, uses no blocking I/O, and can be tested independently.

### D8: Exponential backoff on mint failure

**Choice:** If minting fails, retry with exponential backoff: 5s, 10s, 20s, 40s, capped at 60s. After 5 consecutive failures, log an error and fall back to OAuth mount for that project (if available).

**Why:** Transient network issues or GitHub API blips should not break the user's workflow. The old token remains valid until its 1-hour expiry, so there is time to retry. If the API is persistently down, the fallback ensures the container keeps working.

### D9: Fallback to OAuth token mount

**Choice:** If the GitHub App is not configured (no App ID in config, no private key in keyring) OR if token minting fails after retries, fall back to the current approach: write `hosts.yml` from the keyring OAuth token and mount it at `/home/forge/.config/gh:ro`.

**Why:** Backwards compatibility. Users who have not set up the GitHub App flow should not lose functionality. The fallback is the current production behavior and is strictly less secure, but it works.

### D10: Repository name resolution

**Choice:** The rotation daemon needs the repository's full name (`owner/repo`) to scope the installation token. This is resolved by:
1. Reading the `origin` remote URL from the project's `.git/config`
2. Parsing `github.com/<owner>/<repo>` from the URL (HTTPS or SSH format)
3. Caching the result for the lifetime of the container

**Why:** The project path (e.g., `~/src/tillandsias`) does not reliably map to a GitHub repository name (the directory name might differ from the repo name). Reading the git remote is the only authoritative source.

## Token Lifecycle

```
User clicks "Attach Here" for project "tetris"
    |
    v
[1] handlers.rs resolves repo: git remote origin -> "alice/tetris"
    |
    v
[2] handlers.rs sends TokenCommand::Track { project: "tetris", repo: "alice/tetris" }
    to rotation daemon
    |
    v
[3] Rotation daemon mints installation token:
    POST /app/installations/{id}/access_tokens
    Body: { "repositories": ["tetris"], "permissions": { "contents": "write", "metadata": "read" } }
    Response: { "token": "ghs_xxxx", "expires_at": "2026-03-26T15:00:00Z" }
    |
    v
[4] Daemon writes token to ~/.cache/tillandsias/secrets/tetris/github_token
    (atomic: write .tmp, rename)
    |
    v
[5] handlers.rs launches container with:
    -v ~/.cache/tillandsias/secrets/tetris/github_token:/run/secrets/github_token:ro
    -e GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias
    |
    v
[6] Inside container: git push origin main
    -> git calls GIT_ASKPASS for credentials
    -> script returns username="x-access-token", password=<token from /run/secrets/github_token>
    -> push succeeds (token has contents:write on alice/tetris)
    |
    v
[7] 55 minutes later: rotation daemon mints a new token
    -> writes to same path atomically
    -> old token still valid for 5 more minutes
    -> next git operation uses new token transparently
    |
    v
[8] User stops container (or container exits)
    -> event_loop sends TokenCommand::Untrack { project: "tetris" }
    -> rotation daemon stops tracking, deletes token file
    -> old token expires naturally after 1 hour (no explicit revocation needed)
```

## GIT_ASKPASS Approach

The `GIT_ASKPASS` mechanism is a standard git feature. When git needs credentials for an HTTPS remote, it:

1. Checks `GIT_ASKPASS` environment variable (takes precedence over credential helpers)
2. Calls the script twice: once asking for "Username", once asking for "Password"
3. Uses the responses as HTTP Basic Auth credentials

For GitHub App installation tokens, the username must be `x-access-token` and the password is the token itself. This is documented by GitHub as the way to use installation tokens with git.

**Advantages over `gh auth setup-git`:**
- No `gh` CLI dependency for git operations
- No `hosts.yml` file needed (eliminates the OAuth token mount entirely)
- Works with any git client, not just git-via-gh
- The script is a static file in the image, not a dynamic configuration

**Interaction with existing gh CLI usage inside containers:**
- `gh` CLI operations that don't involve git (e.g., `gh issue list`) still use `hosts.yml` if it exists, or can be configured to use the token file via `GH_TOKEN` env var
- For Phase 1-3, `hosts.yml` is still mounted as fallback for `gh` CLI operations
- In Phase 4, `GH_TOKEN` can point to the same `/run/secrets/github_token` file, making `gh` CLI use the scoped token too

## Rotation Daemon Architecture

```
                    +--------------------------+
                    |   Main Event Loop        |
                    |   (event_loop.rs)        |
                    |                          |
  container start --+--> TokenCommand::Track   |
  container stop  --+--> TokenCommand::Untrack |
                    +-----------+--------------+
                                |
                         mpsc channel
                                |
                    +-----------v--------------+
                    |   Rotation Daemon        |
                    |   (token_rotation.rs)    |
                    |                          |
                    |  HashMap<project, state> |
                    |                          |
                    |  every 60s:              |
                    |    for each project:     |
                    |      if age > 55min:     |
                    |        mint new token    |
                    |        atomic write      |
                    |                          |
                    |  on Track:               |
                    |    mint immediately       |
                    |    insert into map       |
                    |                          |
                    |  on Untrack:             |
                    |    remove from map       |
                    |    delete token file     |
                    +-----------+--------------+
                                |
                         mpsc channel (events back)
                                |
                    +-----------v--------------+
                    |   Main Event Loop        |
                    |   (logs, error display)  |
                    +--------------------------+
```

**TokenState struct:**
```
project_name: String
repo_full_name: String        // "owner/repo"
token: String                 // current installation token
minted_at: Instant            // when the current token was minted
consecutive_failures: u32     // for exponential backoff
```

**JWT generation for App authentication:**
The rotation daemon signs JWTs using the App's PEM private key (retrieved from the OS keyring). JWTs are short-lived (max 10 minutes per GitHub spec) and used only to authenticate the `POST /app/installations/{id}/access_tokens` request. The `jsonwebtoken` crate handles RS256 signing.

## Failure Modes and Fallback

| Failure | Impact | Recovery |
|---------|--------|----------|
| GitHub API unreachable | Cannot mint new tokens | Existing token valid until expiry; exponential backoff retries; fall back to OAuth after 5 failures |
| App private key missing from keyring | Cannot sign JWTs | Fall back to OAuth mount immediately; warn user to re-run GitHub App setup |
| Installation ID unknown | Cannot call token endpoint | Resolve installation ID from `GET /app/installations`; cache in config.toml |
| Repository not accessible to App | Mint returns 422 | Log error with actionable message ("Install the Tillandsias GitHub App on repository X"); fall back to OAuth for that project |
| Token file write fails (disk full, permissions) | Container has stale or no token | Log error; container falls back to `hosts.yml` mount if present |
| Atomic rename fails | Partial write visible | Use write-to-tmpfile + rename pattern; tmpfile is in same directory (same filesystem) to guarantee atomic rename |
| Container starts before first token is ready | No token at mount path | Rotation daemon mints synchronously (awaited) for new Track commands before returning to the event loop; container launch waits for first mint |

## Security Analysis

### What is protected

- **Cross-repository access:** A compromised `tetris` container cannot access `cool-app`'s repository. The token is scoped to a single repository.
- **Scope escalation:** Installation tokens cannot exceed the App's registered permissions (`contents: write`, `metadata: read`). Even if the user's OAuth token has `admin:org` scope, the installation token does not.
- **Token longevity:** Tokens expire after 1 hour automatically. A stolen token has a maximum useful lifetime of 60 minutes, compared to the OAuth token which never expires unless manually revoked.
- **Token minting from container:** Containers do not have the App's private key (stored in host keyring) and cannot sign JWTs. They cannot mint new tokens or extend existing ones.

### What is NOT protected

- **Access within the scoped repository:** A compromised container can still push malicious code, delete branches, or force-push to the repository the token is scoped to. `contents: write` is broad within a single repo.
- **Token exfiltration within lifetime:** A stolen token works for up to 60 minutes. This is better than an indefinite OAuth token but not zero-risk.
- **Host compromise:** If the host is compromised, the attacker can read the keyring (App private key) and mint tokens for any repository. This is no worse than the current OAuth approach (compromised host = compromised OAuth token).
- **Side-channel via git operations:** A malicious process can observe git operations (remote URLs, branch names) even without the token, by watching network traffic or filesystem events inside the container.

### Comparison to current approach

| Risk | Current (OAuth mount) | After (App installation tokens) |
|------|----------------------|----------------------------------|
| Token scope | All repos (repo scope) | Single repository |
| Token lifetime | Indefinite | 1 hour |
| Token minting by container | N/A (token is static) | Impossible (no private key) |
| Cross-project access | Yes (same token) | No |
| Organization data access | Yes (read:org scope) | No |
| Gist access | Yes (gist scope) | No |

## Migration Path

### Phase 1: GIT_ASKPASS infrastructure (no API calls)
- Add `git-askpass-tillandsias` script to forge image
- Add `GIT_ASKPASS` env var to container launch args
- Add token file path infrastructure (`~/.cache/tillandsias/secrets/<project>/github_token`)
- Write the existing OAuth token to the token file path (same token, new delivery mechanism)
- Containers work identically but read credentials via GIT_ASKPASS instead of hosts.yml
- hosts.yml mount remains as fallback for gh CLI operations

### Phase 2: GitHub App registration + token minting
- Implement App manifest registration flow (browser-based)
- Store App credentials in keyring
- Implement JWT signing and `POST /app/installations/{id}/access_tokens`
- Mint real scoped tokens and write them to the token file path
- Fall back to OAuth token when App is not configured

### Phase 3: Rotation daemon
- Implement the rotation daemon as a tokio task
- Integrate Track/Untrack commands with the event loop
- Add exponential backoff retry logic
- Add tray status indicator for token health

### Phase 4: Remove OAuth mount
- Remove `hosts.yml` mount from container launch args
- Remove `gh auth setup-git` dependency
- Set `GH_TOKEN` env var pointing to `/run/secrets/github_token` for gh CLI operations inside containers
- Keep OAuth token in keyring for host-side operations (remote repo listing, cloning)
- Migration guide for existing users

## Open Questions

1. **Should the GitHub App be shared or per-user?** A shared App (registered by the Tillandsias project) would simplify onboarding (user just installs it, no manifest flow) but requires a webhook server and centralized App credentials. A per-user App (via manifest flow) requires no server infrastructure but adds a one-time setup step. **Current decision: per-user via manifest flow.** Revisit if user feedback indicates the setup is too complex.

2. **What about repositories the App is not installed on?** The user may have repos from organizations or other accounts where they cannot install the App. These repos would fall back to the OAuth token. The tray menu should indicate which projects use scoped tokens vs. fallback.

3. **Should we revoke tokens on container stop or let them expire?** Early revocation (`DELETE /app/installations/{id}/access_tokens`) is possible but adds an API call per container stop. Since tokens expire in 1 hour anyway, letting them expire naturally is simpler and more resilient to network issues. **Current decision: let them expire.**
