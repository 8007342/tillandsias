---
tags: [secrets, retired, podman, github, credentials]
since: 2026-05-22
last_verified: 2026-05-22
authority: medium
status: retired
---

# Token Rotation

This cheatsheet described the old tmpfs token-file + `GIT_ASKPASS` flow.
That flow is retired.

## Current replacement

- `docs/cheatsheets/secrets-management.md`
- `openspec/specs/podman-secrets-integration/spec.md`
- `openspec/specs/git-mirror-service/spec.md`

The current runtime path is:

1. Host reads the GitHub token from the native keyring.
2. Host creates the `tillandsias-github-token` podman secret.
3. Git service reads `/run/secrets/tillandsias-github-token` directly.

No active code path should rely on `GIT_ASKPASS` or bind-mounted token files.
