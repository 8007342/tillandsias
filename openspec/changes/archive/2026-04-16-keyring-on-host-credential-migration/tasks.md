## 1. Purge hosts.yml from live code

- [x] 1.1 Remove `secrets/gh:/home/forge/.config/gh:ro` mount from `src-tauri/src/github.rs::build_gh_run_args` and `clone_repo`
- [x] 1.2 Simplify `src-tauri/src/launch.rs::ensure_secrets_dirs` to return only the git-identity dir (no `gh_dir`)
- [x] 1.3 Remove `cache/secrets/gh/hosts.yml` existence-check fallback from `src-tauri/src/menu.rs::needs_github_login`
- [x] 1.4 Remove all hosts.yml doc comments from `src-tauri/src/handlers.rs` (4 sites, no behavior change)
- [x] 1.5 Remove broken `GH_AUTH_LOGIN = include_str!(...)` from `src-tauri/src/embedded.rs` and the now-unused `ensure_gh_auth_login` extractor
- [x] 1.6 Delete top-level `gh-auth-login.sh` (the host wrapper it was made obsolete by the Rust `--github-login` path)

## 2. Purge hosts.yml from live specs + docs + shell

- [x] 2.1 Rewrite `openspec/specs/secret-management/spec.md` (singular) to drop D-Bus + hosts.yml requirements
- [x] 2.2 Rewrite `openspec/specs/native-secrets-store/spec.md` for keyring-only + delete auto-migration requirement
- [x] 2.3 Rewrite `openspec/specs/secret-rotation/spec.md` — drop hosts.yml fallback scenario
- [x] 2.4 Rewrite `openspec/specs/git-mirror-service/spec.md` — hosts.yml fallback scenario becomes hard-error
- [x] 2.5 Strip hosts.yml mention from `openspec/specs/forge-offline/spec.md` (comparative breadcrumb)
- [x] 2.6 Remove `mkdir -p ~/.config/gh` from `images/default/lib-common.sh`
- [x] 2.7 Rewrite `docs/cheatsheets/secret-management.md` for D-Bus-free architecture
- [x] 2.8 Update `docs/cheatsheets/token-rotation.md` — drop hosts.yml from failure-modes + phase tables
- [x] 2.9 Update `docs/cheatsheets/github-credential-tools.md` — drop `hosts.yml --insecure-storage` row
- [x] 2.10 Update `docs/cheatsheets/os-vault-credentials.md` — Headless/SSH security note
- [x] 2.11 Update `docs/cheatsheets/logging-levels.md` — drop hosts.yml refresh references
- [x] 2.12 Append keyring-only credential-flow paragraph to `CLAUDE.md` under Enclave Architecture
- [x] 2.13 Rewrite `SECRETS.md` (top-level) for host-keyring architecture
- [x] 2.14 Surgically update `docs/SECRETS.md` — remove `gh/` mount row from Secret Categories + Mount Strategy
- [x] 2.15 Final `rg 'hosts\.yml|\.config/gh|secrets/gh'` across live paths → zero matches

## 3. Consolidate spec dir `secret-management/` → `secrets-management/` (plural)

- [x] 3.1 Write merged content to `openspec/specs/secrets-management/spec.md` with `# secrets-management Specification` header
- [x] 3.2 Delete `openspec/specs/secret-management/` directory (spec.md + auto-generated TRACES.md)
- [x] 3.3 Replace `@trace spec:secret-management` → `@trace spec:secrets-management` in 17 live files (Rust src, shell, cheatsheets, other specs, container files)
- [x] 3.4 Replace `spec%3Asecret-management` → `spec%3Asecrets-management` in GitHub search URLs
- [x] 3.5 Rename cheatsheet `docs/cheatsheets/secret-management.md` → `secrets-management.md` + update 9 inbound cross-refs
- [x] 3.6 Rename runtime flag `--log-secret-management` → `--log-secrets-management` in `cli.rs`, `logging.rs`, 5 cheatsheets, 3 live specs

## 4. Keyring-on-host migration

- [x] 4.1 Add `apple-native` and `windows-native` features to `keyring` dep in `src-tauri/Cargo.toml`
- [x] 4.2 Add direct `zeroize = "1"` dep to `src-tauri/Cargo.toml`
- [x] 4.3 Replace `SecretKind::DbusSession` with `SecretKind::GitHubToken` in `crates/tillandsias-core/src/container_profile.rs`
- [x] 4.4 Add `LaunchContext.token_file_path: Option<PathBuf>` field
- [x] 4.5 Update `git_service_profile()` to use `SecretKind::GitHubToken`
- [x] 4.6 Update profile test `git_service_has_github_token_and_log_mount`
- [x] 4.7 Rewrite `src-tauri/src/launch.rs` `SecretKind` handler: delete D-Bus branch, add GitHubToken branch that mounts `ctx.token_file_path` at `/run/secrets/github_token:ro` and sets `GIT_ASKPASS` env
- [x] 4.8 Populate `token_file_path: None` on every `LaunchContext` constructor for non-git-service containers (inference, proxy, forge/terminal in handlers + runner + test)
- [x] 4.9 Populate `token_file_path` in the git-service launch via `secrets::prepare_token_file`

## 5. Token-file delivery helpers (`src-tauri/src/secrets.rs`)

- [x] 5.1 Rewrite module doc block for keyring-on-host architecture
- [x] 5.2 Keep/harden `store_github_token` + `retrieve_github_token`; add `delete_github_token`
- [x] 5.3 Implement `token_file_root()` (platform-aware)
- [x] 5.4 Implement `token_file_path(container_name)`
- [x] 5.5 Implement `prepare_token_file(container_name) -> Result<Option<PathBuf>, String>` with atomic write + 0700/0600 (Unix) / NTFS ACL (Windows)
- [x] 5.6 Implement `cleanup_token_file(container_name)` — idempotent unlink + parent rmdir
- [x] 5.7 Implement `cleanup_all_token_files()` — recursive rmtree of tokens-root
- [x] 5.8 Implement `secure_dir(path)` and `write_secure(path, bytes)` helpers

## 6. Git image + askpass

- [x] 6.1 Write `images/git/git-askpass-tillandsias.sh` — prompt-aware responses (`Username*` → `x-access-token`; `Password*` → `cat /run/secrets/github_token`; unknown prompt → exit 1)
- [x] 6.2 Add `COPY git-askpass-tillandsias.sh /usr/local/bin/` + `chmod +x` to `images/git/Containerfile`
- [x] 6.3 Embed `GIT_ASKPASS_TILLANDSIAS` via `include_str!` in `src-tauri/src/embedded.rs` and `write_lf` it during image-sources extraction (with `0755` on Unix)

## 7. `--github-login` flow

- [x] 7.1 Rewrite `runner::run_github_login_git_service` as keep-alive container + `podman exec gh auth login` interactive + `podman exec gh auth token` extraction + keyring store + Drop-guard teardown
- [x] 7.2 Always prompt for git identity with host `~/.gitconfig` fallback as defaults (not only when cache is empty)
- [x] 7.3 Remove the "Found running git service → exec into it" shortcut from `runner::run_github_login`
- [x] 7.4 Wrap extracted token in `zeroize::Zeroizing<String>`
- [x] 7.5 Set `stdin=null, stdout=piped, stderr=piped` explicitly on `gh auth token` + `gh api user` invocations
- [x] 7.6 Redact gh stderr from the user terminal on error path — print generic message pointing to `--log-secrets-management`
- [x] 7.7 Replace `handle_github_login` body with `open_terminal("<own-exe> --github-login", ...)` so tray and CLI share the same code path

## 8. `GH_TOKEN` env injection for ad-hoc gh calls

- [x] 8.1 `github::fetch_repos` reads token from keyring, wraps in Zeroizing, passes via `Command::env("GH_TOKEN", token)`
- [x] 8.2 `github::clone_repo` same pattern
- [x] 8.3 `build_gh_run_args` adds bare-name `-e GH_TOKEN` (no value in argv)
- [x] 8.4 Update module-level doc block to describe the no-leak scheme

## 9. Startup crash-recovery sweep

- [x] 9.1 Implement `handlers::sweep_orphan_containers` — `podman ps --filter name=tillandsias-` → per-container `stop` + `rm -f` + `cleanup_token_file` + `cleanup_enclave_network`
- [x] 9.2 Call `secrets::cleanup_all_token_files()` at tray startup
- [x] 9.3 Call `sweep_orphan_containers()` at tray startup (blocking via minimal tokio runtime)
- [x] 9.4 Wire `stop_git_service` to also call `cleanup_token_file`

## 10. CLI polish

- [x] 10.1 Fix `--help` output: `MAINTENANCE: init` → `MAINTENANCE: --init`
- [x] 10.2 Remove bareword `init` alias from CLI parser (only `--init` accepted)
- [x] 10.3 Rename `--log-secret-management` → `--log-secrets-management` everywhere (cli.rs, logging.rs, examples in docs)

## 11. Windows build: single binary

- [x] 11.1 `build-local.sh` — remove the `cp "$BIN" "$INSTALL_DIR/tillandsias-tray.exe"` double-install
- [x] 11.2 `build-local.ps1` — change `cargo build -p tillandsias-tray` → `cargo build -p tillandsias`, drop the Copy-Item to `-tray.exe`
- [x] 11.3 `scripts/install.ps1` — remove the "short-alias" Copy-Item block
- [x] 11.4 `src-tauri/src/update_cli.rs` — point the Windows install-path check at `tillandsias.exe` instead of `tillandsias-tray.exe`

## 12. New cheatsheets + CLAUDE.md polish

- [x] 12.1 Write `docs/cheatsheets/windows-credential-manager.md` — Wincred lifecycle, target-name format, "what we can't see", troubleshooting
- [x] 12.2 Rewrite `docs/cheatsheets/os-vault-credentials.md` — platform-vault tour, headless-Linux caveat, cross-refs
- [x] 12.3 Add `## Plugins & Skills` section to `CLAUDE.md` — when to invoke simplify / security-review / review / less-permission-prompts / update-config / openspec / etc.
- [x] 12.4 Evaluate Caveman-Claude (decision: skip — vanity repo, no usable artifact)

## 13. Windows overlay build fix (WSL-interop podman)

- [x] 13.1 In `src-tauri/src/tools_overlay.rs` Windows branch: translate host `podman.exe` path via `to_wsl_path` (`/mnt/c/...`) and pass as `PODMAN_PATH` env
- [x] 13.2 Add `WSLENV=PODMAN_PATH/u:TOOLS_OVERLAY_QUIET:TILLANDSIAS_PORT_MAPPING:CA_CHAIN_PATH/u` so env vars cross the WSL boundary
- [x] 13.3 In `scripts/build-tools-overlay.sh` resolver: accept `.exe`-suffixed `PODMAN_PATH` via `-f` test (WSL interop can exec .exe; the `-x` bit isn't set on interop-mounted binaries)

## 14. Rust audit hard-fails (from Opus audit)

- [x] 14.1 `ensure_proxy_running` readiness: 10 attempts then `return Err` (was: warn + proceed)
- [x] 14.2 `ensure_git_service_running` readiness: 10 attempts then `return Err` (was: warn + proceed)
- [x] 14.3 `ensure_enclave_ready` propagates git-service error instead of returning `Some(mirror)` with warning
- [x] 14.4 `singleton::try_acquire` returns `Err(())` when lockfile write fails (was: warn + `Ok(())`)
- [x] 14.5 `scripts/build-tools-overlay.sh` proxy-unreachable: `exit 1` (was: unset HTTP_PROXY and proceed with direct internet — security degradation)
- [x] 14.6 `main.rs` overlay failure sites (2 sites — fresh-images branch + after-build branch) + `handlers.rs` attach-here site: hard-fail via `overlay_ok` flag + `forge_available=false` + Dried icon + infrastructure_failed notification
- [x] 14.7 Shell entrypoints — git-clone failure becomes `exit 1` (3 files); missing overlay agent binary becomes `exit 1` (2 files); OpenSpec overlay missing becomes `exit 1` (lib-common.sh)
- [x] 14.8 `lib-common.sh` — replace `install_openspec` (inline npm install fallback) with `require_openspec` (overlay-only, fatal on miss)

## 15. Git-identity host fallback

- [x] 15.1 `launch::read_git_identity` — if cache gitconfig is empty, fall back to `~/.gitconfig`
- [x] 15.2 `build_podman_args` — skip `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` env vars when value is empty (prevents git's "empty ident" error)

## 16. Verification (manual — end-to-end on Windows)

- [x] 16.1 `keyring` round-trip probe confirmed write + read via `CredRead`
- [x] 16.2 `--github-login` OAuth device flow → token lands at `github-oauth-token.tillandsias` in Wincred
- [x] 16.3 Tray sees user as logged-in after keyring write (`needs_github_login()` returns false)
- [x] 16.4 Remote-repos list populates in tray (GH_TOKEN env injection path)
- [x] 16.5 Forge commit → mirror post-receive hook → github.com push succeeds (askpass path) with real PAT
- [x] 16.6 Branch verified on github.com via authenticated `git ls-remote`
- [x] 16.7 Orphan sweep verified by planting both `--rm` and non-`--rm` orphan `tillandsias-*` containers + dangling token files, then launching tray — all removed + enclave network cleaned
- [x] 16.8 Token file permissions confirmed (0644 on Windows mount, which is the NTFS ACL inheritance as expected)
- [x] 16.9 `cmdkey /list` shows only `github-oauth-token.tillandsias`; does NOT show any other Tillandsias-written entry

## 17. Sign-off

- [x] 17.1 `cargo check --workspace` clean (3 unrelated pre-existing warnings)
- [x] 17.2 `cargo test -p tillandsias-core container_profile` — 19/19 tests pass
- [x] 17.3 Release binary built and installed to `%LOCALAPPDATA%\Tillandsias\tillandsias.exe` (only binary present)
