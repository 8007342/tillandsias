---
tags: [github, credentials, keyring, secret-service, gh-cli, git-credential-manager, macos-keychain, deploy-key]
languages: []
since: 2026-04-26
last_verified: 2026-05-14
sources:
  - https://cli.github.com/manual/
  - https://cli.github.com/manual/gh_auth_login
  - https://cli.github.com/manual/gh_auth_token
  - https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys
  - https://specifications.freedesktop.org/secret-service/latest/
authority: high
status: current
---

# GitHub Credential Tools

How popular GitHub tools store credentials and how Tillandsias can consume them.

@trace spec:native-secrets-store, spec:secrets-management

## Provenance

- https://cli.github.com/manual/ — official GitHub CLI manual index; lists all `gh auth` subcommands (login, logout, refresh, setup-git, status, switch, token). Fetched 2026-04-27.
- https://cli.github.com/manual/gh_auth_login — official docs for `gh auth login`; confirms "an authentication token will be stored securely in the system credential store" with plaintext fallback when no credential store is found; documents `--insecure-storage` flag. Fetched 2026-04-27.
- https://cli.github.com/manual/gh_auth_token — official docs for `gh auth token`; confirms `-h`/`--hostname` and `-u`/`--user` flags; outputs the active token to stdout. Fetched 2026-04-27.
- https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys — official GitHub deploy-key guide; confirms least-privilege per-repo SSH access pattern used by `scripts/generate-repo-key.sh --mode=deploy`. Fetched 2026-05-14.
- https://specifications.freedesktop.org/secret-service/latest/ — Freedesktop Secret Service specification; canonical D-Bus reference for libsecret / GNOME Keyring used by the Tillandsias deploy-key flow. Fetched 2026-05-14.
- **Last updated:** 2026-05-14

## Tool Credential Storage

### gh CLI (GitHub CLI)

**Default (v2.40+):** OS keyring.

| Platform | Backend | Service | Account |
|----------|---------|---------|---------|
| Linux/GNOME | Secret Service D-Bus | `gh:github.com` | GitHub username |
| macOS | Keychain (Generic Password) | `gh:github.com` | GitHub username |
| Windows | Credential Manager | `gh:github.com` | GitHub username |

**Token format in keyring:** base64-encoded with prefix `go-keyring-base64:`

**Read token programmatically** (flags confirmed from fetched manual):
```bash
gh auth token                              # Print active token to stdout
gh auth token --hostname github.com        # Specify host (-h / --hostname)
gh auth token --user 8007342               # Print specific account's token (-u / --user)
gh auth status                             # Shows "(keyring)" if secure storage active
```

**Read from keyring directly:**
```bash
# Linux
secret-tool lookup service gh:github.com username 8007342
# macOS
security find-generic-password -s "gh:github.com" -a "8007342" -w
```

> Ref: [gh auth login manual](https://cli.github.com/manual/gh_auth_login)
> Ref: [gh CLI v2.24.0 — secure storage](https://github.com/cli/cli/discussions/7109)
> Ref: [gh multi-account docs](https://github.com/cli/cli/blob/trunk/docs/multiple-accounts.md)
> Ref: [zalando/go-keyring](https://github.com/zalando/go-keyring)

### Git Credential Manager (GCM)

Microsoft's recommended cross-platform credential helper.

| Platform | Default Backend | Entry Key |
|----------|----------------|-----------|
| Windows | Credential Manager | `target=git:https://github.com` |
| macOS | Keychain (Internet Password) | `server=github.com, protocol=https` |
| Linux | Must configure (`secretservice`, `gpg`, `cache`, `plaintext`) | `service=git:https://github.com` |

```bash
# Configure on Linux
git config --global credential.credentialStore secretservice
# or
export GCM_CREDENTIAL_STORE=secretservice
```

> Ref: [GCM credential stores](https://github.com/git-ecosystem/git-credential-manager/blob/main/docs/credstores.md)

### git-credential-libsecret (GNOME-native)

Stores as Internet Password in GNOME Keyring:

| Attribute | Value |
|-----------|-------|
| `xdg:schema` | `org.gnome.keyring.NetworkPassword` |
| `protocol` | `https` |
| `server` | `github.com` |
| `user` | GitHub username |

```bash
# Read
secret-tool lookup server github.com protocol https user <username>
# Install (Fedora)
sudo dnf install git-credential-libsecret
# Configure
git config --global credential.helper /usr/libexec/git-core/git-credential-libsecret
```

> Ref: [Fedora git-credential-libsecret](https://discussion.fedoraproject.org/t/attention-git-credential-libsecret-for-storing-git-passwords-in-the-gnome-keyring-is-now-an-extra-package/18275)

### git-credential-osxkeychain (macOS-native)

Stores as Internet Password in macOS Keychain:

| Field | Value |
|-------|-------|
| Kind | Internet Password |
| Server | `github.com` |
| Protocol | `https` |
| Account | GitHub username |

```bash
# Read
security find-internet-password -s github.com -a "<username>" -w
# Configure (usually pre-configured on macOS)
git config --global credential.helper osxkeychain
```

> Ref: [GitHub Docs — macOS Keychain credentials](https://docs.github.com/en/get-started/git-basics/updating-credentials-from-the-macos-keychain)

### GitHub Desktop

Uses Electron `safeStorage` API — NOT directly consumable by other tools.
Encryption key stored in OS keyring under app-specific name. Encrypted blob in Electron config file.

> Ref: [Electron safeStorage API](https://www.electronjs.org/docs/latest/api/safe-storage)

## Cross-Tool Keyring Entry Map

| Tool | Linux Lookup | macOS Lookup | Windows Lookup |
|------|-------------|-------------|----------------|
| **gh CLI** | `secret-tool lookup service gh:github.com username <user>` | `security find-generic-password -s "gh:github.com" -a "<user>" -w` | `cmdkey /list` filter `gh:github.com` |
| **GCM** | `secret-tool lookup service git:https://github.com` | `security find-internet-password -s github.com -w` | `cmdkey /list` filter `git:https://github.com` |
| **libsecret** | `secret-tool lookup server github.com protocol https` | N/A | N/A |
| **osxkeychain** | N/A | `security find-internet-password -s github.com -w` | N/A |
| **Tillandsias** | `secret-tool lookup service tillandsias username github-oauth-token` | `security find-generic-password -s "tillandsias" -a "github-oauth-token" -w` | N/A |

## Detection Priority for Tillandsias

When authenticating GitHub, check in order:

1. **`gh auth token` on host** — if `gh` is installed and authenticated, use its token directly
2. **Host keyring: `gh:github.com`** — gh's known entry, even if `gh` binary is absent
3. **Host keyring: `git:https://github.com`** — GCM's known entry
4. **Host keyring: `tillandsias` / `github-oauth-token`** — our own entry from previous sessions
5. **Fallback: run `gh auth login`** — on host if `gh` installed, in forge container with D-Bus forwarding otherwise

@trace spec:secrets-management

## Tillandsias Credential Flow (Host -> D-Bus -> Git Mirror -> Forge)

@trace spec:gh-auth-script, spec:secrets-management, spec:native-secrets-store

Tillandsias deliberately constrains credentials to the host. The forge container
where agents and OpenCode sessions run NEVER sees a GitHub token, deploy key, or
keyring socket. The flow is:

```
                +----------------+
   Host keyring | Secret Service |  (libsecret on Linux, Keychain on macOS,
                +----------------+   Credential Manager on Windows)
                        |
                        | D-Bus on /run/user/$UID/bus
                        v
                +----------------+
                | Git Service    |  Bare mirror + git daemon. Exec'd by the
                | container      |  tray on demand; reads the token via
                +----------------+   secret-tool, performs the authenticated
                        |             push to GitHub on behalf of the forge.
                        | git:// over the enclave network (no TLS, no auth)
                        v
                +----------------+
                | Forge          |  Speaks plain git. Pushes go to the mirror,
                | container      |   which then re-pushes upstream.
                +----------------+
```

**Why the forge never sees credentials**:

- The forge is the most-exposed surface (agent code, untrusted prompts, MCP
  servers running arbitrary tool calls). Treat it as compromised.
- A compromised forge that cannot read the keyring cannot exfiltrate the
  token even via D-Bus, because the forge has no D-Bus bind-mount.
- Defence-in-depth: even if a single forge boundary fails, the credential
  blast radius is capped at the project's git mirror, not the whole GitHub
  account.

See `cheatsheets/utils/podman-secrets.md` and
`cheatsheets/utils/tillandsias-secrets-architecture.md` for the deeper
mechanics (ephemeral podman secrets, cleanup-on-shutdown, no world-readable
files on disk).

## SSH Deploy Keys via `scripts/generate-repo-key.sh`

@trace spec:gh-auth-script

For projects that prefer per-repo SSH deploy keys (the GitHub recommendation
for least-privilege CI / agent access), Tillandsias provides:

```bash
./scripts/generate-repo-key.sh --mode=deploy [--project NAME] [--dry-run]
```

**What it does**:

1. Generates a fresh ed25519 key pair via `ssh-keygen -t ed25519 -N ''`.
2. Stores the **private key** in the host keyring via Secret Service:
   - Service: `tillandsias`
   - Account: `tillandsias-deploy-key:<project>`
3. Performs a round-trip read to confirm the key landed.
4. Writes a `[deploy_key]` section to `.tillandsias/config.toml` with:
   - Algorithm (`ed25519`)
   - Public-key fingerprint (`SHA256:...`)
   - The public key itself (paste this into GitHub repo settings)
   - The `keyring_service` / `keyring_account` pointers so the tray /
     headless can re-fetch the private key by name on subsequent attaches.

**What it deliberately does NOT do**:

- It does NOT write the private key to any file inside the project tree.
- It does NOT pass the private key to a forge container directly. The git
  service container fetches it from the host keyring at push time.
- It does NOT replace `gh auth login` — both modes coexist. Use the deploy
  key for non-interactive push paths (CI, scheduled agent loops) and the
  `gh` OAuth flow for interactive humans.

**Reading the key back** (host-side):

```bash
secret-tool lookup service tillandsias \
    account tillandsias-deploy-key:<project>
```

**Detection priority** (extended): in addition to the five steps above, if
`.tillandsias/config.toml` contains a `[deploy_key]` section with a
`keyring_service` pointer, the tray will prefer that key for non-interactive
git operations on the project.

**Legacy mode**: `scripts/generate-repo-key.sh --mode=gpg` (the default for
backward compatibility) still generates the RSA-4096 GPG key for APT/RPM
repository signing. The active release pipeline uses Cosign, so this path is
exercised only by historical scripts.

## git credential.helper Options

| Helper | Storage | Security | Cross-platform |
|--------|---------|----------|----------------|
| `store` | Plaintext `~/.git-credentials` | None | Yes |
| `cache` | In-memory daemon (default 15 min) | Good (memory only) | Yes |
| `osxkeychain` | macOS Keychain | Strong (OS encryption + ACL) | macOS only |
| `libsecret` | GNOME Keyring | Moderate (OS encryption, no ACL) | Linux/GNOME |
| `wincred` | Windows Credential Manager | Strong (DPAPI) | Windows only |
| `manager` (GCM) | Platform-dependent | Best (auto-selects) | Yes |

> Ref: [Git credential storage — Pro Git](https://git-scm.com/book/en/v2/Git-Tools-Credential-Storage)
> Ref: [GitHub Docs — Caching credentials](https://docs.github.com/en/get-started/git-basics/caching-your-github-credentials-in-git)
