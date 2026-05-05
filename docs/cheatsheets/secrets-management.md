---
tags: [secrets, keyring, credentials, security, tokens]
languages: [rust]
since: 2024-01-01
last_verified: 2026-04-27
sources:
  - https://docs.rs/keyring/latest/keyring/
  - https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html
authority: high
status: current
---

# Secret Management

## Overview

Tillandsias manages three categories of secrets on behalf of the user: the GitHub OAuth token, the Claude (Anthropic) API key, and the git identity. The host Rust process is the **sole consumer** of the OS native keyring. Containers never see D-Bus, the Secret Service API, the Keychain, or Credential Manager. When a container needs the GitHub token, the host reads the keyring in-process, writes the token to a per-container ephemeral file with restrictive permissions, and bind-mounts that file read-only into the one container that needs it (the git service). The forge container has zero credentials at all times.

## How It Works

### Secret types and keyring entries

| Secret | Keyring service | Keyring key | Used for |
|--------|----------------|-------------|----------|
| GitHub OAuth token | `tillandsias` | `github-oauth-token` | Authenticated GitHub traffic from the git service |
| Claude API key | `tillandsias` | `claude-api-key` | Claude coding agent inside containers |
| Git identity | n/a (file) | n/a | `<cache>/secrets/git/.gitconfig`, surfaced as `GIT_AUTHOR_*` / `GIT_COMMITTER_*` env vars |

Source: `src-tauri/src/secrets.rs`
@trace spec:native-secrets-store

### Keyring backends per platform

| Platform | Backend | Access path | Notes |
|----------|---------|-------------|-------|
| Linux (GNOME / KDE / any Secret Service implementation) | libsecret over Secret Service D-Bus API | `keyring` crate, in the host process only | Requires an unlocked Secret Service in the user session |
| macOS | Keychain Services (Generic Password class) | `keyring` crate, Security framework | Always available in a logged-in session |
| Windows | Credential Manager (Wincred) | `keyring` crate, `CredWriteW` / `CredReadW` / `CredDeleteW` | Always available in a logged-in session |

Source: `src-tauri/src/secrets.rs`
@trace spec:native-secrets-store

### Headless-Linux caveat

A bare SSH session into a Linux box has no desktop session, no Secret Service daemon, and no D-Bus session bus. `gh auth login` driven through Tillandsias will surface an error such as `NoStorageAccess` from the `keyring` crate when it tries to call `store_github_token`.

To enable the keyring on a headless host, run one of the following before invoking `tillandsias --github-login`:

```bash
# Option 1: start gnome-keyring-daemon manually and unlock it
eval "$(gnome-keyring-daemon --unlock --daemonize)"
export SSH_AUTH_SOCK GPG_AGENT_INFO GNOME_KEYRING_CONTROL DBUS_SESSION_BUS_ADDRESS

# Option 2: wrap Tillandsias in a fresh dbus session
dbus-run-session -- tillandsias --github-login
```

The container itself never touches D-Bus — this caveat is purely about the host being able to reach its own keyring.

@trace spec:native-secrets-store

### Step-by-step: GitHub token lifecycle

```
[1] First authentication (user action)
    `tillandsias --github-login` (or tray "GitHub Login")
      - Prompts for git identity, writes <cache>/secrets/git/.gitconfig
      - Spins up an ephemeral container from the git-service image
        (default bridge network, no host mounts, no enclave network)
      - Runs `podman exec -it gh auth login --git-protocol https`
        with the real TTY
      - Runs `podman exec gh auth token` to capture the token on the host
      - Calls `secrets::store_github_token` -> writes to host OS keyring
        (service=tillandsias, key=github-oauth-token)
      - Drop guard tears down the login container; all on-disk gh state
        dies with it. Token is in the host keyring only.

[2] Forge launch (every time)
    - No token material is prepared for the forge
    - Forge has no D-Bus socket, no token file, no keyring access

[3] Forge performs git push / fetch / clone
      -> git speaks plain git protocol to the enclave-local git service
         (host: tillandsias-git in the enclave network)
      -> no authentication at the forge boundary

[4] Git service launch
      -> host reads the token from its OS keyring in-process
      -> host writes it atomically to:
           Linux:   $XDG_RUNTIME_DIR/tillandsias/tokens/<container>/github_token
           macOS:   $TMPDIR/tillandsias-tokens/<container>/github_token
           Windows: %LOCALAPPDATA%\Temp\tillandsias-tokens\<container>\github_token
         (parent dir 0700, file 0600 on Unix; per-user NTFS ACL on Windows)
      -> bind-mounts the file at /run/secrets/github_token:ro
      -> sets GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias.sh
      -> the git daemon authenticates to github.com via that ASKPASS script
      -> token never leaves the git service container or the host keyring

[5] Container stop
      -> host calls cleanup_token_file(container_name)
      -> the file and its parent directory are unlinked from the runtime dir

[6] App exit (including panic / Drop guard)
      -> cleanup_all_token_files() removes the entire tokens/ tree
```

### Step-by-step: Claude API key lifecycle

1. User authenticates via "Claude Login" in the tray menu.
2. Key is stored in OS keyring (`tillandsias` / `claude-api-key`).
3. At container launch, key is retrieved and passed as `-e ANTHROPIC_API_KEY=<key>`.
4. Key is only injected into `forge-claude` profile containers; `forge-opencode` and `terminal` profiles do not receive it.
5. Future: the API key will move to the same ephemeral-file delivery path as the GitHub token to eliminate exposure via `/proc/*/environ`.

### Volume mount strategy

| Mount | Host path | Container path | Mode | Purpose |
|-------|-----------|----------------|------|---------|
| Project code | `<project-dir>` | `/home/forge/src/<name>` | `rw` | Source files |
| Cache | `~/.cache/tillandsias/` | `/home/forge/.cache/` | `rw` | Build artifacts, npm/cargo caches |
| GitHub token (git service only) | `<runtime-dir>/tillandsias/tokens/<container>/github_token` | `/run/secrets/github_token` | `ro` | Single ephemeral file written from the host keyring |

The GitHub token mount appears **only on the git service container**. It is never bind-mounted into a forge or terminal container in any form.

Source: `src-tauri/src/launch.rs`, `src-tauri/src/secrets.rs`
@trace spec:podman-orchestration, spec:secrets-management

### Agent credential isolation

Forge containers have ZERO credentials — sensitive directories (`~/.claude`, `/run/secrets/`) are protected by container mount topology, not by agent config deny lists. Secrets never enter the forge container; git authentication flows through the git service, which holds only the read-only token file written by the host.

@trace spec:secrets-management

## CLI Commands

```bash
# Watch all secret lifecycle events in real time
tillandsias --log-secrets-management

# Same, with full trace-level detail (includes spec URLs)
tillandsias --log=secrets:trace --log-secrets-management

# Authenticate with GitHub (token lands in host OS keyring)
tillandsias --github-login

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

[secrets] v0.1.97.76 | Prepared ephemeral token file for container launch
  -> Token written to ephemeral per-container file for :ro bind-mount; unlinked on container stop
  @trace https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Asecrets-management&type=code
```

## Failure Modes

| Scenario | Symptom | Recovery |
|----------|---------|----------|
| Keyring locked (e.g., after reboot, before first desktop login) | `Keyring unavailable` error from `store_github_token` / `retrieve_github_token`; git service launches without `/run/secrets/github_token` and authenticated traffic fails | Unlock keyring (log in to desktop session); retry |
| Headless Linux SSH (no Secret Service, no D-Bus session bus) | `--github-login` aborts with `NoStorageAccess`; nothing is written to disk | Run `gnome-keyring-daemon --unlock --daemonize` or wrap the binary in `dbus-run-session` (see Headless-Linux caveat above) |
| No GitHub token in keyring | `prepare_token_file` returns `Ok(None)`; git service starts without the bind mount and `git push` fails with an auth error | Run `tillandsias --github-login` |
| `cleanup_token_file` fails on container stop | Warning in logs that the file may briefly persist | The shutdown sweep (`cleanup_all_token_files`) removes everything on app exit |

## Security Model

**What is protected:**

- The GitHub token is written to the host OS keyring and never to persistent disk as plaintext.
- Containers never receive D-Bus, never call the keyring API, and never see any host credential beyond a single read-only file at `/run/secrets/github_token` (and only on the git service container).
- The forge container has no D-Bus socket, no keyring handle, no token file, and no outbound network — a compromised agent cannot exfiltrate a credential it cannot see.
- The token file is ephemeral: written from the host keyring at git-service launch, mode `0600` on Unix or per-user NTFS ACL on Windows, and unlinked on container stop. A panic-safe Drop guard sweeps the entire tokens directory on app exit.
- The token is not passed as an environment variable to any container (no exposure via `/proc/*/environ`).
- The Claude API key is stored in the OS keyring, not in config files on disk.
- Non-negotiable container security flags (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--rm`) are hardcoded in `src-tauri/src/launch.rs` and cannot be overridden by profiles or config.

**What is NOT protected (known limitations):**

- The Claude API key is currently injected as an environment variable (`ANTHROPIC_API_KEY`), which is visible in `/proc/*/environ` to processes inside the forge. Future: deliver it through the same ephemeral-file pattern as the GitHub token.
- If the host system is compromised, the attacker can access the OS keyring and retrieve all stored tokens.

**Threat model:**
The primary threats are: (1) an AI agent attempting to read credentials directly, and (2) token leakage beyond the trusted components. Keeping the token out of the forge entirely addresses both. Long-term, `fine-grained-pat-rotation` reduces blast radius by scoping tokens to single repositories with 1-hour expiry.

## Enclave Architecture Impact

The enclave architecture fundamentally changes the threat model for secrets. Forge containers have ZERO credentials — the git service receives the GitHub token as a bind-mounted read-only file (written from the host keyring) and is the sole credential holder, communicating with github.com from the internal `tillandsias-enclave` network. Forge containers reach the git service via the enclave network only, with no direct external access.

| Aspect | State |
|--------|-------|
| GitHub token in forge | ZERO — never mounted, never delivered |
| Claude API key in forge | Env var, scoped to forge-claude profile only (planned migration to file delivery) |
| Forge external network | ZERO — enclave only, all traffic via proxy |
| Credential exfiltration risk | No credentials exist in forge to exfiltrate |
| Git push flow | forge pushes to git service (enclave) -> git service authenticates via `/run/secrets/github_token` (read-only bind from host keyring) -> pushes to remote |
| Git clone flow | Clone from git mirror service at startup (mirror-only, no fallback) |
| GitHub Login | `tillandsias --github-login` runs `gh auth login` in an ephemeral git-service-image container, host extracts the token, writes it to the OS keyring, tears the container down |

See `docs/cheatsheets/enclave-architecture.md` for the full enclave design, container types, and network topology.

@trace spec:enclave-network, spec:proxy-container

## Related

**Specs:**
- `openspec/specs/secrets-management/` — credential delivery pipeline
- `openspec/specs/native-secrets-store/` — keyring backend
- `openspec/specs/gh-auth-script/` — interactive `--github-login` flow

**Source files:**
- `src-tauri/src/secrets.rs` — keyring storage, retrieval, ephemeral token files
- `src-tauri/src/launch.rs` — volume mount assembly, security flags, secret bind mounts
- `src-tauri/src/runner.rs` — `--github-login` flow
- `src-tauri/src/handlers.rs` — git service launch, tray "GitHub Login" dispatch
- `crates/tillandsias-core/src/container_profile.rs` — `SecretKind::GitHubToken`, `LaunchContext::token_file_path`

**Cheatsheets:**
- `docs/cheatsheets/token-rotation.md` — how token rotation works inside the git service
- `docs/cheatsheets/logging-levels.md` — how to use `--log-secrets-management`
- `docs/cheatsheets/os-vault-credentials.md` — OS keyring APIs (GNOME, KDE, macOS, Windows)
- `docs/cheatsheets/github-credential-tools.md` — how gh, GCM, and git credential helpers store tokens

## Provenance

- https://docs.rs/keyring/latest/keyring/ — keyring crate v4.0.0; platform-neutral API for OS credential vaults (libsecret, Keychain, Wincred); `use_native_store()` selects the platform default
- https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html — OWASP Secrets Management Cheat Sheet; key guidance: never hardcode secrets, encrypt at rest and in transit, audit all access, automate rotation, revoke immediately on compromise
- **Last updated:** 2026-04-27
