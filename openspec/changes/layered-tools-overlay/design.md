## Context

Tillandsias forge containers are ephemeral (`--rm`). Code comes from a git mirror service, packages flow through a caching proxy, and the container has zero credentials. Every launch currently runs install scripts for AI coding tools:

| Tool | Install mechanism | Time (cold) | Time (warm via proxy) |
|------|-------------------|-------------|----------------------|
| Claude Code | `npm install -g @anthropic-ai/claude-code` | 30-60s | 15-30s |
| OpenCode | `curl -fsSL https://opencode.ai/install \| bash` | 10-20s | 5-10s |
| OpenSpec | `npm install -g @fission-ai/openspec` | 10-20s | 5-10s |

"Warm" assumes the proxy has cached HTTP responses, but HTTPS content is not cached (splice-all mode). npm and curl both use HTTPS, so the proxy provides limited benefit for these installs.

The forge image is rebuilt infrequently (every few weeks) and is large (~500MB compressed). Baking tools into the image couples their release cadence to the image rebuild cadence. The tools update weekly or more.

The `~/.cache/tillandsias/` directory was previously bind-mounted into containers for install caching, but forge containers no longer have any host bind-mounts (Phase 3: code comes from git mirror, no project dir mount). The cache mount was removed as part of the credential-free enclave architecture.

## Goals / Non-Goals

**Goals:**
- Eliminate per-launch tool installation delay (target: 0 additional seconds for tools)
- Decouple tool version lifecycle from forge image lifecycle
- Share tools across all containers (read-only, no per-container duplication)
- Background updates: detect new versions and rebuild overlay without blocking user
- Graceful fallback: if overlay is absent, fall back to inline install (current behavior)
- Cross-platform: works on Linux (podman), macOS (podman machine), Windows (podman machine)

**Non-Goals:**
- Changing the forge image build process itself
- Adding new tools to the overlay (scope limited to OpenCode, Claude Code, OpenSpec)
- Modifying proxy caching (HTTPS interception) -- that is a separate concern
- Supporting user-customizable tool sets in the overlay

## Alternatives Evaluated

### Alternative 1: Podman Named Volume (read-only mount)

**Approach:** Create a named podman volume, populate it by running a temporary builder container, then mount it `ro` into forge containers.

```bash
# Create and populate
podman volume create tillandsias-tools
podman run --rm \
    -v tillandsias-tools:/tools \
    tillandsias-forge:v0.1.90 \
    bash -c 'npm install -g --prefix /tools/openspec @fission-ai/openspec && ...'

# Mount read-only in forge containers
podman run --rm \
    -v tillandsias-tools:/home/forge/.cache/tillandsias:ro \
    tillandsias-forge:v0.1.90 \
    /usr/local/bin/entrypoint-forge-claude.sh
```

**Pros:** Native podman primitive. Cross-platform (volumes work on podman machine). Atomic replacement possible (create new volume, swap name).

**Cons:** Named volumes on podman machine (macOS/Windows) are stored inside the VM, harder to inspect. Read-only mount means the container entrypoint cannot write update stamps to the same location -- need a separate writable layer for per-container state. Volume locking semantics are unclear (can you mount a volume RO while another process writes to it?). No podman-native "seal" operation.

**Verdict:** Viable but operationally complex. Volume management adds podman-specific state to reason about.

### Alternative 2: Host Directory Bind-Mount (read-only)

**Approach:** Maintain a host directory (`~/.cache/tillandsias/tools-overlay/`) populated by a builder script or temporary container. Mount it `ro` into forge containers.

```bash
# Populate on host (or via temporary container)
TOOLS_DIR="$HOME/.cache/tillandsias/tools-overlay/v1"
mkdir -p "$TOOLS_DIR"
podman run --rm \
    -v "$TOOLS_DIR:/output" \
    tillandsias-forge:v0.1.90 \
    bash -c '
        npm install -g --prefix /output/claude @anthropic-ai/claude-code
        npm install -g --prefix /output/openspec @fission-ai/openspec
        curl -fsSL https://opencode.ai/install | OPENCODE_INSTALL_DIR=/output/opencode bash
    '

# Mount read-only in forge containers
podman run --rm \
    -v "$TOOLS_DIR:/home/forge/.tools:ro" \
    tillandsias-forge:v0.1.90 \
    /usr/local/bin/entrypoint-forge-claude.sh
```

**Pros:** Simple. Inspectable on the host filesystem. Cross-platform (bind-mounts work everywhere podman runs). Easy versioning: use subdirectories (`v1/`, `v2/`) and swap symlinks. No podman-specific state. Rust code can check directory existence and version stamps directly. Can run update builds in the background without affecting running containers (build to a new directory, swap symlink atomically).

**Cons:** On macOS/Windows with podman machine, the directory must be in a host path that is mapped into the VM (typically `$HOME`). `~/.cache/tillandsias/` is already under `$HOME`, so this works. Slightly less "container-native" than a volume.

**Verdict:** Recommended. Simplest, most portable, easiest to reason about.

### Alternative 3: Second Image Layer (multi-stage / overlay image)

**Approach:** Build a lightweight "tools" image on top of the forge image. Use podman's built-in layering.

```dockerfile
FROM tillandsias-forge:v0.1.90
RUN npm install -g @anthropic-ai/claude-code
RUN npm install -g @fission-ai/openspec
RUN curl -fsSL https://opencode.ai/install | bash
```

Tag as `tillandsias-forge-tools:v0.1.90-tools.3` and launch containers from this image instead of the base forge image.

**Pros:** True image layering -- podman handles storage and dedup. No bind-mounts needed. Clean conceptual model.

**Cons:** Creates a new image on every tools update. Image storage grows (each tools update adds ~200MB). Requires rebuilding whenever either the forge image OR tools update. Couples the two lifecycles instead of decoupling them. Image building is slower than directory population. Cannot share tools across different forge image versions without rebuilding.

**Verdict:** Rejected. Couples lifecycles -- the opposite of what we want.

### Alternative 4: Podman `--mount type=image` (image as read-only mount)

**Approach:** Build a minimal tools-only image (not based on forge) and mount it into forge containers.

```bash
# Build a minimal tools image
podman build -t tillandsias-tools:v3 - <<'EOF'
FROM scratch
COPY --from=builder /tools /tools
EOF

# Mount as read-only filesystem
podman run --rm \
    --mount type=image,src=tillandsias-tools:v3,dst=/home/forge/.tools,rw=false \
    tillandsias-forge:v0.1.90
```

**Pros:** True read-only. Image dedup via podman storage. Conceptually clean.

**Cons:** `--mount type=image` is not supported on all podman versions. Requires building a full container image. Not available on podman machine (macOS/Windows) in older versions. More complex than bind-mounts for no clear benefit in this use case.

**Verdict:** Rejected. Not portable enough.

### Alternative 5: systemd-nspawn overlay

**Verdict:** Rejected immediately. Not portable (Linux-only, systemd-specific), not available inside podman containers.

## Recommended Architecture: Host Directory Bind-Mount

### Directory Layout

```
~/.cache/tillandsias/
+-- tools-overlay/
    +-- current -> v3/          # Symlink to active version
    +-- v3/                     # Active tools directory
    |   +-- claude/             # Claude Code npm prefix
    |   |   +-- bin/claude
    |   |   +-- lib/node_modules/
    |   +-- opencode/           # OpenCode binary
    |   |   +-- bin/opencode
    |   +-- openspec/           # OpenSpec npm prefix
    |   |   +-- bin/openspec
    |   |   +-- lib/node_modules/
    |   +-- .manifest.json      # Version stamps and metadata
    +-- v4/                     # Being built (next version)
    |   +-- ...
    +-- v2/                     # Previous version (kept for rollback)
```

### Manifest File (`.manifest.json`)

```json
{
  "version": 4,
  "created": "2026-04-05T14:30:00Z",
  "forge_image": "tillandsias-forge:v0.1.90",
  "tools": {
    "claude": {
      "version": "1.0.34",
      "installed": "2026-04-05T14:30:05Z"
    },
    "opencode": {
      "version": "0.25.1",
      "installed": "2026-04-05T14:30:18Z"
    },
    "openspec": {
      "version": "1.2.3",
      "installed": "2026-04-05T14:30:22Z"
    }
  }
}
```

### Lifecycle

#### 1. Create (first launch, no overlay exists)

```
User launches tillandsias <path>
  |
  v
ensure_tools_overlay()
  |
  +-- Is ~/.cache/tillandsias/tools-overlay/current a valid symlink?
  |     |
  |     NO --> Build tools overlay (blocking, first time only)
  |     |       |
  |     |       +-- mkdir v1/
  |     |       +-- podman run --rm -v v1:/output forge-image bash -c 'install tools to /output'
  |     |       +-- Write .manifest.json
  |     |       +-- ln -sfn v1 current
  |     |       +-- Continue to container launch
  |     |
  |     YES --> Check for updates (non-blocking, background)
  |              |
  |              +-- Read .manifest.json
  |              +-- Compare versions against latest (GitHub releases / npm registry)
  |              +-- If stale: spawn background update task
  |              +-- Continue to container launch immediately (use current overlay)
  |
  v
Launch forge container with -v current:/home/forge/.tools:ro
```

#### 2. Populate (builder container)

The overlay is populated by running a temporary container from the forge image itself. This ensures binary compatibility -- tools are installed in the same environment where they will run.

```bash
#!/usr/bin/env bash
# scripts/build-tools-overlay.sh
# Populates a tools overlay directory using a temporary forge container.
# @trace spec:layered-tools-overlay

set -euo pipefail

OUTPUT_DIR="${1:?Usage: build-tools-overlay.sh <output-dir>}"
FORGE_IMAGE="${2:-tillandsias-forge:v0.1.90}"

mkdir -p "$OUTPUT_DIR"/{claude,opencode,openspec}

# Use the proxy if available (enclave network)
PROXY_ARGS=()
if podman network exists tillandsias-enclave 2>/dev/null; then
    PROXY_ARGS=(
        --network=tillandsias-enclave
        -e HTTP_PROXY=http://proxy:3128
        -e HTTPS_PROXY=http://proxy:3128
        -e http_proxy=http://proxy:3128
        -e https_proxy=http://proxy:3128
    )
fi

# Install all tools in a single container run to minimize overhead
podman run --rm --init \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --userns=keep-id \
    --security-opt=label=disable \
    "${PROXY_ARGS[@]}" \
    -v "$OUTPUT_DIR:/output:rw" \
    --entrypoint bash \
    "$FORGE_IMAGE" \
    -c '
        set -euo pipefail

        # Claude Code
        echo "[tools-overlay] Installing Claude Code..."
        npm install -g --prefix /output/claude @anthropic-ai/claude-code 2>&1

        # OpenSpec
        echo "[tools-overlay] Installing OpenSpec..."
        npm install -g --prefix /output/openspec @fission-ai/openspec 2>&1

        # OpenCode
        echo "[tools-overlay] Installing OpenCode..."
        export OPENCODE_INSTALL_DIR=/output/opencode
        curl -fsSL https://opencode.ai/install | bash 2>&1
        # Relocate if installer ignored OPENCODE_INSTALL_DIR
        if [ ! -x /output/opencode/bin/opencode ] && [ -f ~/.opencode/bin/opencode ]; then
            mkdir -p /output/opencode/bin
            cp ~/.opencode/bin/opencode /output/opencode/bin/opencode
            chmod +x /output/opencode/bin/opencode
        fi

        echo "[tools-overlay] Done."
    '
```

#### 3. Seal (mark as complete)

After the builder container exits successfully, the Rust code:
1. Writes `.manifest.json` with tool versions (queried from the installed binaries)
2. Updates the `current` symlink atomically: `ln -sfn v<N> current`

The symlink swap is atomic on all POSIX filesystems. Running containers still see the old directory (they hold open file descriptors). New containers get the new version.

On Windows (podman machine), the symlink is inside the VM filesystem, not the Windows host. This works because `~/.cache/tillandsias/` is mounted into the VM.

#### 4. Update Detection

Background task runs after container launch (not blocking):

```
fn check_tools_versions(manifest: &Manifest) -> Vec<ToolUpdate> {
    // For each tool, check latest version:
    // - Claude Code: npm view @anthropic-ai/claude-code version
    // - OpenSpec: npm view @fission-ai/openspec version
    // - OpenCode: GitHub releases API (curl https://api.github.com/repos/.../releases/latest)
    //
    // Compare against manifest.tools[name].version
    // Return list of tools that need updating
}
```

Rate-limited to once per 24 hours (stamp file at `~/.cache/tillandsias/tools-overlay/.last-update-check`).

#### 5. Update Application

When updates are detected:

```
Spawn background task:
  1. Create new directory v<N+1>/
  2. Run builder container to populate v<N+1>/
  3. Write .manifest.json
  4. Atomically swap symlink: current -> v<N+1>
  5. Delete v<N-1> (keep one rollback version)
```

Running containers are unaffected -- they hold the old directory via the bind-mount. The next container launch picks up the new version through the `current` symlink.

#### 6. Mount into Forge Containers

Add to `common_forge_mounts()` in `container_profile.rs`:

```rust
fn common_forge_mounts() -> Vec<ProfileMount> {
    vec![
        ProfileMount {
            host_key: MountSource::ToolsOverlay,  // New variant
            container_path: "/home/forge/.tools",
            mode: MountMode::Ro,
        },
    ]
}
```

Add `ToolsOverlay` to `MountSource` enum and resolve it in `resolve_mount_source()`:

```rust
MountSource::ToolsOverlay => {
    let overlay_path = ctx.cache_dir.join("tools-overlay").join("current");
    overlay_path.display().to_string()
}
```

#### 7. Entrypoint Modifications

Each entrypoint checks for pre-installed tools at `/home/forge/.tools/` before falling back to install:

```bash
# In entrypoint-forge-claude.sh
TOOLS_DIR="/home/forge/.tools"
CC_BIN="$TOOLS_DIR/claude/bin/claude"

if [ -x "$CC_BIN" ]; then
    # Tools overlay present -- use pre-installed binary
    trace_lifecycle "install" "claude-code: using tools overlay ($("$CC_BIN" --version 2>/dev/null || echo "unknown"))"
    export PATH="$TOOLS_DIR/claude/bin:$PATH"
else
    # Fallback: install inline (first launch or overlay not ready)
    install_claude
    update_claude
fi
```

Same pattern for OpenCode and OpenSpec in their respective entrypoints.

### Container Mount Diagram

```
Host filesystem                           Container filesystem
-------------------                       --------------------

~/.cache/tillandsias/
  tools-overlay/
    current/ ----bind-mount, ro------>  /home/forge/.tools/
      claude/                             claude/bin/claude
      opencode/                           opencode/bin/opencode
      openspec/                           openspec/bin/openspec
      .manifest.json                      .manifest.json
```

### Edge Cases

#### First Launch (no overlay exists)

The entrypoints detect the absence of tools at `/home/forge/.tools/` and fall back to inline install (current behavior). Meanwhile, `ensure_tools_overlay()` in the Rust code builds the overlay in the background. The next launch will be instant.

Alternatively, `ensure_tools_overlay()` could block on first launch to build the overlay before starting the container. This adds ~30s to the very first launch but guarantees all subsequent launches are instant. Given that first launch already takes time (image pull, git service setup, etc.), this is acceptable.

**Recommendation:** Block on first launch. The user is already waiting for infrastructure setup. Adding tools overlay build to that one-time cost is better than having the first container launch also be slow.

#### Update Race (user launches during rebuild)

The symlink `current` points to the old version while the new version is being built. The container launches with the old overlay (correct, fast). When the new version is ready, the symlink swaps. Next launch gets the new version. No race condition.

#### Platform Differences

| Platform | `~/.cache/tillandsias/` location | Symlink support | Bind-mount support |
|----------|----------------------------------|-----------------|-------------------|
| Linux | Native filesystem | Yes (POSIX) | Native |
| macOS | Mapped into podman VM | Yes (POSIX, inside VM) | Via virtiofs/9p |
| Windows | Mapped into podman VM | Yes (inside WSL2 VM) | Via 9p mount |

On macOS and Windows, the tools overlay directory lives on the host filesystem but is accessed through the podman machine's filesystem mapping. Bind-mounts work because podman machine automatically maps `$HOME` (or a configured set of paths) into the VM.

**Potential issue on macOS:** virtiofs/9p performance for many small files (node_modules) may be slower than native. Mitigation: the overlay is read-only, so the performance penalty is limited to initial file reads which get cached by the VM's page cache.

#### Disk Space

| Tool | Approximate installed size |
|------|---------------------------|
| Claude Code | ~100 MB (npm tree) |
| OpenCode | ~30 MB (single binary) |
| OpenSpec | ~50 MB (npm tree) |
| **Total per version** | **~180 MB** |
| **Two versions** (current + rollback) | **~360 MB** |

This is modest. The forge image itself is ~500 MB compressed.

#### Version Pinning

The overlay tracks "latest" by default. This matches current behavior (entrypoints install latest on every launch). For reproducibility, the manifest records exact versions, enabling future support for:
- Pinning to a specific version in project config (`.tillandsias/config.toml`)
- Rolling back to a previous overlay version

**For initial implementation:** Track latest, no pinning.

#### Forge Image Version Mismatch

If the forge image is upgraded but the tools overlay was built against the old image, there could be glibc or library incompatibilities. The manifest records `forge_image` to detect this:

```
if manifest.forge_image != current_forge_image_tag {
    // Rebuild overlay against new forge image
    trigger_overlay_rebuild();
}
```

This is a rare event (forge image updates every few weeks) and the rebuild is fast (~30s).

## Performance Estimates

| Scenario | Current (install-on-launch) | With tools overlay |
|----------|----------------------------|-------------------|
| First launch ever | 30-60s tool install | 30-60s overlay build (one-time, blocking) |
| Subsequent launches | 15-30s tool install | 0s (mount pre-built directory) |
| After tool update | 15-30s install | 0s (background rebuild, old version still works) |
| After forge image update | 30-60s tool install | 30-60s overlay rebuild (one-time, auto-triggered) |

**Net improvement:** Every launch after the first saves 15-60 seconds. For a user launching 5-10 containers per day, this saves 2-10 minutes of waiting time daily.

## Implementation Plan

### Phase 1: Core Infrastructure (MVP)
1. Add `scripts/build-tools-overlay.sh` -- shell script to populate overlay directory
2. Add `MountSource::ToolsOverlay` to container profiles
3. Add tools overlay mount to `common_forge_mounts()`
4. Add `ensure_tools_overlay()` to `handlers.rs` enclave setup
5. Modify entrypoints to detect and use pre-mounted tools
6. Add `.manifest.json` read/write to Rust code

### Phase 2: Background Updates
1. Add version checking (npm view, GitHub API)
2. Add background overlay rebuild task
3. Add symlink rotation (keep one rollback)
4. Add 24-hour rate limiting on version checks
5. Wire update notifications into tray menu / CLI output

### Phase 3: Cross-Platform Validation
1. Test on macOS with podman machine (virtiofs performance)
2. Test on Windows with podman machine (9p performance)
3. Test symlink behavior inside podman machine VMs
4. Test concurrent container launches sharing the overlay

## Risks / Trade-offs

### Risk: Node.js module path resolution inside read-only mount
npm installs create symlinks and `.bin/` wrappers that encode absolute paths. If the install path inside the builder container (`/output/claude/`) differs from the mount path inside the forge container (`/home/forge/.tools/claude/`), the binaries may fail to resolve their dependencies.

**Mitigation:** The builder container must install to a path that matches the mount path. Either:
- Mount the output directory at `/home/forge/.tools` inside the builder container too, OR
- Use `--prefix /home/forge/.tools/claude` in the builder so npm records the correct paths

This is the highest-risk item and should be validated early in Phase 1.

### Risk: OpenCode binary compatibility across images
The OpenCode binary is a Go static binary that should be portable. But the Nix image variant needs a dynamic linker wrapper (see `_make_opencode_wrapper()` in the entrypoint). If the overlay is built against a Fedora image but mounted into a Nix image, the wrapper won't exist.

**Mitigation:** Build overlays per-image-variant (Fedora vs Nix). Currently only Fedora is used, so this is future-proofing.

### Risk: macOS virtiofs performance
Many small files in node_modules may be slow over virtiofs. Measured data needed.

**Mitigation:** If severe, consider packing the overlay as a squashfs image and loop-mounting it read-only. This is a future optimization.

### Risk: Symlink atomicity on Windows
Windows NTFS supports symlinks but they require elevated privileges or Developer Mode. Inside WSL2/podman-machine, POSIX symlinks work natively. As long as the tools overlay directory lives inside the podman machine's filesystem (it does, since `~/.cache/` is mapped), this is not an issue.

**Mitigation:** None needed for initial implementation. Verify during Phase 3.
