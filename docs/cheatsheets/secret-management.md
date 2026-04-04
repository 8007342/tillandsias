# Secret Management

## Overview

Tillandsias manages three categories of secrets on behalf of the user: the GitHub OAuth token, the Claude (Anthropic) API key, and the git identity. Each is stored in the host OS native keyring and delivered to development environments without ever appearing in environment variables or persistent files inside the container. The goal is to make credentials available where tools need them while keeping them inaccessible to AI agents running inside the environment.

## How It Works

### Secret types and keyring entries

| Secret | Keyring service | Keyring key | Used for |
|--------|----------------|-------------|----------|
| GitHub OAuth token | `tillandsias` | `github-oauth-token` | git authentication, `gh` CLI operations |
| Claude API key | `tillandsias` | `claude-api-key` | Claude coding agent inside containers |
| Git identity | n/a (file) | n/a | `~/.gitconfig` bind-mounted into containers |

Source: `src-tauri/src/secrets.rs`
@trace spec:native-secrets-store

### Step-by-step: GitHub token lifecycle

```
[1] First launch (migration)
    secrets::migrate_token_to_keyring()
      - Reads ~./cache/tillandsias/secrets/gh/hosts.yml (if it exists)
      - Extracts oauth_token value
      - Stores it in OS keyring (service=tillandsias, key=github-oauth-token)
      - One-time, idempotent

[2] Container launch (every time)
    secrets::write_hosts_yml_from_keyring()
      - Retrieves token from OS keyring
      - Writes a fresh hosts.yml at ~/.cache/tillandsias/secrets/gh/hosts.yml
      - File is overwritten on every launch (not persistent)

    token_file::write()  [secret-rotation-tokens change]
      - Writes token to $XDG_RUNTIME_DIR/tillandsias/tokens/<name>/github_token
      - Directory: mode 0700, file: mode 0600
      - Atomic: write to .tmp, rename to final path (POSIX guarantee)
      - File lives on tmpfs (RAM only, never touches disk)

[3] Inside container
    git push origin main
      -> git reads GIT_ASKPASS env var
      -> calls /usr/local/bin/git-askpass-tillandsias
      -> script reads /run/secrets/github_token
      -> returns username="x-access-token", password=<token>
      -> push succeeds

    gh issue list
      -> gh CLI reads /home/forge/.config/gh/hosts.yml (bind-mounted)
      -> uses oauth_token from the file

[4] Container stop
    token_file::delete(<container-name>)
      - Deletes $XDG_RUNTIME_DIR/tillandsias/tokens/<name>/
      - Logged to accountability window

[5] App exit
    $XDG_RUNTIME_DIR/tillandsias/tokens/ tree deleted
    (Drop guard ensures cleanup even on panic)
```

### Step-by-step: Claude API key lifecycle

1. User authenticates via "Claude Login" in the tray menu.
2. Key is stored in OS keyring (`tillandsias` / `claude-api-key`).
3. At container launch, key is retrieved and passed as `-e ANTHROPIC_API_KEY=<key>`.
4. Key is only injected into `forge-claude` profile containers; `forge-opencode` and `terminal` profiles do not receive it.
5. Future: the API key will move to tmpfs token files (same pattern as the GitHub token) to eliminate exposure via `/proc/*/environ`.

### Volume mount strategy

| Mount | Host path | Container path | Mode | Purpose |
|-------|-----------|----------------|------|---------|
| Project code | `<project-dir>` | `/home/forge/src/<name>` | `rw` | Source files |
| Cache | `~/.cache/tillandsias/` | `/home/forge/.cache/` | `rw` | Build artifacts, npm/cargo caches |
| GitHub auth | `~/.cache/tillandsias/secrets/gh/` | `/home/forge/.config/gh/` | `ro` | `gh` CLI token (dual-path, see below) |
| Git identity | `~/.cache/tillandsias/secrets/git/` | `~/.gitconfig` etc. | `rw` | Commit author identity |
| GitHub token file | `$XDG_RUNTIME_DIR/tillandsias/tokens/<name>/github_token` | `/run/secrets/github_token` | `ro` | GIT_ASKPASS credential file |

Source: `src-tauri/src/launch.rs`
@trace spec:podman-orchestration

### Dual-path: hosts.yml and token file

Currently, both the `hosts.yml` mount (at `/home/forge/.config/gh/`) and the tmpfs token file (at `/run/secrets/github_token`) are present simultaneously. This is intentional:

- **`hosts.yml`** is used by the `gh` CLI for API operations (`gh issue list`, `gh pr create`, etc.)
- **Token file + GIT_ASKPASS** is used by git for HTTPS authentication

The `hosts.yml` mount will be removed in Phase 4 of `fine-grained-pat-rotation`, when the `GH_TOKEN` environment variable can point to the scoped installation token instead.

### OpenCode / Claude agent deny list

The forge image's `opencode.json` contains a deny list that blocks the AI agent from directly reading `/run/secrets/`. This provides defense in depth: even if an agent attempts `cat /run/secrets/github_token`, the file is not accessible through OpenCode's tool system. The agent should use `git push` (which invokes GIT_ASKPASS transparently) rather than raw token access.

@trace spec:secrets-management

## CLI Commands

```bash
# Watch all secret lifecycle events in real time
tillandsias --log-secret-management

# Same, with full trace-level detail (includes spec URLs)
tillandsias --log=secrets:trace --log-secret-management

# Log file contains all events regardless of flags
# Linux:   ~/.local/state/tillandsias/tillandsias.log
# macOS:   ~/Library/Logs/tillandsias/tillandsias.log
# Windows: %LOCALAPPDATA%/tillandsias/logs/tillandsias.log
```

Example accountability output:
```
[secrets] v0.1.97.76 | GitHub token stored in native keyring
  -> Token stored in OS keyring, not written to disk
  @trace https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Anative-secrets-store&type=code

[secrets] v0.1.97.76 | Token written for tillandsias-tetris-aeranthos -> /run/secrets/... (tmpfs, ro mount)
  -> Token on RAM-only tmpfs, deleted on container stop
  @trace https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Asecret-rotation&type=code
```

## Failure Modes

| Scenario | Symptom | Recovery |
|----------|---------|----------|
| Keyring locked (e.g., after reboot, before first desktop login) | Warning in logs: "Keyring unavailable"; `hosts.yml` is left unchanged from previous launch; git auth may fail if `hosts.yml` is stale | Unlock keyring (log in to desktop session); restart Tillandsias |
| Keyring unavailable (headless/SSH server, no secret service) | Same as above; fallback to existing `hosts.yml` if present | Store token manually in `hosts.yml`; or run Tillandsias in a desktop session |
| `$XDG_RUNTIME_DIR` not set or not writable | Warning: "Cannot create tmpfs token dir"; token file mount skipped | GIT_ASKPASS fallback absent; git auth falls back to `hosts.yml` credential helper |
| Token file write fails (tmpfs full, permissions error) | Error logged; container launched without token file | Run `--log-secret-management` to see the specific error; check tmpfs usage with `df -h /run/user/<uid>/` |
| `hosts.yml` write fails (disk full) | Warning logged; existing `hosts.yml` used as-is | Check disk space; `hosts.yml` is at `~/.cache/tillandsias/secrets/gh/` |
| No GitHub token in keyring and no `hosts.yml` | Git operations fail non-interactively inside container | Run `gh auth login` on the host, then restart Tillandsias |
| Cleanup fails on container stop | Stale token file left on tmpfs | Cleaned by app-exit handler, Drop guard, or session end (tmpfs cleared on logout/reboot) |

## Security Model

**What is protected:**

- The GitHub token is never written to persistent disk storage by Tillandsias. `hosts.yml` is a transitional dual-path that will be removed when fine-grained App tokens are fully deployed.
- The token file lives on tmpfs (RAM) and is deleted when the container stops, when the app exits, and on logout/reboot.
- Tokens are not passed as environment variables to containers (no exposure via `/proc/*/environ`).
- The Claude API key is stored in the OS keyring, not in config files on disk.
- The OpenCode agent deny list prevents direct file-read access to `/run/secrets/`.
- Non-negotiable container security flags (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--rm`) are hardcoded in `src-tauri/src/launch.rs` and cannot be overridden by profiles or config.

**What is NOT protected (known limitations):**

- The Claude API key is currently injected as an environment variable (`ANTHROPIC_API_KEY`), which is visible in `/proc/*/environ` to processes inside the container. Future: move to a tmpfs file (same pattern as GitHub token).
- If the host system is compromised, the attacker can access the OS keyring and retrieve all stored tokens.
- The GitHub token in the dual-path `hosts.yml` is on persistent disk while the container is running. It is overwritten (not appended) on each launch.
- SIGKILL of the Tillandsias process prevents cleanup of tmpfs token files. They will be cleaned on session logout or reboot.

**Threat model:**
The primary threats are: (1) an AI agent attempting to read credentials directly, and (2) token persistence beyond the container's lifetime. The token-file delivery mechanism addresses both. Long-term, `fine-grained-pat-rotation` reduces blast radius by scoping tokens to single repositories with 1-hour expiry.

## Enclave Architecture Impact (Phase 3 — ACTIVE)

Phase 3 is live. The enclave architecture fundamentally changes the threat model for secrets. Forge containers have ZERO credentials — the git service is the sole credential holder, communicating with the host keyring via D-Bus while remaining isolated on the internal `tillandsias-enclave` network with no external access.

**Current state:**

| Aspect | Before (Phase 1-2) | Now (Phase 3) |
|--------|---------------------|---------------|
| GitHub token in forge | Yes (tmpfs + hosts.yml mounts) | ZERO — git service handles auth |
| Claude API key in forge | Yes (env var) | Delivered via enclave IPC, not env var |
| Forge external network | Direct access (transitional) | ZERO — enclave only, all traffic via proxy |
| Credential exfiltration risk | Agent can read `/run/secrets/` (mitigated by deny list) | No credentials exist in forge to exfiltrate |
| Git push flow | forge reads token -> pushes directly | forge pushes to git service (enclave) -> git service authenticates via D-Bus -> pushes to remote |
| Git clone flow | Direct mount from host filesystem | Clone from git mirror service at startup (mirror-only, no fallback) |
| GitHub Login | Standalone forge container with script | Exec into running git service, or temporary git service container |

**Why this matters:** The previous secret management (keyring -> tmpfs -> bind mount) was defense in depth against a single-container architecture. The enclave eliminates the need to deliver credentials into the forge at all. The git service acts as a credential proxy — it authenticates on behalf of forge containers without exposing tokens.

The `hosts.yml` dual-path, the tmpfs token files, and the GIT_ASKPASS mechanism described in earlier sections are legacy. In Phase 3, they are replaced by enclave-internal git protocol traffic that never carries credentials. Forge containers clone from the git mirror at startup and push back to it — all over the enclave network with no credentials.

See `docs/cheatsheets/enclave-architecture.md` for the full enclave design, container types, and network topology.

@trace spec:enclave-network, spec:proxy-container

## Related

**Specs:**
- `openspec/changes/secrets-architecture/` — overall secrets architecture
- `openspec/changes/secret-rotation-tokens/` — tmpfs token file design (D1–D7)
- `openspec/changes/fine-grained-pat-rotation/` — GitHub App installation token roadmap

**Source files:**
- `src-tauri/src/secrets.rs` — keyring storage and retrieval, `hosts.yml` migration/write
- `src-tauri/src/launch.rs` — volume mount assembly, security flags
- `crates/tillandsias-core/src/container_profile.rs` — declarative mount profiles

**Cheatsheets:**
- `docs/cheatsheets/token-rotation.md` — how the 55-minute refresh task works
- `docs/cheatsheets/logging-levels.md` — how to use `--log-secret-management`
- `docs/cheatsheets/os-vault-credentials.md` — OS keyring APIs (GNOME, KDE, macOS, Windows)
- `docs/cheatsheets/github-credential-tools.md` — how gh, GCM, and git credential helpers store tokens
