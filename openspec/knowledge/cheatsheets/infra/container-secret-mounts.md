# Container Secret Mounts

## Secret Flow

```
Host keyring → temp files → bind mounts → container filesystem
```

On every launch:
1. `migrate_token_to_keyring()` — one-time migration of plain `hosts.yml` → OS keyring
2. `write_hosts_yml_from_keyring()` — refreshes `secrets/gh/hosts.yml` from keyring
3. `ensure_secrets_dirs()` — creates dirs + `.gitconfig` stub if absent
4. `podman run` — bind-mounts the secrets dirs into the container

## Mount Layout

| Host Path | Container Path | Mode | Purpose |
|---|---|---|---|
| `~/.cache/tillandsias/` | `/home/forge/.cache/tillandsias` | rw | Tool cache (npm, binaries) |
| `~/.cache/tillandsias/secrets/gh/` | `/home/forge/.config/gh` | ro | GitHub CLI credentials |
| `~/.cache/tillandsias/secrets/git/` | `/home/forge/.config/tillandsias-git` | rw | Git config |
| `~/.claude/` | `/home/forge/.claude` | rw | Claude OAuth credentials (Claude profile only) |

Project dir is mounted at `/home/forge/src` (rw) for all forge/terminal profiles. The web profile mounts project dir at `/var/www/html` (ro) only.

## Secret Scopes by Profile

| Profile | Project | Cache | gh (ro) | git (rw) | Claude dir |
|---|---|---|---|---|---|
| `forge-opencode` | rw | rw | yes | yes | NO |
| `forge-claude` | rw | rw | yes | yes | yes |
| `terminal` | rw | rw | yes | yes | NO |
| `web` | ro only | NO | NO | NO | NO |

Defined in `crates/tillandsias-core/src/container_profile.rs`. `common_forge_mounts()` covers project + cache + gh + git for all forge/terminal profiles. `SecretKind::ClaudeDir` in `ContainerProfile.secrets` adds the Claude mount.

## GitHub Token Flow

1. User authenticates via `gh auth login` inside a container
2. `gh` CLI writes token to `~/.cache/tillandsias/secrets/gh/hosts.yml` (via the rw cache mount)
3. On next Tillandsias launch, `migrate_token_to_keyring()` reads `hosts.yml`, stores token in OS keyring, marks migration complete
4. Before each subsequent launch, `write_hosts_yml_from_keyring()` writes a fresh minimal `hosts.yml` from the keyring token
5. `secrets/gh/` is mounted **read-only** — container reads credentials, cannot modify keyring

Fallback: if keyring is unavailable (headless, SSH, locked), the existing `hosts.yml` on disk is used as-is and a warning is logged.

## `hosts.yml` Format

`gh` CLI format — line-based parse, no YAML dependency:

```yaml
github.com:
    oauth_token: gho_xxxxxxxxxxxx
    git_protocol: https
```

## Claude Credential Flow (OAuth)

1. `~/.claude/` is created on the host if missing (before first mount)
2. Mounted rw into the Claude container at `/home/forge/.claude`
3. First launch: Claude Code prompts for browser OAuth inside the container
4. Credentials written to `~/.claude/` and persist across container restarts (container is ephemeral via `--rm`; host dir survives)
5. Reset via tray menu: Settings → Seedlings → Claude Reset Credentials

## Security Constraints

All containers receive these flags unconditionally — they are hardcoded in the arg builder and cannot be overridden by profiles:

| Flag | Effect |
|---|---|
| `--cap-drop=ALL` | No Linux capabilities |
| `--security-opt=no-new-privileges` | No suid/sgid escalation |
| `--userns=keep-id` | Rootless; host UID mapped into container |
| `--rm` | Ephemeral; removed on exit |

**Never mounted:** host root, other project dirs, system dirs, Docker/Podman socket, `~/.ssh`, `~/.gnupg`, or any path outside the declared profile.

## `ensure_secrets_dirs()` — `src-tauri/src/launch.rs`

Called before every `podman run`:

```
~/.cache/tillandsias/
  secrets/
    gh/           ← created if absent; hosts.yml written by write_hosts_yml_from_keyring()
    git/          ← created if absent
      .gitconfig  ← empty stub created if absent
```

Returns `(gh_dir, git_dir)` as `PathBuf` for use in mount arg construction.

## Keyring Integration — `src-tauri/src/secrets.rs`

| Function | When called | Effect |
|---|---|---|
| `migrate_token_to_keyring()` | App startup | One-time: reads `hosts.yml`, stores token in OS keyring |
| `store_github_token(token)` | After `gh auth login` detection | Writes token to OS keyring |
| `retrieve_github_token()` | Before each launch | Reads token from OS keyring |
| `write_hosts_yml_from_keyring()` | Before each `podman run` | Writes fresh `hosts.yml` from keyring |

Keyring entry: service `tillandsias`, key `github-oauth-token`. Uses the `keyring` crate — maps to GNOME Keyring (Linux), Keychain (macOS), Credential Manager (Windows).

## Env Vars Set by Profiles

| Var | Value | Profiles |
|---|---|---|
| `TILLANDSIAS_PROJECT` | project name (from context) | all forge, terminal |
| `TILLANDSIAS_HOST_OS` | host OS string | all forge, terminal |
| `GIT_CONFIG_GLOBAL` | `/home/forge/.config/tillandsias-git/.gitconfig` | all forge, terminal |
| `TILLANDSIAS_AGENT` | agent name (from context) | forge-opencode, forge-claude |

`GIT_CONFIG_GLOBAL` points into the rw-mounted git secrets dir — git operations inside the container use this isolated config, not the host's `~/.gitconfig`.
