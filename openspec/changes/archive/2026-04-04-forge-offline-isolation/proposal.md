## Why

Phases 1-2 established the enclave network, proxy, and git mirror. But forge containers still have credential mounts (GitHub token, hosts.yml, Claude dir) and the project directory is still mounted directly. Phase 3 completes the isolation: forge containers become fully offline with zero credentials. Code comes exclusively from the git mirror, packages through the proxy. This is the security payoff — AI agents can no longer exfiltrate data or read secrets.

## What Changes

- **BREAKING**: Remove GitHub token file mount from forge profiles (no more `/run/secrets/github_token`)
- **BREAKING**: Remove `hosts.yml` mount from forge profiles (no more `/home/forge/.config/gh/`)
- **BREAKING**: Remove `GIT_ASKPASS` env var from forge containers
- **BREAKING**: Remove Claude dir mount from forge-claude profile (auth handled differently)
- **BREAKING**: Remove direct project directory mount from forge containers — code comes from git mirror clone only
- Forge entrypoint switches from fallback mode to mirror-only (remove `.mirror` suffix, clone directly to `/home/forge/src/<project>`)
- Remove git config mount from forge (git identity comes from mirror's config)
- Update forge container to use enclave-only network (already done in Phase 1, but now enforce — no bridge fallback)
- GitHub Login rerouted to git service container (has D-Bus + credentials)

## Capabilities

### New Capabilities
- `forge-offline`: Forge container isolation — no credentials, no direct network, no project mount

### Modified Capabilities
- `environment-runtime`: Forge profile stripped of all credential mounts and project mount; entrypoint is mirror-clone-only
- `podman-orchestration`: Forge security model — enclave-only network enforced, no secrets
- `gh-auth-script`: GitHub Login runs in git service container instead of standalone forge

## Impact

- **Modified crates**: `tillandsias-core` (forge profiles stripped of secrets/mounts)
- **Modified binaries**: `src-tauri/src/launch.rs` (verify no credentials), `src-tauri/src/handlers.rs` (GitHub Login reroute)
- **Modified scripts**: `images/default/entrypoint-*.sh` (mirror-only clone), `gh-auth-login.sh` (git service context)
- **Breaking**: Any workflow that relied on direct project mount or credential access inside forge will break
