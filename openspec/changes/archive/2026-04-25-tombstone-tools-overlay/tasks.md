# tasks

## 1. Delete stale code

- [x] Delete `scripts/build-tools-overlay.sh`.
- [x] Delete `src-tauri/src/tools_overlay.rs`.
- [x] Remove `mod tools_overlay;` from `src-tauri/src/main.rs`.
- [x] Remove `embedded::BUILD_TOOLS_OVERLAY` const + write_lf + chmod call.
- [x] Remove `MountSource::ToolsOverlay` variant + all usages.
- [x] Remove `is_proxy_healthy` (last consumer was tools_overlay).

## 2. Update call sites

- [x] `main.rs` event loop: both `ensure_tools_overlay` call paths.
- [x] `handlers.rs`: all 4 call sites (2 ensure_tools_overlay, 3 spawn_background_update).
- [x] `init.rs`: `build_overlay_for_init`.
- [x] `runner.rs`: `build_overlay_for_init`.
- [x] `launch.rs`: match arm, stale comments, test rewrite.

## 3. Tests

- [x] Rename + update `forge_profiles_have_tools_overlay_mount`.
- [x] Rename + update `tools_overlay_expected_paths`.
- [x] Update `git_service_has_github_token_and_log_mount` for new env vars.
- [x] `cargo test --workspace --release` all green.

## 4. Spec convergence

- [x] Proposal + deltas under `openspec/changes/tombstone-tools-overlay/`.
- [x] Validates strict.
- [x] Archive.
