## 1. Strip Credentials from Forge Profiles

- [ ] 1.1 Remove `SecretKind::GitHubToken` from `forge_opencode_profile()` secrets
- [ ] 1.2 Remove `SecretKind::GitHubToken` and `SecretKind::ClaudeDir` from `forge_claude_profile()` secrets
- [ ] 1.3 Remove `GIT_ASKPASS` related env var handling (it was injected by launch.rs for GitHubToken)
- [ ] 1.4 Remove `SecretKind::GitHubToken` from `terminal_profile()` secrets
- [ ] 1.5 Update all profile tests (secret counts, env var counts)

## 2. Strip Direct Mounts from Forge Profiles

- [ ] 2.1 Remove `MountSource::ProjectDir` from `common_forge_mounts()` — code comes from git clone
- [ ] 2.2 Remove `MountSource::SecretsSubdir("gh")` from `common_forge_mounts()` — no hosts.yml
- [ ] 2.3 Remove `MountSource::SecretsSubdir("git")` from `common_forge_mounts()` — no git config
- [ ] 2.4 Keep `MountSource::CacheDir` — build caches are still needed
- [ ] 2.5 Add `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` env vars from global config (replaces git config mount)
- [ ] 2.6 Update `common_forge_mounts()` tests (mount count: 4 → 1)
- [ ] 2.7 Update launch.rs tests that verify mount strings

## 3. Forge Entrypoint — Mirror Only

- [ ] 3.1 Update `entrypoint-forge-opencode.sh` — remove fallback to direct mount, clone to primary path
- [ ] 3.2 Update `entrypoint-forge-claude.sh` — same as opencode
- [ ] 3.3 Update `entrypoint-terminal.sh` — terminal also clones from mirror (maintenance mode)
- [ ] 3.4 Add git identity setup in entrypoint from env vars (`git config user.name`, `git config user.email`)
- [ ] 3.5 Add agent reminder message about committing work before stopping

## 4. GitHub Login Reroute

- [ ] 4.1 Update `handle_github_login()` to exec into running git service or start temporary one
- [ ] 4.2 Remove the standalone forge-based `gh-auth-login.sh` terminal launch
- [ ] 4.3 Update CLI `run_github_login()` to use git service container
- [ ] 4.4 Test: GitHub Login works with and without running git service

## 5. Cleanup & Verification

- [ ] 5.1 Remove `write_hosts_yml_from_keyring()` calls from forge launch paths (no longer needed)
- [ ] 5.2 Remove `token_files::write_token()` calls from forge launch paths (no longer needed)
- [ ] 5.3 Keep token infrastructure for git service container (it still uses token as fallback)
- [ ] 5.4 Run `cargo test --workspace` — all tests pass
- [ ] 5.5 Verify: forge container has zero credential mounts in podman args
- [ ] 5.6 Verify: forge container has no project directory mount
- [ ] 5.7 Update `docs/cheatsheets/secret-management.md` — Phase 3 is now active
