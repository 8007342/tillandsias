---
tags: [credentials, keyring, vault, github, podman]
since: 2026-05-22
last_verified: 2026-05-22
authority: high
status: current
---

# OS Vault Credentials

Tillandsias stores the GitHub OAuth token in the host operating system's
native credential vault:

- Linux: Secret Service via `keyring`
- macOS: Keychain via `keyring`
- Windows: Credential Manager via `keyring`

The host Rust process is the only code that reads or writes that token.

## How it is used

1. `tillandsias --github-login` captures the token from an ephemeral git-image container.
2. The host stores the token in the native vault.
3. When the git service starts, the host creates the `tillandsias-github-token` podman secret.
4. The git service reads `/run/secrets/tillandsias-github-token` directly.

## Important properties

- No container talks to the keyring directly.
- No active path uses a bind-mounted token file or `GIT_ASKPASS`.
- Git identity is stored separately in `~/.cache/tillandsias/secrets/git/.gitconfig`.

## Validation

- `gh auth token` should only run inside the ephemeral login container.
- `podman secret ls` should show `tillandsias-github-token` while the tray is active.
- `podman inspect` should not reveal token values.
