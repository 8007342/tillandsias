## Why

Forge containers are ephemeral — every `git push`, `gh pr create`, or authenticated GitHub API call fails because credentials don't survive container recreation. Users must re-authenticate on every Attach Here, which breaks the "just works" promise.

## What Changes

- Mount a persistent `secrets/` directory from the host cache into forge containers
- Bind-mount `~/.config/gh` (GitHub CLI auth) and `~/.gitconfig` (git identity) so credentials persist across container lifecycles
- Update the container entrypoint to ensure mount targets exist before tools access them

## Capabilities

### New Capabilities
<!-- None — this extends the existing environment-runtime capability -->

### Modified Capabilities
- `environment-runtime`: Containers now mount git and GitHub CLI credentials from a persistent secrets directory in the cache

## Impact

- Both `handlers.rs` (tray mode) and `runner.rs` (CLI mode) gain new volume mounts
- The entrypoint script ensures target directories exist inside the container
- No new dependencies — uses existing cache directory infrastructure
- Credentials never leave the user's machine (mounted read/write from host filesystem)
