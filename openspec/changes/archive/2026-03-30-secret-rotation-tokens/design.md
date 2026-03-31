## Context

Tillandsias containers currently receive GitHub credentials via a read-only bind mount of `~/.cache/tillandsias/secrets/gh/hosts.yml` at `/home/forge/.config/gh/`. This file contains the user's full OAuth token and is written to persistent storage by `secrets::write_hosts_yml_from_keyring()` before every container launch.

The `fine-grained-pat-rotation` OpenSpec change designs a complete solution using GitHub App installation tokens. This change implements the intermediate step: same OAuth token, better delivery mechanism. The token moves from a persistent file to a tmpfs-backed file that exists only in RAM and is aggressively cleaned up.

## API Research

### Can an OAuth token create fine-grained PATs via API?

**No.** GitHub does not expose any REST or GraphQL endpoint for creating Personal Access Tokens (classic or fine-grained). PATs can only be created through the GitHub web UI at `github.com/settings/tokens`. The REST API endpoints under `/orgs/{org}/personal-access-tokens` are for organization admins to review and revoke tokens, not create them. This has been a persistent feature request since fine-grained PATs launched (GitHub Community Discussion #120437) with no API resolution as of March 2026.

Source: [Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens), [REST API endpoints for personal access tokens](https://docs.github.com/en/rest/orgs/personal-access-tokens), [Community Discussion #120437](https://github.com/orgs/community/discussions/120437)

### Can an OAuth token create temporary credentials via any other mechanism?

**No practical mechanism exists.** The OAuth token can authenticate to the GitHub API, but there is no endpoint that accepts an OAuth token and returns a new, scoped, short-lived credential. The only mechanism for programmatic short-lived token creation is GitHub App installation tokens (see `fine-grained-pat-rotation` design), which require a registered GitHub App with a private key -- not derivable from an OAuth token.

### What about `gh auth token` + `GIT_ASKPASS` served from a host-side process?

**This is the practical approach.** `gh auth token` outputs the current OAuth token to stdout. The token can be written to a tmpfs-backed file and served to the container via `GIT_ASKPASS`. The container never needs `gh` installed or configured -- it just reads the token file when git asks for credentials.

Source: [gh auth token](https://cli.github.com/manual/gh_auth_token), [Dev Containers GIT_ASKPASS discussion (microsoft/vscode-remote-release#8883)](https://github.com/microsoft/vscode-remote-release/issues/8883)

### Why is `/proc/*/environ` a real threat?

Environment variables are visible to any process that can read `/proc/<pid>/environ`. Inside a container, this means any process running as the same user can read the environment of any other process. AI coding agents execute arbitrary code, install packages, and run build scripts -- all of which could read `/proc/self/environ` or `/proc/1/environ` to extract tokens passed as environment variables. Security tools like Falco specifically detect this pattern as a credential exfiltration attempt.

Source: [CyberArk: Environment Variables Don't Keep Secrets](https://developer.cyberark.com/blog/environment-variables-dont-keep-secrets-best-practices-for-plugging-application-credential-leaks/), [Trend Micro: Hidden Danger of Environment Variables](https://www.trendmicro.com/en_us/research/22/h/analyzing-hidden-danger-of-environment-variables-for-keeping-secrets.html), [Falco rules #200](https://github.com/falcosecurity/rules/issues/200)

### Why tmpfs?

`$XDG_RUNTIME_DIR` (typically `/run/user/<uid>/`) is mandated by the XDG Base Directory Specification to be a tmpfs (RAM-backed filesystem) owned by the user with mode 0700. Data written here:
- Never touches persistent storage (SSD/HDD)
- Is automatically cleaned up when the user's session ends
- Cannot survive a reboot
- Is invisible to other users

Docker and Podman use `/run/secrets/` (also tmpfs) as the conventional path for container secrets. This is a well-established pattern: secrets exist only in memory during container runtime and are automatically removed when the container exits.

Source: [Docker tmpfs mounts](https://docs.docker.com/engine/storage/tmpfs/), [Docker Secrets management](https://docs.docker.com/engine/swarm/secrets/), [XDG Runtime Dir specification](https://wiki.alpinelinux.org/wiki/XDG_RUNTIME_DIR)

## Goals / Non-Goals

**Goals:**
- Token is never written to persistent storage (disk) by Tillandsias
- Token is not in the container's initial environment (`/proc/*/environ`)
- Token file is on tmpfs (RAM only) with 0600 permissions
- Token file is deleted immediately on container stop
- All token files are deleted on app exit (including panic)
- GIT_ASKPASS mechanism works for both OAuth tokens now and App installation tokens later
- Every token operation is logged to the accountability window
- Existing `hosts.yml` mount is preserved as fallback for `gh` CLI operations inside containers

**Non-Goals:**
- Replacing the OAuth token with scoped tokens (that is `fine-grained-pat-rotation`)
- Encrypting the token file (tmpfs is already RAM-only; encryption would add complexity with minimal benefit since the threat model is persistent storage exposure)
- Supporting non-GitHub forges (GitLab, Bitbucket)
- Modifying the forge container image beyond adding the `git-askpass-tillandsias` script

## Decisions

### D1: Token file location on host

**Choice:** `$XDG_RUNTIME_DIR/tillandsias/tokens/<container-name>/github_token`

Example: `/run/user/1000/tillandsias/tokens/tillandsias-tetris-aeranthos/github_token`

**Why:**
- `$XDG_RUNTIME_DIR` is guaranteed tmpfs on systemd-based systems (Fedora, Ubuntu, Arch, etc.)
- Per-container subdirectory prevents token leakage between projects
- Path is predictable for cleanup
- On macOS, fallback to `$TMPDIR/tillandsias/tokens/...` (also tmpfs-backed by default on macOS)
- On Windows, fallback to `%TEMP%\tillandsias\tokens\...` (not tmpfs, but best available; future: Windows Credential Manager integration)

**Permissions:** Directory created with mode 0700, file written with mode 0600. Both owned by the current user.

**Fallback:** If `$XDG_RUNTIME_DIR` is not set or not writable, fall back to `$TMPDIR` with a warning logged. If neither works, fall back to the current `hosts.yml` approach with a warning.

### D2: GIT_ASKPASS script baked into forge image

**Choice:** A shell script at `/usr/local/bin/git-askpass-tillandsias` inside the forge image:

```bash
#!/bin/sh
# GIT_ASKPASS helper for Tillandsias forge containers.
# Reads a GitHub token from the mounted secrets path and returns it
# as the password when git asks for credentials.
#
# @trace spec:secret-rotation
case "$1" in
  *assword*) cat /run/secrets/github_token 2>/dev/null || echo "" ;;
  *sername*) echo "x-access-token" ;;
esac
```

**Why:**
- Identical to the script designed in `fine-grained-pat-rotation` D5
- `x-access-token` username works for OAuth tokens, App installation tokens, and fine-grained PATs
- Script is baked into the image (not mounted), so containers cannot modify it
- Script is owned by root, mode 0755 (executable but not writable by forge user)
- Falls back gracefully: if `/run/secrets/github_token` doesn't exist, returns empty string (git prompts interactively, which fails non-interactively -- same as having no credentials)

### D3: Container mount strategy

**Choice:** Mount the token file read-only at `/run/secrets/github_token`:

```
-v $XDG_RUNTIME_DIR/tillandsias/tokens/<name>/github_token:/run/secrets/github_token:ro
```

Additionally, set the environment variable:
```
-e GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias
```

**Why:**
- `/run/secrets/` is the conventional container secrets path (Docker/Podman convention)
- Read-only mount prevents the container from modifying or deleting the token
- `GIT_ASKPASS` takes precedence over git credential helpers, ensuring the token file is used
- OpenCode's deny list can block `/run/secrets/` to prevent the AI agent from reading the token directly (defense in depth; the agent should use `git` commands, not read the token)

### D4: Keep hosts.yml mount alongside (dual-path)

**Choice:** During this change, the existing `hosts.yml` mount remains alongside the new token file mount.

**Why:**
- The `gh` CLI inside containers reads `hosts.yml` for non-git operations (e.g., `gh issue list`, `gh pr create`)
- Git operations use `GIT_ASKPASS` (which takes precedence over credential helpers)
- `gh` CLI operations use `hosts.yml` (which reads from the mounted file)
- The `hosts.yml` mount will be removed in Phase 4 of `fine-grained-pat-rotation`, when `GH_TOKEN` env var can point to the scoped installation token

### D5: Host-side refresh task (55-minute interval)

**Choice:** A tokio task that rewrites the token file every 55 minutes. For OAuth tokens, this writes the same token (no-op in effect). The task exists to establish the infrastructure for future App token rotation.

**Why:**
- OAuth tokens don't expire, so the refresh is technically unnecessary
- But the infrastructure (tokio interval, atomic write, error handling) is identical to what `fine-grained-pat-rotation` Phase 3 needs
- Building it now means Phase 3 only needs to change the token source (keyring -> App API), not the delivery mechanism
- The refresh task also serves as a health check: if the keyring becomes unavailable mid-session, the log will show the failure

**Implementation:** `tokio::spawn` a task that runs `tokio::time::interval(Duration::from_secs(55 * 60))`. On each tick, for each tracked container:
1. Retrieve token from keyring
2. Write to tmpfs file atomically (write `.tmp`, rename)
3. Log to accountability window

### D6: Cleanup strategy

**Choice:** Three layers of cleanup, from most specific to broadest:

1. **Container stop:** When a podman `die`/`stop` event is received for a tracked container, delete its token file and parent directory. Triggered in `event_loop.rs`.

2. **App exit:** On `RunEvent::ExitRequested`, delete the entire `$XDG_RUNTIME_DIR/tillandsias/tokens/` directory tree. This catches any containers that were running when the app exits.

3. **Drop guard:** A `TokenCleanupGuard` struct holds the base token directory path. Its `Drop` implementation deletes the directory tree. This ensures cleanup even if the app panics or is killed by a signal (for signals caught by Rust's panic handler; SIGKILL cannot be caught).

**Why:** Belt-and-suspenders. The most common path (container stop) cleans up immediately. The exit handler catches graceful shutdown. The Drop guard catches panics. Together, the only scenario where token files survive is `kill -9` of the Tillandsias process -- and even then, the files are on tmpfs and disappear on reboot or session logout.

### D7: Container profile changes

**Choice:** Add a new `SecretKind::GitHubToken` variant and a new `MountSource::TokenFile` variant to the container profile system.

The `forge_opencode_profile()`, `forge_claude_profile()`, and `terminal_profile()` gain a new secret entry:
```rust
SecretMount {
    kind: SecretKind::GitHubToken,
}
```

The `build_podman_args()` function in `launch.rs` handles this by:
1. Looking up the token file path from `LaunchContext`
2. Adding `-v <host_path>:/run/secrets/github_token:ro`
3. Adding `-e GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias`

`LaunchContext` gains a new field: `token_file_path: Option<PathBuf>`.

**Why:** This integrates cleanly with the existing profile system. The web profile does NOT get the GitHub token (it has no secrets by design). The `token_file_path` being `Option` allows graceful fallback when tmpfs is unavailable.

## Token Lifecycle

```
User clicks "Attach Here" for project "tetris"
    |
    v
[1] handlers.rs: retrieve token from keyring
    |
    v
[2] token_file.rs: write token to $XDG_RUNTIME_DIR/tillandsias/tokens/tillandsias-tetris-aeranthos/github_token
    - Create directory with mode 0700
    - Write to .tmp file
    - Set mode 0600 on .tmp file
    - Atomic rename .tmp -> github_token
    |
    v
[3] Accountability log:
    [secrets] v0.1.97.76 | Token written for tillandsias-tetris-aeranthos -> /run/secrets/... (tmpfs, ro mount)
      Spec: secret-rotation
      Cheatsheet: docs/cheatsheets/token-rotation.md
    |
    v
[4] launch.rs: build podman args including:
    -v /run/user/1000/tillandsias/tokens/tillandsias-tetris-aeranthos/github_token:/run/secrets/github_token:ro
    -e GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias
    |
    v
[5] Inside container: git push origin main
    -> git calls GIT_ASKPASS for credentials
    -> script reads /run/secrets/github_token -> returns token as password
    -> username = "x-access-token"
    -> push succeeds
    |
    v
[6] 55 minutes later: refresh task rewrites token file
    Accountability log:
    [secrets] v0.1.97.76 | Token refreshed for tillandsias-tetris-aeranthos (55min rotation)
      Spec: secret-rotation
      Cheatsheet: docs/cheatsheets/token-rotation.md
    |
    v
[7] Container stops (user or exit):
    -> event_loop receives podman die event
    -> token_file::delete("tillandsias-tetris-aeranthos")
    -> Removes /run/user/1000/tillandsias/tokens/tillandsias-tetris-aeranthos/
    Accountability log:
    [secrets] v0.1.97.76 | Token revoked for tillandsias-tetris-aeranthos (container stopped)
      Spec: secret-rotation
      Cheatsheet: docs/cheatsheets/token-rotation.md
```

## Platform-Specific tmpfs Paths

| OS | Token file base path | Backed by |
|----|---------------------|-----------|
| Linux (systemd) | `$XDG_RUNTIME_DIR/tillandsias/tokens/` | tmpfs (RAM), cleaned on session end |
| Linux (no systemd) | `$TMPDIR/tillandsias/tokens/` or `/tmp/tillandsias-$UID/tokens/` | tmpfs if `/tmp` is tmpfs (common), otherwise disk |
| macOS | `$TMPDIR/tillandsias/tokens/` | tmpfs (macOS default for `$TMPDIR`) |
| Windows | `%TEMP%\tillandsias\tokens\` | Disk (NTFS). Not ideal. Future: Windows named pipes or Credential Manager. |

**Resolution function:**
```
fn token_base_dir() -> PathBuf:
    1. Try $XDG_RUNTIME_DIR (Linux, guaranteed tmpfs)
    2. Try $TMPDIR (macOS, usually tmpfs)
    3. Fall back to platform temp dir
    4. Append "tillandsias/tokens/"
```

## Security Analysis

### What improves

| Property | Before | After |
|----------|--------|-------|
| Token in `/proc/*/environ` | Yes (if ever passed as env var) | No (delivered via file mount) |
| Token on persistent storage | Yes (`~/.cache/.../hosts.yml`) | No (tmpfs only) |
| Token survives container stop | Yes (file stays on disk) | No (deleted immediately) |
| Token survives app exit | Yes | No (cleanup guard) |
| Token survives reboot | Yes (persisted in `~/.cache`) | No (tmpfs cleared) |

### What stays the same

| Property | Before | After |
|----------|--------|-------|
| Token scope | All repos (OAuth `repo` scope) | All repos (same token) |
| Token lifetime | Indefinite (OAuth) | Indefinite (same token) |
| Token accessible inside container | Yes (file read) | Yes (file read at `/run/secrets/`) |
| Host compromise = token compromise | Yes | Yes |

### What the future `fine-grained-pat-rotation` change adds

| Property | This change | + fine-grained-pat-rotation |
|----------|-------------|----------------------------|
| Token scope | All repos | Single repository |
| Token lifetime | Indefinite | 1 hour |
| Token minting by container | N/A | Impossible (no private key) |

## Interaction with `fine-grained-pat-rotation`

This change implements Phase 1 of the `fine-grained-pat-rotation` design:
- GIT_ASKPASS script in forge image (task 1.1, 1.2)
- Token file infrastructure (task 1.3)
- Container launch with token file mount (task 1.4, 1.5, 1.6)
- Dual-path with hosts.yml (task 1.7)

The refresh task (D5) prepares for Phase 3 (rotation daemon). When Phase 2 (GitHub App token minting) is implemented, the only change needed in the delivery path is: replace `retrieve_github_token()` with `mint_installation_token()` as the token source. Everything else (file write, mount, GIT_ASKPASS, cleanup) stays identical.

## Failure Modes

| Failure | Impact | Recovery |
|---------|--------|----------|
| `$XDG_RUNTIME_DIR` not set | Cannot create tmpfs token file | Fall back to `$TMPDIR`; warn in accountability log |
| `$XDG_RUNTIME_DIR` not writable | Cannot create token directory | Fall back to `hosts.yml` mount; warn |
| Keyring unavailable | Cannot retrieve token | Fall back to existing `hosts.yml` if present; warn |
| Token file write fails | Container has no token at mount path | Container launch fails with clear error; suggest `--log-secret-management` |
| Atomic rename fails | Partial token visible | Write to `.tmp` in same directory (same fs); rename is atomic on POSIX. If rename fails, delete `.tmp` and retry once. |
| Cleanup fails on container stop | Stale token file on tmpfs | Cleaned up on app exit (layer 2) or Drop guard (layer 3) or session end (tmpfs cleared) |
| App killed with SIGKILL | Token files not cleaned | tmpfs cleared on reboot or session end. Token is the same OAuth token that's in the keyring anyway. |

## Open Questions

1. **Should `hosts.yml` writes to `~/.cache/` stop immediately?** Current design keeps them for backward compatibility (Phase 1 dual-path). But the current `write_hosts_yml_from_keyring()` writes to persistent storage on every container launch. **Recommendation: keep for now, remove in Phase 4 of fine-grained-pat-rotation.** The accountability window will show both the tmpfs write and the hosts.yml write, making the dual-path visible.

2. **Should OpenCode's deny list be updated to block `/run/secrets/`?** Yes, but that is a forge image change, not a Tillandsias change. Add a task to the forge repo. The deny list prevents the AI agent from `cat /run/secrets/github_token` directly. The agent should use `git push`, not raw token access.

3. **Should the Claude API key also move to tmpfs?** Currently it's passed as `ANTHROPIC_API_KEY` environment variable (visible in `/proc/*/environ`). Same vulnerability. **Recommendation: yes, in a follow-up change.** The same token file infrastructure can serve multiple secrets. Add `ANTHROPIC_API_KEY` to `/run/secrets/anthropic_api_key` and have the entrypoint script source it.
