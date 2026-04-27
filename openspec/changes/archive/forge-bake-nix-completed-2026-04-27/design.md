## Context

The forge currently lacks nix tooling, yet `forge-cache-architecture` already bakes a `/nix/store` mount point as the shared cache entry point. To unlock deterministic, reproducible builds with nix flakes, we must add nix + direnv + nix-direnv to the forge image and configure shell hooks so `.envrc` files auto-activate on `cd`.

Single-user nix mode (no daemon) is sufficient — the forge is ephemeral, and the shared `/nix/store/` mount is read from the immutable image layer while new builds populate it from the host.

## Goals / Non-Goals

**Goals:**
- Install nix, direnv, and nix-direnv into the forge image
- Configure `/etc/nix/nix.conf` to enable experimental features (`nix-command`, `flakes`)
- Add direnv shell hooks to bash, zsh, and fish so `.envrc` files auto-activate
- Set `NIX_CONFIG` and `NIX_PATH` env vars in the entrypoint so flakes work out of the box
- Verify `/nix/store` mount is usable and enable `trust-on-first-use` for user-built artifacts
- Test nix version and `nix flake` commands to confirm functionality

**Non-Goals:**
- Multi-user nix daemon (unnecessary for ephemeral forge containers)
- Nix IDE integrations or direnv UI enhancements
- Automated flake caching strategies (deferred to per-project decisions)
- Documentation of nix flake authoring (that's in `cheatsheets/build/nix-flake-basics.md`)

## Decisions

### Decision 1: Single-user nix mode, not multi-user daemon
**Choice:** Install nix via the standard `curl | sh` installer in single-user mode.
**Rationale:** The forge is ephemeral; daemon overhead is wasted. The `/nix/store/` mount point (from `forge-cache-architecture`) provides the shared cache layer. Single-user nix reads from and writes to the mounted store without daemon coordination.
**Alternatives considered:** Multi-user daemon would require `nix-daemon` systemd service, which adds complexity and persistence concerns in a container context. Single-user is simpler and sufficient.

### Decision 2: Direnv shell hooks for auto-activation
**Choice:** Add `eval "$(direnv hook bash)"`, `eval "$(direnv hook zsh)"`, and `direnv hook fish | source` to the respective shell configs.
**Rationale:** Projects with `.envrc` files expect automatic activation on `cd`. Without hooks, agents must manually invoke `direnv allow` and `direnv exec`, breaking the transparent containerization goal.
**Alternatives considered:** A global direnv trigger in the entrypoint would be fragile (only works for one shell session). Per-shell hooks ensure every shell type (bash, zsh, fish) honors `.envrc` automatically.

### Decision 3: nix-direnv for performance
**Choice:** Install nix-direnv alongside direnv to cache evaluations and prevent repeated flake rebuilds on every `cd`.
**Rationale:** Full nix flake evaluation on every directory change is slow (5-10 seconds per `cd`). nix-direnv caches the evaluation and only re-evaluates if `flake.nix` or `flake.lock` changes. Critical for interactive usability.
**Alternatives considered:** Pure direnv without caching would work but create a horrible UX with sluggish directory navigation. Not acceptable.

### Decision 4: Experimental features baked into /etc/nix/nix.conf
**Choice:** Set `experimental-features = nix-command flakes` in `/etc/nix/nix.conf` (image-wide).
**Rationale:** Nix flakes require these features. Baking them into the image means every project gets them by default without per-project setup.
**Alternatives considered:** Setting via environment variable (`NIX_CONFIG`) would work but is fragile if a project has its own `nix.conf`. Image-level baking is more reliable.

### Decision 5: NIX_CONFIG and NIX_PATH in entrypoint
**Choice:** Export `NIX_CONFIG=/etc/nix/nix.conf` and `NIX_PATH=nixpkgs=flake:nixpkgs` in the entrypoint so flakes auto-resolve nixpkgs without a `flake.lock` entry.
**Rationale:** Projects may not have a `flake.lock` yet. Setting `NIX_PATH` provides a fallback so `nix flake show` and other commands work interactively without project-level setup.
**Alternatives considered:** Requiring every project to have `flake.lock` would be brittle; providing a sensible default reduces friction.

### Decision 6: Use Fedora microdnf if nix is available, otherwise curl installer
**Choice:** Check if nix is available in Fedora's minimal repos; if not, fall back to the official `curl | sh` installer.
**Rationale:** Reduces image build complexity and dependency on external installers if the distro ships nix. Fedora minimal repos as of 43 may not include nix (needs verification), so the curl installer is the reliable fallback.
**Alternatives considered:** Always use curl installer bypasses distro package management but is more reliable and reproducible.

## Risks / Trade-offs

**[Risk] nix single-user mode has no isolation from container root**
→ Mitigation: The forge runs as non-root user (uid 1000). nix respects file permissions. The `/nix/store` mount is mounted read-only from the host, and build outputs are validated. This is acceptable for dev containers.

**[Risk] direnv adds startup latency to every new shell**
→ Mitigation: nix-direnv caching mitigates this for stable `.envrc` files. Projects with unstable flakes (frequently changing `flake.nix`) will see slower shells, but that's a project-level optimization concern, not a forge issue.

**[Risk] /nix/store mount point depends on forge-cache-architecture**
→ Mitigation: forge-cache-architecture is already shipped (merged to main). This change only adds the nix layer on top of existing mount infrastructure. If the mount is missing, nix will fail gracefully with a clear error.

**[Risk] Experimental features may change in future nix versions**
→ Mitigation: nix-command and flakes are now stable and unlikely to break. If breaking changes occur, we update the cheatsheet and CLAUDE.md methodology. This is acceptable technical debt for now.

## Migration Plan

1. **Image build** (CI/CD or manual): Rebuild forge image with nix + direnv + nix-direnv installed and `/etc/nix/nix.conf` configured.
2. **Shell config update** (this change): Add direnv hooks to bashrc, zshrc, config.fish.
3. **Entrypoint update** (this change): Export NIX_CONFIG and NIX_PATH.
4. **Verification** (testing): `podman run forge nix --version && nix flake --help` must succeed.
5. **Rollout**: New forge containers automatically use the updated image. Existing containers are unaffected (they keep the old image).

No special rollback needed — old images remain on disk; new containers simply use the newer version.

## Open Questions

1. Is nix available in Fedora minimal 43 repos, or must we use the curl installer? (Implementation will reveal this.)
2. Should we set `nix.conf` options like `max-jobs` or `cores` for the forge, or leave them at defaults?
3. Should projects be instructed to commit `flake.lock`, or is it optional?

These are non-blocking for implementation — defaults are reasonable and can be refined per-project.
