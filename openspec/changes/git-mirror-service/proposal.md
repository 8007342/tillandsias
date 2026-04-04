## Why

Phase 1 introduced the enclave network and proxy. But credentials (GitHub token, hosts.yml) are still mounted directly into forge containers. The git mirror service eliminates this by isolating all git/GitHub operations into a dedicated container that owns the credentials. Forge containers clone from the mirror — they never touch credentials or the remote.

This also enables multiple containers per project (each gets its own working tree from the mirror) and ensures uncommitted work is lost on container stop (commits persist through the mirror to the host filesystem).

## What Changes

- Build a `tillandsias-git` container image (Alpine + git + gh + git-daemon)
- Add project initialization flow: detect git state (repo with remote, repo without remote, not a git repo) and create/update a bare mirror at `~/.cache/tillandsias/mirrors/<project>/`
- Git service container runs `git daemon` on the enclave network, serving mirrors for clone/fetch/push
- D-Bus session bus forwarded into git service for host keyring access (GitHub credentials)
- post-receive hook auto-pushes to remote origin when configured
- Forge containers clone from `git://git-service/<project>` instead of direct mount
- Support credential refresh: tray "GitHub Login" runs `gh auth login` in the git service container
- Add `--log-git` accountability window for mirror sync, clone/push events, remote push results
- Add git service lifecycle management (per-project, starts/stops with forge containers)

## Capabilities

### New Capabilities
- `git-mirror-service`: Bare mirror management, git daemon, post-receive hooks, D-Bus credential forwarding, project initialization

### Modified Capabilities
- `environment-runtime`: Forge entrypoint clones from git mirror instead of using direct project mount; multiple containers per project supported
- `podman-orchestration`: Git service container lifecycle, per-project mirror volumes
- `runtime-logging`: New `--log-git` accountability window
- `gh-auth-script`: GitHub Login runs in git service container (has D-Bus) instead of forge

## Impact

- **New files**: `images/git/Containerfile`, `images/git/entrypoint.sh`, `images/git/post-receive-hook.sh`
- **Modified crates**: `tillandsias-core` (git service profile, mirror types), `tillandsias-podman` (container inspect helpers)
- **Modified binaries**: `src-tauri/src/handlers.rs` (git service lifecycle, mirror init), `src-tauri/src/runner.rs` (CLI mirror init), `src-tauri/src/cli.rs` (--log-git flag)
- **Modified scripts**: `gh-auth-login.sh` (credential refresh through git service), `build-image.sh` (git image type)
- **Image build**: New `tillandsias-git:v{VER}` image, ~10-15MB (Alpine-based)
