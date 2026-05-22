---
tags: [secrets, keyring, podman, credentials, security]
languages: [rust]
since: 2026-05-22
last_verified: 2026-05-22
authority: high
status: current
---

# Secrets Management

Tillandsias keeps credential handling split into two pieces:

1. The host Rust process is the only code that reads or writes the OS native
   keyring.
2. The git service container receives GitHub credentials only as the podman
   secret `tillandsias-github-token`, mounted at
   `/run/secrets/tillandsias-github-token`.

No active code path should use a bind-mounted token file or `GIT_ASKPASS`.

## Current Flow

### GitHub login

- The user runs `tillandsias --github-login` or clicks `GitHub Login` in the tray.
- The host launches an ephemeral container from the git image.
- The container runs `gh auth login` and `gh auth token`.
- The host stores the token in the OS native keyring.

### Git service launch

- The host creates the `tillandsias-github-token` podman secret from the keyring token.
- The git service container is launched with `--secret=tillandsias-github-token`.
- The git service reads `/run/secrets/tillandsias-github-token` directly.
- Forge and terminal containers receive no GitHub credential material.

### Git identity

- Git author name and email live in `~/.cache/tillandsias/secrets/git/.gitconfig`.
- That file contains identity metadata only.
- The launcher injects `GIT_AUTHOR_*` and `GIT_COMMITTER_*` from the cached identity.

## Validation

- `tillandsias --github-login` should succeed on a system with an unlocked keyring.
- `podman inspect` for the git service container should not reveal token values.
- `podman secret ls` should show `tillandsias-github-token` only while the tray is running.

## Related Specs

- `openspec/specs/native-secrets-store/spec.md`
- `openspec/specs/podman-secrets-integration/spec.md`
- `openspec/specs/git-mirror-service/spec.md`
