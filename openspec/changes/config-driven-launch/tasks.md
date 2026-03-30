## 1. Define ContainerProfile Types

- [ ] 1.1 Create `crates/tillandsias-core/src/container_profile.rs` with `ContainerProfile`, `ProfileMount`, `SecretMount`, `LaunchContext` structs
- [ ] 1.2 Implement `Default` for `ContainerProfile` (Claude forge as default)
- [ ] 1.3 Implement built-in profiles: `forge_opencode()`, `forge_claude()`, `terminal()`, `web()` as associated functions
- [ ] 1.4 Add `container_profile` module to `crates/tillandsias-core/src/lib.rs`
- [ ] 1.5 Write unit tests: each built-in profile produces expected entrypoint, mounts, env, secrets

## 2. Implement build_podman_args

- [ ] 2.1 Create `src-tauri/src/launch.rs` with `build_podman_args(profile: &ContainerProfile, context: &LaunchContext) -> Vec<String>`
- [ ] 2.2 Hardcode non-negotiable security flags at the start of the function (never from profile)
- [ ] 2.3 Implement mount key resolution: `"project"` -> `context.project_path`, `"cache"` -> `context.cache_dir`, `"secrets/gh"` -> `context.gh_dir`, etc.
- [ ] 2.4 Implement secret mount resolution: `"claude_dir"` -> `context.claude_dir` (if Some), `"claude_api_key"` -> env var injection (if Some)
- [ ] 2.5 Add GPU passthrough detection (Linux only)
- [ ] 2.6 Add custom mounts from project config (appended after profile mounts)
- [ ] 2.7 Write unit tests: verify correct args for each profile type, verify security flags always present, verify secrets only present for profiles that declare them

## 3. Refactor handlers.rs

- [ ] 3.1 Replace `build_run_args()` function body with: select profile based on agent + container type, build `LaunchContext`, call `build_podman_args()`
- [ ] 3.2 Refactor `handle_terminal()`: remove the 40-line format string, replace with profile lookup + `build_podman_args()` + `open_terminal()`
- [ ] 3.3 Refactor `handle_root_terminal()`: same as 3.2, with `is_watch_root = true` in context
- [ ] 3.4 Verify `handle_attach_here()` uses the refactored `build_run_args()`
- [ ] 3.5 Delete the old `build_run_args()` function after migration

## 4. Refactor runner.rs

- [ ] 4.1 Replace `runner.rs::build_run_args()` with profile lookup + `build_podman_args()` from the new `launch.rs` module
- [ ] 4.2 Handle the `bash` flag: use `terminal()` profile when `bash = true`, forge profile otherwise
- [ ] 4.3 Delete the old `build_run_args()` function

## 5. Add Version Field to Config

- [ ] 5.1 Add `version: Option<u32>` to `GlobalConfig` with default value 1
- [ ] 5.2 Add parsing logic: absent = 1, present = use value, > max_supported = log warning
- [ ] 5.3 Add `version: Option<u32>` to `ProjectConfig` with same semantics
- [ ] 5.4 Write unit tests: parse config with version=1, version absent, version=99 (unknown future version)

## 6. Test

- [ ] 6.1 `cargo test --workspace` — all existing tests pass
- [ ] 6.2 New unit tests for `build_podman_args()` with all four profile types
- [ ] 6.3 New unit tests for mount key resolution (project, cache, secrets, claude)
- [ ] 6.4 New unit tests for security flag enforcement (flags present regardless of profile)
- [ ] 6.5 Manual test: tray mode Attach Here (Claude) — verify correct mounts, env, entrypoint
- [ ] 6.6 Manual test: tray mode Maintenance — verify no Claude secrets mounted
- [ ] 6.7 Manual test: CLI mode `tillandsias <path>` — verify correct launch
- [ ] 6.8 Manual test: CLI mode `tillandsias --bash <path>` — verify terminal profile used
