## Why

The move to a "full battery" hard-installed forge image in the
`zen-default-with-ollama-analysis-pool` change superseded the runtime
tools overlay for claude/opencode/openspec. Agents now live at
`/usr/local/bin/` inside the forge image, symlinked from `/opt/agents/`,
baked at `podman build` time with deterministic versions.

Leaving the runtime overlay in place was actively harmful:

- Every `Attach Here` re-ran `build-tools-overlay.sh` which spawned a
  temporary forge container, re-installed the same three agents via
  npm + curl, and bind-mounted the result read-only at `/home/forge/.tools`.
- The OpenCode installer inside the overlay container dropped its
  binary at `/root/.opencode/bin/opencode` — not the overlay-target path —
  so every run logged `OpenCode: FAILED (binary not found)` and the
  overlay build exited non-zero.
- The non-fatal failure produced a scary error in the debug log and
  wasted 7+ seconds per attach doing work whose output was already in
  the image.
- The old entrypoints still hard-coded `/home/forge/.tools/<tool>/bin`
  as the canonical path. They were updated to `/usr/local/bin/...` in
  the prior change, but the mount continued to dangle.

Tombstone the entire subsystem. Image-baked agents are the single path.

## What Changes

### Deleted

- `scripts/build-tools-overlay.sh` (347 lines).
- `src-tauri/src/tools_overlay.rs` (1486 lines).
- `mod tools_overlay;` in `main.rs`.
- `MountSource::ToolsOverlay` enum variant.
- `ProfileMount { host_key: MountSource::ToolsOverlay, ... }` from
  `common_forge_mounts()`.
- `embedded::BUILD_TOOLS_OVERLAY` const + its write_lf call + its
  chmod +x call.
- `is_proxy_healthy()` in `handlers.rs` (only consumer was the overlay).

### Updated

- All `crate::tools_overlay::ensure_tools_overlay(...)` and
  `spawn_background_update()` / `build_overlay_for_init()` call sites in
  `main.rs`, `handlers.rs`, `init.rs`, `runner.rs`, `launch.rs` replaced
  by short comment blocks explaining the tombstone.
- Unit tests in `container_profile.rs` and `launch.rs` updated:
  `forge_profiles_have_tools_overlay_mount` →
  `forge_profiles_have_no_tools_overlay_mount`;
  `tools_overlay_expected_paths` → `agents_are_hard_installed_paths`.
- Forge profile mount count drops from 3 → 2 (ConfigOverlay + ContainerLogs).

### Unchanged

- `ConfigOverlay` mount stays — config (opencode config.json, MCP
  scripts, instructions) still lives on tmpfs and is bind-mounted
  read-only. That's the *config* overlay, not the *tools* overlay.
- Forge entrypoints (already pointed at `/usr/local/bin/` in the prior
  change).

## Capabilities

### Removed Capabilities

- `layered-tools-overlay` — superseded. The tools portion was
  responsible for runtime-installed agents; that responsibility moved
  to the forge Containerfile in `spec:default-image`. The *config*
  portion stays under `spec:opencode-web-session` /
  `spec:default-image`.

### Modified Capabilities

- `default-image` — gains a requirement that agents MUST be image-baked
  (no runtime install).
- `podman-orchestration` — gains "forge profiles MUST NOT mount
  `/home/forge/.tools`".

## Impact

- **Rust**: ~1500 LOC deleted, ~15 call sites simplified.
- **Shell**: 347-line script deleted.
- **Image**: forge Containerfile unchanged (already has agents baked).
- **User-visible**: attach time drops ~7s per launch; the debug log no
  longer includes the `OpenCode: FAILED` false alarm.
- **No behavior regression**: opencode + claude + openspec already
  resolve to the hard-installed binaries because `/usr/local/bin` is
  first on the PATH inside the forge.
