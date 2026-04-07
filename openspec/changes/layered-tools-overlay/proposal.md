## Why

Every forge container launch downloads and installs OpenCode and OpenSpec from the internet before the user can begin work. On the Claude entrypoint, this means `npm install -g @anthropic-ai/claude-code` (large npm tree) plus `npm install -g @fission-ai/openspec`. On the OpenCode entrypoint, this means `curl | bash` for OpenCode plus the same npm install for OpenSpec. Even with the proxy cache (which only caches HTTP, not HTTPS content in splice-all mode), these installs take 15-60 seconds per launch. The cache at `~/.cache/tillandsias/` helps on subsequent launches within the same container, but forge containers are ephemeral (`--rm`) and code comes from the git mirror, so the cache directory is not currently mounted.

The forge image itself is rebuilt infrequently (weeks apart) and contains OS packages. OpenCode and OpenSpec update weekly or more. Baking them into the forge image would require frequent rebuilds of a large image. Installing them on every launch wastes time. Neither extreme is right.

## What Changes

Introduce a "tools overlay" layer between the immutable forge base image and the mutable per-container workspace. This layer contains pre-installed AI coding tools (OpenCode, Claude Code, OpenSpec) and is shared read-only across all containers. It is built once, updated in the background when new versions are detected, and mounted instantly on container start.

Architecture:

```
+---------------------------------------------+
|  Layer 3: Project workspace (mutable, rw)   |  git clone, user files
+---------------------------------------------+
|  Layer 2: Tools overlay (sealed, ro mount)  |  OpenCode, Claude Code, OpenSpec
+---------------------------------------------+
|  Layer 1: Forge base image (immutable)      |  Fedora + packages
+---------------------------------------------+
```

Container startup goes from "download + install tools (15-60s)" to "mount existing directory (0s)".

## Capabilities

### New Capabilities
- `layered-tools-overlay`: Pre-built tools layer shared across all containers, decoupling AI tool lifecycle from forge image lifecycle. Background updates, read-only mounts, instant container starts.

### Modified Capabilities
- `default-image`: Entrypoints detect pre-mounted tools at a well-known path and skip install steps. Fallback to inline install if tools layer is absent (first launch, update in progress).
- `forge-shell-tools`: OpenSpec installation moves from entrypoint to tools overlay builder. Entrypoints check for pre-installed binary first.
- `podman-orchestration`: New bind-mount for the tools overlay directory added to forge container profiles.

## Impact

- `images/default/lib-common.sh` -- modify `install_openspec()` to check overlay path first
- `images/default/entrypoint-forge-claude.sh` -- modify `install_claude()` to check overlay path first
- `images/default/entrypoint-forge-opencode.sh` -- modify `ensure_opencode()` to check overlay path first
- `crates/tillandsias-core/src/container_profile.rs` -- add tools overlay mount to `common_forge_mounts()`
- `src-tauri/src/launch.rs` -- resolve tools overlay path in `LaunchContext`
- `src-tauri/src/handlers.rs` -- add `ensure_tools_overlay()` to enclave setup
- `scripts/build-tools-overlay.sh` (new) -- script to populate the overlay directory
- New spec: `openspec/specs/layered-tools-overlay/spec.md`
