---
tags: [cache, architecture, storage, tillandsias]
languages: []
since: 2026-05-03
last_verified: 2026-05-03
sources:
  - internal
authority: internal
status: draft
tier: bundled
---

# Cache Architecture

@trace spec:overlay-mount-cache, spec:tools-overlay-fast-reuse

**Use when**: Understanding how Tillandsias caches container overlays, tool layers, and build artifacts.

## Provenance

- Internal architecture documentation
- **Last updated:** 2026-05-03

## Cache Model

Tillandsias uses a tiered cache:

1. **Shared cache (read-only)** — Nix-built image layers
   - Built at forge build time
   - Bind-mounted read-only into all containers
   - Survives container restarts (immutable)

2. **Per-project cache (read-write)** — project-specific overlays
   - Created on first container start
   - Persists across container lifecycle
   - Binds to `~/.cache/tillandsias/<project>/`

3. **Project workspace** — source code and configurations
   - Mounted at `/workspace` in container
   - User's actual project directory
   - Outside container lifecycle

4. **Ephemeral layer** — container writable filesystem
   - Temporary, lost on container stop
   - Used for runtime state and logs
   - No persistence intended

## Key Properties

- **Zero overlap**: project A never sees project B's cache
- **Reproducible**: same tooling across restarts (from shared cache)
- **Isolated**: each project sandbox has independent state
- **Efficient**: shared layers reduce storage and startup time

## Cache Staleness

Shared cache is refreshed at image build time. Per-project cache is user-managed:
- Clearing `~/.cache/tillandsias/<project>/` resets project state
- Clearing entire `~/.cache/tillandsias/` resets all projects

## Related Specs

- `spec:layered-tools-overlay` — tools layer management
- `spec:tools-overlay-fast-reuse` — overlay optimization
- `spec:init-incremental-builds` — incremental build caching

## See Also

- `cheatsheets/runtime/container-lifecycle.md` — container lifecycle
- `cheatsheets/build/podman-image-management.md` — image caching
