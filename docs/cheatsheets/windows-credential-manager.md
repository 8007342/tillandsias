---
tags: [windows, credential-manager, keyring, podman, secrets]
languages: [rust, powershell]
since: 2026-05-22
last_verified: 2026-05-22
authority: high
status: current
---

# Windows Credential Manager

Tillandsias uses the Windows Credential Manager through the Rust `keyring`
crate. The GitHub token stays in the host credential vault, then the host
creates a podman secret named `tillandsias-github-token` for the git service
container.

## What matters

- The host process is the only code that talks to Credential Manager.
- Containers do not see Wincred, D-Bus, or any keyring API.
- The git service reads `/run/secrets/tillandsias-github-token` directly.
- No active path uses a bind-mounted token file or `GIT_ASKPASS`.

## Login flow

1. User runs `tillandsias --github-login`.
2. The host launches an ephemeral git-image container.
3. `gh auth login` runs inside that container.
4. `gh auth token` returns the token to the host.
5. The host stores the token in Credential Manager.

## Runtime flow

1. The host retrieves the token from Credential Manager.
2. The host creates the `tillandsias-github-token` podman secret.
3. The git service container starts with `--secret=tillandsias-github-token`.
4. The git service reads `/run/secrets/tillandsias-github-token`.

## Validation

- `cmdkey /list` should show the GitHub entry only on the host.
- `podman inspect` for the git service should not expose the token value.
- `podman secret ls` should show `tillandsias-github-token` while the tray is active.
