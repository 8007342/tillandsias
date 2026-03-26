## Why

Tillandsias currently stores the GitHub OAuth token in plain text at `~/.cache/tillandsias/secrets/gh/hosts.yml`. This file is mounted read-only into forge containers, but on the host it sits unencrypted on disk. Any process running as the user can read it. On a shared machine or compromised host, this is a credential leak.

Every major desktop OS ships a native secret service (GNOME Keyring, macOS Keychain, Windows Credential Manager) specifically designed to store credentials encrypted at rest, unlocked only for the session. Tillandsias should use these instead of a plain YAML file.

## What Changes

- Add the `keyring` crate to the `src-tauri` binary for cross-platform native secret storage
- After `gh auth login` completes, read the OAuth token from `hosts.yml` and store it in the native keyring under service `tillandsias`, key `github-oauth-token`
- On container launch, retrieve the token from the keyring and write a temporary `hosts.yml` into the secrets directory so existing container mount logic continues to work
- Add a `secrets` module to `src-tauri` that encapsulates all keyring read/write/migrate logic
- On first run with an existing `hosts.yml` but no keyring entry, auto-migrate the token into the keyring

## Capabilities

### New Capabilities
- `native-secrets-store`: Store and retrieve the GitHub OAuth token using the host OS's native secret service instead of plain text files

### Modified Capabilities
- `gh-auth-script`: After authentication completes, the token is migrated from the `hosts.yml` file into the native keyring
- `environment-runtime`: Container launch reads the token from the keyring and writes a temporary `hosts.yml` for the container mount

## Impact

- New dependency: `keyring` crate (pure Rust, ~50KB, no C dependencies)
- Linux: requires `libdbus` (present on all GNOME/KDE systems; already available in the tillandsias toolbox)
- macOS: uses Security.framework (always present)
- Windows: uses Windows Credential Manager (always present)
- Graceful fallback: if the keyring is unavailable (headless server, SSH session), fall back to the existing plain text `hosts.yml`
- No changes to the container-side mount paths or the `gh` CLI behavior inside containers
