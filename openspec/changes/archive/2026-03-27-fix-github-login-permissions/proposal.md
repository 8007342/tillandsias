# Fix GitHub Login Permissions

## Why

When a user runs `gh auth login` inside the forge container, the git config
directory is mounted read-only (`:ro`). This causes the operation to fail with:

```
error: could not lock config file /home/forge/.config/tillandsias-git/.gitconfig: Read-only file system
```

`gh auth login` and `gh auth setup-git` need to write credential helper
configuration into `.gitconfig`. The current `:ro` mount prevents this.

## What Changes

Change the git config volume mount from `:ro` to `:rw` in all container launch
paths:

- `src-tauri/src/handlers.rs` — main forge launch (single-project and multi-project)
- `src-tauri/src/runner.rs` — runner launch path
- `src-tauri/src/github.rs` — clone and short-lived gh CLI operations
- `gh-auth-login.sh` — standalone auth login script

The gh config mount (`:ro`) remains unchanged -- it only needs to be read
during git operations, not written to from inside the container.

## Capabilities

- `gh auth login` succeeds inside forge containers
- `gh auth setup-git` can write credential helper config to `.gitconfig`
- Git push/pull with HTTPS authentication works after login

## Impact

- Minimal: only the mount mode flag changes from `ro` to `rw`
- Security: git config is user-owned data, not secrets -- writable is appropriate
- The gh CLI config directory stays read-only (correct behavior)
