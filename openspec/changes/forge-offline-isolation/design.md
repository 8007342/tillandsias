## Context

Phase 1 added the enclave network + proxy. Phase 2 added the git mirror service. Forge containers can now clone from the mirror and install packages through the proxy. But they still have credential mounts and a direct project mount as fallbacks. Phase 3 removes these fallbacks, making forge containers truly offline and credential-free.

@trace spec:forge-offline

## Goals / Non-Goals

**Goals:**
- Remove all credential mounts from forge profiles (token file, hosts.yml, Claude dir, git config)
- Remove direct project directory mount — code comes exclusively from git mirror
- Forge entrypoint: clone from mirror only, no fallback to direct mount
- GitHub Login rerouted to git service container
- Verify forge has zero external network access and zero credentials

**Non-Goals:**
- Inference container (Phase 4)
- Telemetry dashboard (Phase 5)
- Claude authentication redesign (future — needs separate credential service)

## Decisions

### D1: Remove all secrets from forge profiles
**Choice**: Strip `SecretKind::GitHubToken` from `forge_opencode_profile()` and both `GitHubToken` + `ClaudeDir` from `forge_claude_profile()`. Remove `GIT_ASKPASS` env var.
**Rationale**: Git operations go through the mirror (which has credentials). No need for tokens in forge.

### D2: Remove project directory mount
**Choice**: Remove `MountSource::ProjectDir` from `common_forge_mounts()`. Forge gets code only via `git clone` from the mirror.
**Rationale**: Direct mount allows reading/writing files outside of git. With mirror-only access, all changes must be committed — enforces git discipline and ensures persistence.

### D3: Keep cache mount
**Choice**: Keep `MountSource::CacheDir` in forge mounts — build caches (node_modules, target/, etc.) are still valuable.
**Rationale**: Reinstalling all packages on every container start would be too slow. Cache is safe — no credentials there.

### D4: Keep git config mount for identity only
**Choice**: Actually remove the git config mount too. Git identity (name, email) should come from the mirror's config or be set via env vars.
**Rationale**: Fewer mounts = less attack surface. Identity can be set via `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL` env vars from the global config.

### D5: GitHub Login in git service container
**Choice**: `handle_github_login()` execs into the running git service container (or starts a temporary one) instead of spawning a standalone forge.
**Rationale**: The git service already has D-Bus forwarding. No need for a separate container.

## Risks / Trade-offs

- **[Uncommitted work lost]** → By design. Agents must commit frequently. Instructions in entrypoint remind agents of this.
- **[Clone overhead]** → Mirror is local, clone is fast (~1 second for medium repos). Acceptable.
- **[Claude auth broken]** → Claude dir mount removed. Claude Code needs a different auth path. Add TODO for future credential service. For now, Claude auth happens on first launch inside the container — the mount removal means it won't persist across containers. This needs a solution.
- **[No direct file editing]** → Users can't `vim` a file in the container and have it appear on host. Must use git commit + push. This is the intended behavior.
