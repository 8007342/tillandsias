## Phase 1: Create Cheatsheet Documents

- [ ] 1.1 Create `docs/cheatsheets/` directory.
- [ ] 1.2 Write `docs/cheatsheets/secret-management.md` covering:
    - Overview of secret types (GitHub OAuth, Claude API key, git identity)
    - Keyring storage model (service: `tillandsias`, keys: `github-oauth-token`, `claude-api-key`)
    - Token file lifecycle (write to tmpfs, mount at `/run/secrets/github_token:ro`, refresh, delete)
    - Container mount strategy (project:rw, cache:rw, gh:ro, git:rw, token-file:ro)
    - hosts.yml dual-path explanation and removal timeline
    - OpenCode deny list for `/run/secrets/`
    - Failure modes table (keyring locked, tmpfs unavailable, token file write fail)
    - Security model (what is protected, what is not)
    - Related specs: `native-secrets-store`, `secret-rotation`, `secrets-management`
    - Related source: `src-tauri/src/secrets.rs`, `src-tauri/src/token_file.rs`, `src-tauri/src/launch.rs`
- [ ] 1.3 Write `docs/cheatsheets/logging-levels.md` covering:
    - The six module names (`secrets`, `containers`, `updates`, `scanner`, `menu`, `events`) with descriptions
    - The five log levels (`off`, `error`, `warn`, `info`, `debug`, `trace`) with usage guidelines
    - CLI syntax: `--log=module:level;module:level`
    - Accountability windows: `--log-secret-management`, `--log-image-management`, `--log-update-cycle`
    - Combining `--log` with `--log-*` flags
    - Log file locations per platform
    - Environment variable override: `TILLANDSIAS_LOG`
    - Example commands for common debugging scenarios
    - Related specs: `logging-accountability`, `runtime-logging`
    - Related source: `src-tauri/src/logging.rs`, `src-tauri/src/accountability.rs`, `src-tauri/src/cli.rs`
- [ ] 1.4 Write `docs/cheatsheets/token-rotation.md` covering:
    - Why short-lived tokens matter (blast radius, persistence, `/proc/*/environ`)
    - The 55-minute refresh task (tokio interval, atomic write, same token for now)
    - GIT_ASKPASS mechanism (helper script, `x-access-token` username, token file read)
    - Atomic write pattern (`.tmp` file, rename, POSIX guarantees)
    - Three-layer cleanup (container stop, app exit, Drop guard)
    - Platform-specific tmpfs paths ($XDG_RUNTIME_DIR, $TMPDIR, %TEMP%)
    - Failure mode table (keyring lock, tmpfs full, rename fail, SIGKILL)
    - Roadmap to GitHub App installation tokens (Phase 2-4 of fine-grained-pat-rotation)
    - Security comparison: before vs after vs future
    - Related specs: `secret-rotation`, `fine-grained-pat-rotation`
    - Related source: `src-tauri/src/token_file.rs`, `src-tauri/src/event_loop.rs`

## Phase 2: Cross-Reference Validation

- [ ] 2.1 After `logging-accountability-framework` implementation: verify that every `Cheatsheet:` path in accountability output resolves to a real file in `docs/cheatsheets/`.
- [ ] 2.2 After `secret-rotation-tokens` implementation: verify that the `token-rotation.md` cheatsheet accurately describes the implemented mechanism. Update any discrepancies (monotonic convergence).
- [ ] 2.3 Add a CI check (optional, low priority): verify that all `docs/cheatsheets/*.md` files referenced in source code exist. Can be a simple grep + file-exists check in the CI script.

## Phase 3: Future Cheatsheets (as accountability windows are implemented)

- [ ] 3.1 When `--log-image-management` accountability window is implemented: create `docs/cheatsheets/image-management.md` covering forge image build, staleness detection, auto-build, pruning old versions.
- [ ] 3.2 When `--log-update-cycle` accountability window is implemented: create `docs/cheatsheets/update-cycle.md` covering version check, download, verify, apply, restart, rollback.
