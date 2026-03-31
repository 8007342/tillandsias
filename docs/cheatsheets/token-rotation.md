# Token Rotation

## Overview

When a development environment starts, Tillandsias writes the GitHub OAuth token to a RAM-only tmpfs file and mounts it read-only into the container at `/run/secrets/github_token`. A background task rewrites this file every 55 minutes. When the container stops, the file is deleted. This design eliminates token persistence to disk, reduces the blast radius of a compromised container, and establishes the delivery infrastructure that will serve short-lived GitHub App installation tokens in the future.

@trace spec:secret-rotation

## How It Works

### Why not pass the token as an environment variable?

Environment variables are visible in `/proc/<pid>/environ` to any process running as the same user inside the container. AI coding agents execute arbitrary tool calls, install packages, and run build scripts — any of which could read `/proc/1/environ` to extract a token. Passing the token as a file mounted from tmpfs removes it from the process environment entirely.

@trace spec:secret-rotation

### The token file path

```
Linux (systemd):  $XDG_RUNTIME_DIR/tillandsias/tokens/<container-name>/github_token
                  e.g., /run/user/1000/tillandsias/tokens/tillandsias-tetris-aeranthos/github_token

macOS:            $TMPDIR/tillandsias/tokens/<container-name>/github_token

Windows:          %TEMP%\tillandsias\tokens\<container-name>\github_token
                  (disk-backed; Windows named pipe integration planned)
```

`$XDG_RUNTIME_DIR` is mandated by the XDG Base Directory Specification to be a tmpfs (RAM-backed) owned by the user with mode 0700. Data here never touches persistent storage and is automatically cleared on session end.

Directory permissions: `0700` (owner only)
File permissions: `0600` (owner only)

### Step-by-step: from "Attach Here" to git push

```
[1] User clicks "Attach Here" for project "tetris"
    handlers.rs retrieves GitHub token from OS keyring

[2] token_file::write("tillandsias-tetris-aeranthos", token)
    - Create $XDG_RUNTIME_DIR/tillandsias/tokens/tillandsias-tetris-aeranthos/ (mode 0700)
    - Write token to github_token.tmp (mode 0600)
    - Atomic rename: github_token.tmp -> github_token
      (same filesystem, rename is atomic on POSIX — no partial token visible)

[3] Accountability log:
    [secrets] v0.1.97.76 | Token written for tillandsias-tetris-aeranthos (tmpfs, ro mount)
      -> Token on RAM-only tmpfs, deleted on container stop
      @trace https://...spec%3Asecret-rotation

[4] launch.rs adds to podman run args:
    -v /run/user/1000/.../tillandsias-tetris-aeranthos/github_token:/run/secrets/github_token:ro
    -e GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias

[5] Inside container: git push origin main
    - git reads GIT_ASKPASS env var
    - calls /usr/local/bin/git-askpass-tillandsias "Password for 'https://github.com':"
    - script runs: cat /run/secrets/github_token
    - returns token as password; username = "x-access-token"
    - push succeeds (no gh CLI or hosts.yml needed for git operations)

[6] 55 minutes later: refresh task fires
    - retrieve token from OS keyring
    - atomic write (same .tmp + rename pattern)
    - Accountability log: "Token refreshed for tillandsias-tetris-aeranthos (55min rotation)"

[7] Container stops (podman die event received)
    event_loop.rs -> token_file::delete("tillandsias-tetris-aeranthos")
    - Removes $XDG_RUNTIME_DIR/tillandsias/tokens/tillandsias-tetris-aeranthos/ tree
    - Accountability log: "Token revoked for tillandsias-tetris-aeranthos (container stopped)"
```

Source: `src-tauri/src/event_loop.rs`, design: `openspec/changes/secret-rotation-tokens/design.md`

### How GIT_ASKPASS works

`GIT_ASKPASS` is a standard git mechanism. When git needs credentials for an HTTPS remote:

1. Git calls the script at `$GIT_ASKPASS` twice: once with a prompt containing `Username`, once with a prompt containing `Password`.
2. The script outputs one line per call.
3. Git uses the two responses as HTTP Basic Auth.

The script baked into the forge image (`/usr/local/bin/git-askpass-tillandsias`):

```sh
#!/bin/sh
case "$1" in
  *assword*) cat /run/secrets/github_token 2>/dev/null || echo "" ;;
  *sername*) echo "x-access-token" ;;
esac
```

`x-access-token` is the username GitHub requires for OAuth tokens, App installation tokens, and fine-grained PATs. The same script works for all three — only the token value changes. If `/run/secrets/github_token` does not exist, the script returns an empty string and git prompts interactively (which fails non-interactively — same as having no credentials).

The script is baked into the image, not mounted from the host. Containers cannot modify it.

Source design: `openspec/changes/secret-rotation-tokens/design.md` (D2)
Source design: `openspec/changes/fine-grained-pat-rotation/design.md` (D5)

### The atomic write pattern

Token files are never written in-place. Every write (initial and refresh) uses:

```
1. Write token to github_token.tmp (same directory as github_token)
2. Set permissions on .tmp: 0600
3. rename(github_token.tmp, github_token)
```

Because `.tmp` and the final file are in the same directory (same filesystem), the `rename` system call is atomic on POSIX. The container can never read a partially written token.

If `rename` fails, `.tmp` is deleted and the failure is logged. The previous token file remains valid.

### The 55-minute refresh task

The refresh task is a `tokio::spawn`ed task using `tokio::time::interval(Duration::from_secs(55 * 60))`. On each tick, for each tracked container, it:

1. Retrieves the token from the OS keyring.
2. Writes to the token file atomically.
3. Logs to the accountability window.

For current OAuth tokens (which do not expire), this rewrites the same token — effectively a no-op in terms of value, but a real write in terms of mechanism. The infrastructure (interval, atomic write, error handling, accountability logging) is identical to what Phase 3 of `fine-grained-pat-rotation` needs. When that change lands, only the token source changes (`retrieve_github_token()` becomes `mint_installation_token()`). The delivery path stays the same.

The 55-minute interval is chosen to provide a 5-minute safety margin for the 1-hour expiry of future App installation tokens. In-flight git operations started before the rotation window have 5 minutes to complete with the old token.

### Three-layer cleanup

Token files are cleaned up by three independent mechanisms, from most specific to broadest:

| Layer | Trigger | Code location |
|-------|---------|---------------|
| 1. Container stop | `podman die` event received | `src-tauri/src/event_loop.rs` |
| 2. App exit | `RunEvent::ExitRequested` handler | `src-tauri/src/event_loop.rs` (or main.rs) |
| 3. Drop guard | `TokenCleanupGuard::drop()` — fires on panic or any code path that drops the guard | `src-tauri/src/event_loop.rs` (or token_file.rs) |

Layer 1 handles the normal case. Layer 2 handles graceful shutdown when containers may still be running. Layer 3 handles panics. The only scenario where token files survive all three layers is `kill -9` of the Tillandsias process — and even then, the files are on tmpfs and disappear on session logout or reboot.

## CLI Commands

```bash
# Watch token write, refresh, and delete events in real time
tillandsias --log-secret-management /path/to/project

# Same with trace-level detail (includes spec URLs)
tillandsias --log=secrets:trace --log-secret-management /path/to/project

# Inspect tmpfs token directory manually (Linux)
ls -la /run/user/$(id -u)/tillandsias/tokens/

# Check tmpfs usage
df -h /run/user/$(id -u)/

# Verify token file is on tmpfs (Linux)
findmnt --target /run/user/$(id -u)/
# Should show: tmpfs on /run/user/<uid>
```

## Failure Modes

| Scenario | What happens | Recovery |
|----------|-------------|----------|
| `$XDG_RUNTIME_DIR` not set | Warning logged; falls back to `$TMPDIR`; token file still on tmpfs on most systems | Set `XDG_RUNTIME_DIR=/run/user/$(id -u)` in environment |
| `$XDG_RUNTIME_DIR` not writable | Warning logged; falls back to `hosts.yml` mount only; GIT_ASKPASS will fail to read token | Check permissions: `ls -la /run/user/$(id -u)/` |
| OS keyring locked mid-session | 55-minute refresh fails; warning logged; current token file remains valid until container stops | Unlock keyring (usually requires desktop session); next refresh succeeds automatically |
| OS keyring unavailable (headless server) | Token file cannot be written; falls back to `hosts.yml` mount | Run on a system with a keyring daemon, or store token in `hosts.yml` manually |
| Token file write fails (tmpfs full) | Error logged; previous token file remains; `--log-secret-management` shows details | Check tmpfs usage: `df -h /run/user/$(id -u)/`; tmpfs is usually sized at 50% of RAM |
| Atomic rename fails (same-fs guarantee violated) | `.tmp` file is deleted; error logged; previous token untouched | Should not occur on standard Linux (`.tmp` and final file in same directory). If it does, check filesystem type: `findmnt --target /run/user/<uid>/` |
| Container stops before cleanup (SIGKILL) | Token file remains on tmpfs | Cleaned by app-exit handler or session end; tmpfs is cleared on reboot or logout |
| App receives SIGKILL (`kill -9`) | All cleanup layers are bypassed | Token files remain on tmpfs until session end; same OAuth token is also in keyring; no new attack surface |

## Security Model

### Before vs. after vs. future

| Property | Before (hosts.yml) | Now (tmpfs + GIT_ASKPASS) | Future (App tokens) |
|----------|--------------------|--------------------------|---------------------|
| Token in `/proc/*/environ` | Possible (if env var) | No | No |
| Token on persistent disk | Yes (`~/.cache/.../hosts.yml`) | No (tmpfs only) | No (tmpfs only) |
| Token scope | All repositories | All repositories | Single repository |
| Token lifetime | Indefinite (OAuth) | Indefinite (OAuth) | 1 hour |
| Survives container stop | Yes | No (deleted) | No (deleted) |
| Survives app exit | Yes | No (cleanup guard) | No (cleanup guard) |
| Survives reboot | Yes | No (tmpfs cleared) | No (tmpfs cleared) |
| Container can mint new tokens | N/A | No | No (no private key) |

### What remains the same

- A process inside the container can still read `/run/secrets/github_token` if it has filesystem access (the OpenCode deny list blocks this via the agent tool system, not the kernel).
- A compromised host can access the OS keyring and retrieve the token.
- The token has full `repo` scope on all the user's repositories.

These limitations are addressed by the `fine-grained-pat-rotation` roadmap (per-repo scoped tokens, 1-hour expiry).

## Roadmap: GitHub App installation tokens

The current infrastructure is Phase 1 of a four-phase plan defined in `fine-grained-pat-rotation`:

| Phase | Description | Token type |
|-------|-------------|------------|
| 1 (current) | tmpfs token file, GIT_ASKPASS, 55-min refresh | Full OAuth token, indefinite lifetime |
| 2 | GitHub App registration + token minting API | Per-repo installation token, 1-hour expiry |
| 3 | Rotation daemon with Track/Untrack + event loop integration | Per-repo installation token, auto-rotated at 55min |
| 4 | Remove `hosts.yml` mount; set `GH_TOKEN` to token file for `gh` CLI | Per-repo installation token, all git + gh CLI operations |

When Phase 2 is implemented, the only change to the delivery path is: replace `retrieve_github_token()` (keyring read) with `mint_installation_token()` (GitHub App API call) as the token source. The file write, mount, GIT_ASKPASS script, and cleanup logic are unchanged.

## Related

**Specs:**
- `openspec/changes/secret-rotation-tokens/` — this feature's design (D1–D7, failure modes, security analysis)
- `openspec/changes/fine-grained-pat-rotation/` — roadmap to per-repo scoped tokens (Phases 1–4)

**Source files:**
- `src-tauri/src/event_loop.rs` — token cleanup on container stop and app exit
- `src-tauri/src/secrets.rs` — keyring retrieval (`retrieve_github_token`)

**Cheatsheets:**
- `docs/cheatsheets/secret-management.md` — full secrets lifecycle, all secret types
- `docs/cheatsheets/logging-levels.md` — how to use `--log-secret-management`
