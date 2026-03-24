## Context

Tillandsias already scans `~/src/` for local projects and displays them in the tray menu. After `gh auth login`, the user's GitHub identity is stored in `~/.cache/tillandsias/secrets/gh/hosts.yml`. The forge container image includes the `gh` CLI. The app already spawns podman containers for various operations (attach, terminal, GitHub auth).

## Goals / Non-Goals

**Goals:**
- List remote GitHub repos not already cloned locally
- Clone selected repo into `~/src/<name>` via forge container
- Trigger scanner rescan after clone so the project appears immediately
- Rename "GitHub Login" to "GitHub Login Refresh" when authenticated

**Non-Goals:**
- Fetching repos from GitLab, Bitbucket, or other forges (GitHub only for now)
- Paginating hundreds of repos (initial implementation fetches up to 100)
- Showing private/public distinction in the menu
- Managing SSH keys (gh handles auth via token)

## Decisions

### Decision 1: Fetch repos via `gh` CLI in forge container

**Choice**: Run `podman run --rm <forge-image> gh repo list --json name,url --limit 100` with the GitHub secrets mounted, parse the JSON output.

**Alternatives considered**:
- *GitHub REST API directly*: Would need to extract the token from `hosts.yml`, manage HTTP client, handle pagination. The `gh` CLI handles all of this.
- *GraphQL API*: More powerful but same extraction problem. Overkill for a list.

**Rationale**: The forge image already has `gh` installed and the secrets are already mounted for other operations. One podman command gives us structured JSON. No new dependencies needed.

### Decision 2: Cache repo list in TrayState

**Choice**: Store the remote repo list in `TrayState` with a timestamp. Refresh when:
- The Settings submenu is opened and the cache is older than 5 minutes
- After a successful `gh auth login` / refresh
- On explicit user action (future: refresh button)

**Rationale**: Fetching on every menu open would be slow (podman startup + GitHub API). Caching with a reasonable TTL gives snappy UX. The list doesn't change frequently.

### Decision 3: Filter by directory name in `~/src/`

**Choice**: A repo is "remote-only" if no directory named `<repo-name>` exists under the scanner's watched directory (typically `~/src/`). Simple name-based matching, not URL-based.

**Rationale**: Users clone repos as their simple name (`tillandsias`, not `8007342/tillandsias`). Directory name matching is fast and correct for the common case. Edge cases (renamed dirs, forks with same name) are acceptable trade-offs.

### Decision 4: Clone into scanner watched directory

**Choice**: Clone target is `<scan_dir>/<repo-name>` (e.g., `~/src/tillandsias`). The scanner's filesystem watcher automatically detects the new directory and triggers a project rescan.

**Rationale**: No manual rescan trigger needed — the scanner is already watching `~/src/` for changes. The new project appears in the menu within seconds of clone completion.

### Decision 5: GitHub Login label swap

**Choice**: In `menu.rs`, check `needs_github_login()`:
- `true` → label is "GitHub Login"
- `false` → label is "GitHub Login Refresh"

Same menu ID, same handler. Just a label change.

## Risks / Trade-offs

- **[100 repo limit]** → Acceptable for v0.1. Most users have fewer than 100 repos. Can add pagination/search later.
- **[Podman startup latency for list fetch]** → Mitigated by caching. First fetch takes 2-3s, subsequent reads from cache.
- **[Name collision]** → If user has repos with same name from different orgs, only the first match is filtered. Acceptable edge case.
- **[Clone failures]** → Large repos or network issues. Handler should report failure in a notification or tray status, not silently fail.
