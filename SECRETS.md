# SECRETS.md

Secrets architecture for Tillandsias forge containers.

---

## 1. Overview

Tillandsias manages secrets (GitHub tokens, SSH keys, git credentials) transparently. Users never see encryption mechanics -- it "just works." You authenticate once, and every forge container session has access to your credentials without re-authentication.

Secrets persist between forge runs and are shared across projects where appropriate. The system follows the same philosophy as the rest of Tillandsias: invisible infrastructure, zero cognitive load.

---

## 2. Secret Categories

| Category | Scope | Storage | Example |
|----------|-------|---------|---------|
| GitHub auth | Shared (all projects) | `~/.cache/tillandsias/secrets/gh/` | `gh auth` tokens |
| Git identity | Shared | `~/.cache/tillandsias/secrets/git/` | user.name, user.email, .gitconfig |
| SSH keys | Shared | `~/.cache/tillandsias/secrets/ssh/` | id_ed25519, known_hosts |
| Project tokens | Per-project | `<project>/.tillandsias/secrets/` | API keys, .env files |

**Shared** means the same credential is available in every forge container. **Per-project** means the credential is only mounted into the forge for that specific project.

---

## 3. Current Implementation (MVP)

For now, secrets are plain files mounted as volumes into forge containers.

- GitHub credentials are stored via `gh auth login` into `~/.cache/tillandsias/secrets/gh/`
- Git config (user.name, user.email) lives in `~/.cache/tillandsias/secrets/git/`
- SSH keys are copied or symlinked into `~/.cache/tillandsias/secrets/ssh/`
- All secret directories use restrictive UNIX permissions: `0700` for directories, `0600` for files

These directories are transparently mounted into containers at the paths where tools expect them (`~/.config/gh/`, `~/.gitconfig`, `~/.ssh/`). No configuration required from the user.

---

## 4. Future: Encrypted Secrets Filesystem

Phase 2 introduces encryption at rest using either a LUKS-encrypted loop device or `gocryptfs`:

**How it works:**

1. On first `tillandsias` install, a symmetric encryption key is generated and stored in the system keyring (GNOME Keyring, macOS Keychain, Windows Credential Manager)
2. `~/.cache/tillandsias/secrets/` is backed by an encrypted filesystem
3. On container launch: the tray app unlocks the encrypted store using the keyring, mounts the decrypted view, and bind-mounts into the container
4. On container stop: the decrypted view is unmounted
5. From the host filesystem perspective: `~/.cache/tillandsias/secrets/` contains only encrypted blobs when no container is running

**Why `gocryptfs` over LUKS:**

- No root required (userspace FUSE)
- Per-file encryption (plays well with git, backups, sync)
- Cross-platform potential (Linux/macOS; Windows via cppcryptfs)
- Smaller attack surface than full block device encryption

**Fallback:** If the system keyring is unavailable, prompt for a passphrase on first container launch per session.

---

## 5. Per-Project vs Shared Credentials

Most credentials belong to the person, not the project:

| Credential | Shared or Per-Project? | Rationale |
|------------|----------------------|-----------|
| Git identity (user.name/email) | **Shared** | Same person across all projects |
| GitHub auth token | **Shared** | Same GitHub account |
| SSH keys | **Shared** | Same machine identity |
| API keys (.env) | **Per-project** | Different services per project |
| Deploy keys | **Per-project** | Specific repo access |

**Default behavior:** Shared. All forge containers get the same GitHub token, git identity, and SSH keys.

**Per-project override:** Place credentials in `<project>/.tillandsias/secrets/` and configure in `.tillandsias/config.toml`:

```toml
[secrets]
# Override shared git identity for this project
git-identity = "per-project"

# Use a project-specific GitHub token
gh-auth = "per-project"
```

---

## 6. Should .git Credentials Be Per-Project?

**Analysis:**

- **Git identity (user.name/email):** NO -- you are the same person regardless of which project you are working on. Using different identities per project is an edge case (work vs personal), handled by opt-in override.
- **GitHub auth token:** NO -- you use one GitHub account. Multiple accounts are rare and handled by per-project override.
- **Deploy keys:** YES -- deploy keys grant access to a specific repository. They must not leak across projects.

**Recommendation:** Shared by default. The `.tillandsias/config.toml` per-project override covers the edge cases without burdening the common case.

---

## 7. Security Model

| Threat | Mitigation |
|--------|------------|
| Agent reads secrets | `/bash-private` patterns, `agent_blocked` skills prevent agent from reading credential files |
| Container escape | `--cap-drop=ALL`, `--security-opt=no-new-privileges`, rootless podman |
| Host reads secrets at rest | Phase 2: encrypted at rest via gocryptfs, key in system keyring |
| Cross-project secret leak | Per-project secrets mounted only into that project's forge container |
| Token appears in AI context | Private auth flow -- credentials never enter the conversation |
| Backup exposure | Encrypted blobs safe to back up; decryption requires keyring access |
| Stolen laptop | System keyring locked by OS login; encrypted secrets unreadable without session |

**Trust zones remain unchanged:**

| Component | Trust Level |
|-----------|-------------|
| Tray App | Trusted (manages keyring, mounts secrets) |
| Forge Container | Untrusted (has mounted secrets, but agent is restricted) |
| User Code | Hostile (no secret access beyond what the forge explicitly provides) |

---

## 8. Mount Strategy

Host paths are mapped to standard tool-expected paths inside containers:

```
Host: ~/.cache/tillandsias/secrets/
  |-- gh/           --> Container: ~/.config/gh/
  |-- git/          --> Container: ~/.gitconfig + ~/.config/git/
  |-- ssh/          --> Container: ~/.ssh/ (read-only)
  +-- per-project/  --> Container: <project>/.env (per-project only)
```

**Mount flags:**

- SSH keys: `:ro` (read-only) -- forge should never modify SSH keys
- GitHub auth: `:rw` -- `gh auth refresh` needs write access to update tokens
- Git config: `:ro` -- identity is set on host, forge reads it
- Per-project secrets: `:rw` -- project may generate or rotate tokens

**Container launch (conceptual):**

```bash
podman run \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  -v ~/.cache/tillandsias/secrets/gh:~/.config/gh:rw \
  -v ~/.cache/tillandsias/secrets/git/gitconfig:~/.gitconfig:ro \
  -v ~/.cache/tillandsias/secrets/ssh:~/.ssh:ro \
  forge-image
```

---

## 9. Implementation Phases

### Phase 1 (now): Plain directory mounts

- Create `~/.cache/tillandsias/secrets/` directory structure on first run
- Store credentials as plain files with `0600`/`0700` permissions
- Mount into containers via podman volume flags
- Implement `/gh-auth-login` skill for initial GitHub authentication
- Agent blocked from reading credential paths

### Phase 2: Encrypted storage

- Integrate `gocryptfs` for encrypted-at-rest secrets directory
- Key stored in system keyring (GNOME Keyring / macOS Keychain / Windows Credential Manager)
- Auto-unlock on container launch, auto-lock on container stop
- Transparent to all existing mount paths -- no changes to container configuration
- Fallback to passphrase prompt if keyring unavailable

### Phase 3: Per-project isolation and deploy keys

- Per-project secret directories with `.tillandsias/config.toml` configuration
- Deploy key management: generate, store, mount per-project SSH keys
- Secret rotation reminders (token expiry detection)
- Multi-identity support (work/personal git identity switching)

---
