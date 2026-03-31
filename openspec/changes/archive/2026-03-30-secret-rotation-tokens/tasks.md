## Phase 1: Token File Infrastructure

This phase creates the module for writing, reading, and cleaning up token files on tmpfs.

- [ ] 1.1 Create `src-tauri/src/token_file.rs` module with `token_base_dir() -> PathBuf` function. Resolves the tmpfs-backed base directory: `$XDG_RUNTIME_DIR/tillandsias/tokens/` on Linux, `$TMPDIR/tillandsias/tokens/` on macOS, `%TEMP%\tillandsias\tokens\` on Windows. Falls back through the chain if earlier options are unavailable.
- [ ] 1.2 Add `token_file::write(container_name: &str, token: &str) -> Result<PathBuf, String>` function. Creates `<base>/<container_name>/` directory with mode 0700. Writes token to `github_token.tmp` with mode 0600. Atomically renames to `github_token`. Returns the full path to the token file. Logs to accountability window.
- [ ] 1.3 Add `token_file::delete(container_name: &str)` function. Removes the `<base>/<container_name>/` directory and its contents. Best-effort (no error if already gone). Logs to accountability window.
- [ ] 1.4 Add `token_file::delete_all()` function. Removes the entire `<base>/` directory tree. Called on app exit. Logs count of deleted token files to accountability window.
- [ ] 1.5 Create `TokenCleanupGuard` struct that holds the base directory path. Implement `Drop` to call `delete_all()`. This ensures cleanup on panic.
- [ ] 1.6 Add `mod token_file;` declaration to `main.rs`.
- [ ] 1.7 Add unit tests for `token_file`: write creates file with correct permissions, write is atomic (no partial reads), delete removes file and directory, delete_all removes all, token_base_dir resolves correctly on each platform (use `cfg(test)` overrides).

## Phase 2: GIT_ASKPASS Script in Forge Image

This phase adds the credential helper script to the forge container image.

- [ ] 2.1 Create `images/default/git-askpass-tillandsias` script file with the GIT_ASKPASS helper contents. Script reads `/run/secrets/github_token` for password, returns `x-access-token` for username. Must be executable (0755), owned by root in the image.
- [ ] 2.2 Update `flake.nix` to include the script at `/usr/local/bin/git-askpass-tillandsias` in the forge image. Ensure it is in the image's `PATH`.
- [ ] 2.3 Manual test: build the forge image with `scripts/build-image.sh forge --force`, enter a container, verify the script exists at the expected path with correct permissions.

## Phase 3: Container Profile and Launch Integration

This phase wires the token file into the container launch path.

- [ ] 3.1 Add `SecretKind::GitHubToken` variant to `crates/tillandsias-core/src/container_profile.rs`. This represents "mount the GitHub token file at /run/secrets/github_token".
- [ ] 3.2 Add `token_file_path: Option<PathBuf>` field to `LaunchContext` in `container_profile.rs`.
- [ ] 3.3 Add `SecretMount { kind: SecretKind::GitHubToken }` to `forge_opencode_profile()`, `forge_claude_profile()`, and `terminal_profile()`. The web profile does NOT get this secret.
- [ ] 3.4 Update `build_podman_args()` in `src-tauri/src/launch.rs` to handle `SecretKind::GitHubToken`: if `ctx.token_file_path` is `Some(path)`, add `-v <path>:/run/secrets/github_token:ro` and `-e GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias`.
- [ ] 3.5 Update `build_launch_context()` in `src-tauri/src/handlers.rs` to: (a) retrieve token from keyring, (b) call `token_file::write()`, (c) set `token_file_path` in the `LaunchContext`.
- [ ] 3.6 Update `runner.rs` CLI mode to do the same: write token file before launch, set `token_file_path`.
- [ ] 3.7 Update unit tests in `launch.rs`: verify `GitHubToken` secret produces the correct `-v` and `-e` args. Verify web profile does NOT have the token mount.
- [ ] 3.8 Update unit tests in `container_profile.rs`: forge and terminal profiles now have `GitHubToken` in their secrets list.

## Phase 4: Refresh Task

This phase adds the host-side tokio task that periodically rewrites the token file.

- [ ] 4.1 Add `token_file::spawn_refresh_task(tracked: Arc<Mutex<HashSet<String>>>) -> JoinHandle<()>` function. The task runs `tokio::time::interval(Duration::from_secs(55 * 60))`. On each tick, for each container name in `tracked`, retrieve the token from the keyring and rewrite the token file atomically.
- [ ] 4.2 Add `tracked_containers: Arc<Mutex<HashSet<String>>>` to the main event loop state. When a container starts (AttachHere/Terminal), insert the container name. When a container stops (podman die event), remove it.
- [ ] 4.3 Spawn the refresh task in `main.rs` alongside the scanner and podman event tasks. Pass the `tracked_containers` handle.
- [ ] 4.4 Add unit test: mock the interval, verify refresh writes new file content, verify untracked containers are skipped.

## Phase 5: Cleanup Integration

This phase wires the cleanup logic into the event loop and app lifecycle.

- [ ] 5.1 In `event_loop.rs`, when a podman `die` or `stop` event is received for a tracked container, call `token_file::delete(&container_name)`. Remove the container from the `tracked_containers` set.
- [ ] 5.2 In `main.rs`, create `TokenCleanupGuard` early in `main()` (before Tauri setup). The guard's `Drop` will call `delete_all()` on exit.
- [ ] 5.3 In the `RunEvent::ExitRequested` handler in `main.rs`, explicitly call `token_file::delete_all()` before the guard has a chance to run (belt-and-suspenders).
- [ ] 5.4 Add integration test: start a mock container, verify token file exists, stop the container, verify token file is deleted. Exit the app, verify the entire tokens directory is gone.

## Phase 6: Accountability Logging

This phase adds accountability-tagged spans to all token file operations. Depends on `logging-accountability-framework` being implemented; if not yet available, use standard `info!`/`debug!` logging with the same messages (they will be upgraded to accountability spans later).

- [ ] 6.1 Add accountability-tagged spans to `token_file::write()`: `[secrets] Token written for <container> -> /run/secrets/... (tmpfs, ro mount)`.
- [ ] 6.2 Add accountability-tagged spans to `token_file::delete()`: `[secrets] Token revoked for <container> (container stopped)`.
- [ ] 6.3 Add accountability-tagged spans to the refresh task tick: `[secrets] Token refreshed for <container> (55min rotation)`.
- [ ] 6.4 Add accountability-tagged spans to `token_file::delete_all()`: `[secrets] All token files cleaned up (app exit, <N> files removed)`.
- [ ] 6.5 Add accountability-tagged span to fallback path: `[secrets] WARN: tmpfs unavailable, falling back to hosts.yml mount for <container>`.
- [ ] 6.6 Manual test: run `tillandsias --log-secret-management <project>`, verify all token lifecycle events appear in the accountability output.
