## 1. Git Service Container Image

- [ ] 1.1 Create `images/git/Containerfile` — Alpine + git + gh CLI, non-root user, git-daemon ready
- [ ] 1.2 Create `images/git/entrypoint.sh` — start git daemon with `--export-all --enable=receive-pack` on `/srv/git`
- [ ] 1.3 Create `images/git/post-receive-hook.sh` — template hook that pushes to origin if configured
- [ ] 1.4 Register `git` image type in `build-image.sh`
- [ ] 1.5 Test: `build-image.sh git` builds successfully under 20MB

## 2. Mirror Management

- [ ] 2.1 Add `detect_project_git_state()` function — returns enum: `RemoteRepo(url)`, `LocalRepo`, `NotGitRepo`
- [ ] 2.2 Add `ensure_mirror()` function — creates/updates bare mirror at `~/.cache/tillandsias/mirrors/<project>/`
- [ ] 2.3 Handle non-git project: `git init` + initial commit before mirroring
- [ ] 2.4 Install post-receive hook into mirror's `hooks/` directory
- [ ] 2.5 Test: mirror creation for repo with remote, repo without remote, and non-git directory

## 3. Git Service Container Profile & Lifecycle

- [ ] 3.1 Add `git_service_profile()` to `container_profile.rs` — enclave network, D-Bus mounts, mirror volume
- [ ] 3.2 Add `git_image_tag()` to `handlers.rs`
- [ ] 3.3 Add `ensure_git_service_running()` to `handlers.rs` — start per-project git service if not running
- [ ] 3.4 Add `stop_git_service()` to `handlers.rs` — stop when last forge for project stops
- [ ] 3.5 Add `TILLANDSIAS_GIT_SERVICE` env var to forge profiles pointing to git-service hostname
- [ ] 3.6 Wire git service lifecycle into `handle_attach_here()`, `handle_terminal()`, CLI `runner::run()`

## 4. Forge Entrypoint Changes

- [ ] 4.1 Modify `entrypoint-forge-opencode.sh` to clone from git mirror before launching agent
- [ ] 4.2 Modify `entrypoint-forge-claude.sh` to clone from git mirror before launching agent
- [ ] 4.3 Add retry logic (5 attempts, 1s delay) for git clone in case git service isn't ready
- [ ] 4.4 Configure git remote in cloned repo to push back to git-service

## 5. Accountability Window

- [ ] 5.1 Add `GitManagement` variant to `AccountabilityWindow` in `cli.rs`
- [ ] 5.2 Add `--log-git` flag parsing in `parse_log_flags()`
- [ ] 5.3 Add git log targets to `logging.rs`
- [ ] 5.4 Add `@trace spec:git-mirror-service` annotations to all new code
- [ ] 5.5 Update USAGE string with `--log-git`

## 6. GitHub Login Integration

- [ ] 6.1 Modify `handle_github_login()` to run `gh auth login` in git service container instead of forge
- [ ] 6.2 Handle case where no git service is running (start temporary one)
- [ ] 6.3 Update `gh-auth-login.sh` to work in git service container context

## 7. Testing & Verification

- [ ] 7.1 Run `cargo test --workspace` — all existing tests pass
- [ ] 7.2 Test: `build-image.sh git` builds successfully
- [ ] 7.3 Test: git service starts and git daemon is reachable from enclave
- [ ] 7.4 Test: forge container can clone from `git://git-service/<project>`
- [ ] 7.5 Test: push from forge → mirror → remote (with post-receive hook)
- [ ] 7.6 Test: credential refresh via tray GitHub Login works mid-session
- [ ] 7.7 Test: non-git directory auto-initialized and served through mirror
