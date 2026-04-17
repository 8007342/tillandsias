# SECRETS.md

Secrets architecture for Tillandsias forge environments.

---

## 1. Overview

Tillandsias manages secrets (GitHub tokens, SSH keys, git identity) transparently. Users never see encryption mechanics -- it "just works." You authenticate once, the token lands in the host OS keyring, and every forge session is authenticated without the token ever entering a forge container.

The architecture follows the same philosophy as the rest of Tillandsias: invisible infrastructure, zero cognitive load, no credentials in untrusted components.

---

## 2. Credential Flow

GitHub tokens live exclusively in the host OS's native secret store. The git service container inside the enclave reads them on demand through a D-Bus bridge and performs authenticated traffic to GitHub on behalf of the forge.

| Platform | Backend | Service / target |
|----------|---------|------------------|
| Linux (GNOME / KDE via Secret Service) | libsecret / GNOME Keyring | `service=tillandsias`, `username=github-oauth-token` |
| macOS | Keychain Services (Generic Password) | `service=tillandsias`, `account=github-oauth-token` |
| Windows | Credential Manager (DPAPI) | `target=tillandsias:github-oauth-token` |

No plaintext token file is written to disk at any point. The forge container receives no token, no keyring handle, and no D-Bus socket.

---

## 3. Secret Categories

| Category | Scope | Storage | Example |
|----------|-------|---------|---------|
| GitHub OAuth token | Shared (all projects) | Host OS keyring | `gh auth` token |
| Git identity | Shared | `~/.cache/tillandsias/secrets/git/` | user.name, user.email, .gitconfig |
| SSH keys | Shared | `~/.cache/tillandsias/secrets/ssh/` | id_ed25519, known_hosts |
| Project tokens | Per-project | `<project>/.tillandsias/secrets/` | API keys, .env files |

**Shared** means the credential is available in every forge session for this user. **Per-project** means the credential is only mounted into the forge for that specific project.

---

## 4. Component Trust Boundaries

| Component | Trust Level | Sees Token |
|-----------|-------------|-----------|
| Host tray app (signed binary) | Trusted | Writes / reads keyring |
| Git service container | Trusted (within enclave) | Reads token via D-Bus per operation |
| Forge container | Untrusted | **Never** — speaks plain git protocol to the mirror |
| User code / AI agents inside forge | Hostile | **Never** — no credential path reaches them |

The forge has no D-Bus socket mount, no keyring handle, no token file, and no outbound network access. Even a fully compromised agent cannot exfiltrate a credential it cannot see.

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

**Default behavior:** Shared. All forge sessions share the same git identity, GitHub auth, and SSH keys.

**Per-project override:** Place credentials in `<project>/.tillandsias/secrets/` and configure in `.tillandsias/config.toml`:

```toml
[secrets]
# Override shared git identity for this project
git-identity = "per-project"

# Use a project-specific GitHub token
gh-auth = "per-project"
```

---

## 6. Security Model

| Threat | Mitigation |
|--------|------------|
| Agent inside forge reads a token | Forge has no token — it lives in the host keyring and is used only by the git service |
| Container escape from forge | `--cap-drop=ALL`, `--security-opt=no-new-privileges`, rootless podman, enclave network with no egress |
| Escape from the git service | Git service has no code execution surface exposed to the forge — only git protocol |
| Host reads secrets at rest | OS keyring encryption (DPAPI on Windows, file-encrypted kwallet/keyring on Linux, Keychain on macOS) |
| Cross-project secret leak | Per-project secrets mounted only into that project's forge |
| Token in AI context | Tokens are never passed to the forge, so they cannot appear in agent tool output |
| Backup exposure | Keyring backends are excluded from standard user-data backups; Tillandsias writes no plaintext token to `~/.cache/` |
| Stolen laptop | OS login unlocks the keyring; without login, the token is unreadable |

---

## 7. Mount Strategy

The forge container receives only what it needs for the work itself — source code, caches, git identity for commit attribution:

```
Host: ~/.cache/tillandsias/secrets/
  |-- git/          --> Container: ~/.gitconfig + ~/.config/git/  (ro)
  |-- ssh/          --> Container: ~/.ssh/                        (ro, per policy)
  +-- per-project/  --> Container: <project>/.env                 (rw, per policy)
```

GitHub tokens are **not** mounted into the forge. All GitHub-authenticated traffic (clone, fetch, push, API calls) is brokered by the git service container, which lives on the enclave network and bridges to the host keyring via D-Bus.

**Mount flags:**

| Secret | Mount Mode | Rationale |
|--------|-----------|-----------|
| SSH keys | `:ro` | Forge should never modify SSH keys |
| Git config | `:ro` | Identity is set on host, forge reads it for commit metadata |
| Per-project secrets | `:rw` | Project may generate or rotate tokens |

All mounts use `--userns=keep-id` so file ownership maps correctly between host and container.

---

## 8. Lifecycle

1. **First authentication:** `tillandsias --github-login` launches the host-side OAuth flow; the token lands directly in the host OS keyring.
2. **On each forge launch:** no token material is prepared, written, or mounted into the forge. The git service container reads the token from the keyring (via D-Bus on Linux, Security framework on macOS, Credential Manager on Windows) each time it needs to contact GitHub.
3. **On forge stop:** nothing credential-related needs cleanup — the forge never held a token.
4. **On token rotation / re-auth:** `tillandsias --github-login` overwrites the keyring entry; the next git service operation picks up the new token automatically.

---
