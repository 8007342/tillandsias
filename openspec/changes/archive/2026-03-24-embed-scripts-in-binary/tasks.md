## 1. Embedded Scripts Module

- [x] 1.1 Create `src-tauri/src/embedded.rs` with `include_str!` constants for all scripts: `gh-auth-login.sh`, `scripts/build-image.sh`, `scripts/ensure-builder.sh`
- [x] 1.2 Add `include_str!` constants for image sources: `flake.nix`, `flake.lock`, `images/default/entrypoint.sh`, shell configs, skill files
- [x] 1.3 Implement `write_temp_script(name: &str, content: &str) -> Result<PathBuf>` — writes to `$XDG_RUNTIME_DIR/tillandsias/`, chmod 0700
- [x] 1.4 Implement `write_image_sources() -> Result<TempDir>` — writes full image source tree to a tempdir, returns the TempDir (auto-cleanup on drop)
- [x] 1.5 Add `mod embedded;` to crate root

## 2. Wire Into Handlers

- [x] 2.1 Update `handle_github_login()` in `handlers.rs` — use `embedded::write_temp_script("gh-auth-login.sh", embedded::GH_AUTH_LOGIN)` instead of `resolve_gh_auth_script()`
- [x] 2.2 Remove `resolve_gh_auth_script()` and `resolve_project_root()` from `handlers.rs`
- [x] 2.3 Update `run_build_image_script()` in `handlers.rs` — extract embedded scripts to temp, execute from there
- [x] 2.4 Update `run_build_image_script()` in `runner.rs` — same pattern
- [x] 2.5 Remove `resolve_project_root()` from `runner.rs`

## 3. Clean Up Install

- [x] 3.1 Remove script/flake/image installation from `build.sh --install` (keep only binary, libs, icons, desktop file)
- [x] 3.2 Remove `gh-auth-login.sh` installation from `build.sh --install`

## 4. Verification

- [x] 4.1 `cargo check --workspace` passes
- [x] 4.2 Verify `build.sh --install` no longer copies scripts to `~/.local/share/tillandsias/`
