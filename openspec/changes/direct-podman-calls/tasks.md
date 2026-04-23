## Phase 1: Direct gh/podman calls for GitHub Login

### 1.1 Add gh CLI discovery to Rust
- [x] `gh-auth-login.sh` already has the priority logic (host gh > container fallback)
- [ ] Add a `find_gh_path()` function (similar to `find_podman_path()`) that checks known locations: `gh`, `/usr/bin/gh`, `/usr/local/bin/gh`, `~/.local/bin/gh`, and on Windows `C:\Program Files\GitHub CLI\gh.exe` / winget paths
- [ ] Return `Option<PathBuf>` -- `None` means fall back to container

### 1.2 Implement direct GitHub Login handler for Windows
- [ ] In `handle_github_login`, add `#[cfg(target_os = "windows")]` block that:
  - Finds host `gh` via `find_gh_path()`
  - Sets `GH_CONFIG_DIR` to the managed secrets directory
  - Reads existing git identity from managed gitconfig
  - Opens terminal with: `gh auth login --git-protocol https`
  - After auth completes, runs `gh auth setup-git`
- [ ] Skip `write_temp_script("gh-auth-login.sh", ...)` on Windows entirely
- [ ] Test on Windows: GitHub Login works without Git Bash installed

### 1.3 Implement direct GitHub Login handler for all platforms
- [ ] Extend the Windows implementation to work on Linux and macOS
- [ ] For host-gh path: spawn terminal with `gh auth login --git-protocol https`
- [ ] For container fallback: build podman command with security flags, D-Bus forwarding (Linux), and volume mounts
- [ ] Terminal command format: `podman run -it --rm --cap-drop=ALL --security-opt=no-new-privileges --userns=keep-id -v <gh-dir>:/home/forge/.config/gh -v <git-dir>:/home/forge/.config/tillandsias-git <forge-image> gh auth login --git-protocol https`
- [ ] Remove `embedded::GH_AUTH_LOGIN` constant
- [ ] Remove `gh-auth-login.sh` from `include_str!` in `embedded.rs`

### 1.4 Handle git identity prompting
- [ ] Before opening the terminal for `gh auth login`, check if git identity exists in managed gitconfig
- [ ] If not set, either: (a) prompt in the terminal before launching gh, or (b) use a pre-command that sets git config then runs gh auth login
- [ ] Write identity via `git config --file <secrets-dir>/git/.gitconfig user.name "..."` etc.
- [ ] Preserve the re-authentication flow (detect existing creds, offer to re-auth)

### 1.5 Add @trace annotations
- [ ] Add `// @trace spec:direct-podman-calls` to the new gh discovery function
- [ ] Add `// @trace spec:direct-podman-calls, spec:secrets-management` to the direct GitHub Login handler
- [ ] Update existing `// @trace spec:gh-auth-script` references to include `spec:direct-podman-calls`

### 1.6 Test Phase 1
- [ ] Windows: GitHub Login works with host `gh` installed, no Git Bash required
- [ ] Windows: `./build-windows.sh --check` passes
- [ ] Linux: GitHub Login works with host `gh`
- [ ] Linux: GitHub Login works via container fallback (no host `gh`)
- [ ] macOS: GitHub Login works with host `gh`
- [ ] All platforms: security flags match those in `gh-auth-login.sh`
- [ ] All platforms: credentials stored in correct location

## Phase 2: Direct podman calls for image builds (all platforms)

### 2.1 Implement staleness detection in Rust
- [ ] Port `_compute_hash()` logic from `build-image.sh` to Rust: hash Containerfile + image source files
- [ ] Use the same cache directory for hash files (`~/.cache/tillandsias/build-hashes/` or platform equivalent)
- [ ] Compare current hash against cached hash; skip build if matching and image exists

### 2.2 Unify run_build_image_script across platforms
- [ ] Remove the `#[cfg(target_os = "windows")]` and `#[cfg(not(target_os = "windows"))]` blocks
- [ ] Replace with a single codepath: direct `podman build --tag <tag> -f <Containerfile> <context>`
- [ ] Preserve the build lock mechanism (`build_lock::acquire` / `build_lock::wait_for_build`)
- [ ] Preserve old image pruning (`prune_old_forge_images`)
- [ ] Apply `--security-opt label=disable` for SELinux compatibility

### 2.3 Remove embedded build-image.sh
- [ ] Remove `embedded::BUILD_IMAGE` constant
- [ ] Remove `build-image.sh` from `include_str!` in `embedded.rs`
- [ ] Update `extract_image_sources()` to no longer write `scripts/build-image.sh`
- [ ] The nix backend (if needed in future) can be handled separately

### 2.4 Remove embedded::bash_path
- [ ] After Phase 1 and 2 are both complete, remove the `bash_path` function from `embedded.rs`
- [ ] Remove any remaining MSYS2 path conversion logic
- [ ] Verify no other code depends on `bash_path`

### 2.5 Add @trace annotations
- [ ] Add `// @trace spec:direct-podman-calls, spec:default-image` to the unified build function
- [ ] Add `// @trace spec:direct-podman-calls` to the staleness detection code
- [ ] Update existing `@trace` in `run_build_image_script` to include `spec:direct-podman-calls`

### 2.6 Test Phase 2
- [ ] Linux: `./build.sh --test` passes
- [ ] Linux: forge image builds correctly via direct podman
- [ ] macOS: `./build-osx.sh --test` passes
- [ ] macOS: forge image builds correctly via direct podman
- [ ] Windows: `./build-windows.sh --check` passes
- [ ] Windows: forge image builds correctly (already working, verify no regression)
- [ ] Staleness detection: unchanged sources skip rebuild on all platforms
- [ ] Force rebuild: `--force` flag equivalent still works
- [ ] Web image: `build_image("web")` still works

## Phase 3: Cleanup (after both phases verified)

### 3.1 Update documentation
- [ ] Update CLAUDE.md if any build commands changed
- [ ] Update `docs/cheatsheets/` if affected
- [ ] Add notes to `gh-auth-login.sh` and `build-image.sh` headers indicating they are for manual use only, not invoked by the binary

### 3.2 Sync specs
- [ ] Update `gh-auth-script` spec to reflect that the script is no longer invoked at runtime
- [ ] Update `embedded-scripts` spec to reflect reduced scope
- [ ] Update `default-image` spec to reflect unified direct-podman build path
