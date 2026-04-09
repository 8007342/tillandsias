## Phase 1: Core Infrastructure (MVP)

- [x] **P1-1**: Create `scripts/build-tools-overlay.sh` -- shell script that runs a temporary forge container to install Claude Code, OpenCode, and OpenSpec into an output directory. Must use matching container paths (`/home/forge/.tools/`) for npm prefix resolution. @trace spec:layered-tools-overlay
- [x] **P1-2**: Add `MountSource::ToolsOverlay` variant to `MountSource` enum in `crates/tillandsias-core/src/container_profile.rs`. Add `tools_overlay_dir: Option<PathBuf>` to `LaunchContext`. @trace spec:layered-tools-overlay
- [x] **P1-3**: Add tools overlay mount to `common_forge_mounts()` in `container_profile.rs`. Mount at `/home/forge/.tools` with `MountMode::Ro`. @trace spec:layered-tools-overlay
- [x] **P1-4**: Resolve `MountSource::ToolsOverlay` in `resolve_mount_source()` in `src-tauri/src/launch.rs`. Resolve to `cache_dir/tools-overlay/current`. Skip mount if path does not exist (graceful fallback). @trace spec:layered-tools-overlay
- [x] **P1-5**: Add `ensure_tools_overlay()` function to `src-tauri/src/handlers.rs`. On first launch: run builder script, write manifest, create symlink. On subsequent launches: validate symlink, check forge image version match. @trace spec:layered-tools-overlay
- [x] **P1-6**: Wire `ensure_tools_overlay()` into `ensure_enclave_ready()` / `ensure_infrastructure_ready()` call chain. @trace spec:layered-tools-overlay
- [x] **P1-7**: Modify `images/default/entrypoint-forge-claude.sh` -- check `/home/forge/.tools/claude/bin/claude` before calling `install_claude()`. @trace spec:layered-tools-overlay
- [x] **P1-8**: Modify `images/default/entrypoint-forge-opencode.sh` -- check `/home/forge/.tools/opencode/bin/opencode` before calling `ensure_opencode()`. @trace spec:layered-tools-overlay
- [x] **P1-9**: Modify `images/default/lib-common.sh` -- modify `install_openspec()` to check `/home/forge/.tools/openspec/bin/openspec` first. @trace spec:layered-tools-overlay
- [x] **P1-10**: Add `.manifest.json` read/write utilities to Rust code (serde struct, read from overlay dir, write after builder completes). @trace spec:layered-tools-overlay
- [x] **P1-11**: Validate npm path resolution -- confirm that `claude` and `openspec` binaries installed with `--prefix /home/forge/.tools/<tool>` inside the builder container resolve their node_modules correctly when mounted at the same path inside forge containers. @trace spec:layered-tools-overlay
- [x] **P1-12**: Add tests for overlay mount presence/absence in podman args (similar to existing `forge_has_no_project_dir_mount` test pattern). @trace spec:layered-tools-overlay

## Phase 2: Background Updates

- [x] **P2-1**: Add version checking functions -- query npm registry for Claude Code and OpenSpec latest versions, query GitHub releases API for OpenCode latest version. @trace spec:layered-tools-overlay
- [x] **P2-2**: Add 24-hour rate limiting for version checks (stamp file at `tools-overlay/.last-update-check`). @trace spec:layered-tools-overlay
- [x] **P2-3**: Implement background overlay rebuild -- create new versioned directory, run builder, swap symlink atomically, clean up old versions (keep one rollback). @trace spec:layered-tools-overlay
- [x] **P2-4**: Wire background update check into post-launch flow (after container starts, spawn non-blocking task). @trace spec:layered-tools-overlay
- [x] **P2-5**: Add forge image version comparison to `ensure_tools_overlay()` -- trigger blocking rebuild if manifest's `forge_image` does not match current tag. @trace spec:layered-tools-overlay
- [x] **P2-6**: Add CLI/tray notification for overlay status (building, updated, up-to-date). @trace spec:layered-tools-overlay

## Phase 3: Cross-Platform Validation

- [ ] **P3-1**: Test overlay on macOS with podman machine -- verify bind-mount through virtiofs, symlink behavior, npm path resolution. @trace spec:layered-tools-overlay
- [ ] **P3-2**: Test overlay on Windows with podman machine -- verify bind-mount through 9p, symlink behavior inside WSL2 VM. @trace spec:layered-tools-overlay
- [ ] **P3-3**: Test concurrent container launches sharing the same read-only overlay -- verify no contention or file locking issues. @trace spec:layered-tools-overlay
- [ ] **P3-4**: Measure macOS virtiofs performance for node_modules reads -- determine if squashfs optimization is needed. @trace spec:layered-tools-overlay
