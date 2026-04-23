## Why

Tillandsias's credential pipeline previously relied on bind-mounting the host D-Bus session bus socket into the git-service container so `gh` could reach the host's Secret Service. That pattern (a) didn't work on Windows or macOS where there is no D-Bus on the host, (b) leaked the *entire* host keyring (browser passwords, SSH passphrases, WiFi PSKs) into a container that runs `gh` and `git` over an enclave-internal protocol, and (c) lived alongside a half-removed `hosts.yml` codepath that still appeared throughout code, specs, and docs as a "fallback" — a fallback nobody wanted, that masked real failures, and that was a security liability.

The keyring crate (v3, used by rustup / cargo / zed / warg-client) speaks libsecret/Keychain/Wincred natively from the host process, so the right architecture is: the *host* is the sole keyring consumer, and credentials reach the git-service container only as an ephemeral per-container tmpfs file mounted `:ro`. No D-Bus, no Secret Service, no `hosts.yml`, no host filesystem persistence beyond the container's lifetime.

## What Changes

- **BREAKING (internal)**: Removed `SecretKind::DbusSession` and the `DBUS_SESSION_BUS_ADDRESS` mount from every container profile. No D-Bus socket crosses the enclave boundary on any platform.
- **BREAKING (internal)**: Renamed runtime flag `--log-secret-management` → `--log-secrets-management` to match the consolidated plural spec.
- **BREAKING (internal)**: Removed bareword `tillandsias init` alias; only `--init` is supported (matches `--help` text).
- **BREAKING (internal)**: Stopped producing `tillandsias-tray.exe` on Windows. The single binary is `tillandsias.exe`; `--uninstall` and `--uninstall --wipe` work as before.
- Added `SecretKind::GitHubToken` + `LaunchContext.token_file_path` carrying an absolute host path the git-service profile mounts at `/run/secrets/github_token:ro`.
- Added `secrets::prepare_token_file(container)` (atomic-write `.tmp`+rename, mode 0600/Unix or per-user NTFS ACL/Windows), `secrets::cleanup_token_file(container)`, `secrets::cleanup_all_token_files()`, and `secrets::delete_github_token()`.
- Added `images/git/git-askpass-tillandsias.sh` installed at `/usr/local/bin/` in the git image; reads `/run/secrets/github_token` and feeds git's HTTPS auth (`x-access-token` username + token password). Wired into `GIT_ASKPASS` env at git-service launch.
- Added `handlers::sweep_orphan_containers()` called at tray startup. `TerminateProcess` / SIGKILL bypass Rust's Drop guards; this sweep stops + removes all `tillandsias-*` containers, unlinks orphan token files, and clears the enclave network so a crashed prior session leaves no residue.
- Hardened the `gh auth token` extraction in `runner::run_github_login_git_service` with explicit `Stdio::null/piped/piped`, `zeroize::Zeroizing<String>` wrapping, and gh-stderr redaction on failure (errors no longer surface raw container stderr to the user's terminal).
- Unified `--github-login` and tray > Settings > GitHub Login: both spawn a fresh ephemeral `tillandsias-gh-login` container. Removed the "exec into running git service" shortcut that bypassed keyring storage AND collided with the long-running git-service's read-only `/home/git/.config` path.
- `github::fetch_repos` and `github::clone_repo` now read the token from the keyring and inject it via `Command::env("GH_TOKEN", token)` + bare-name `-e GH_TOKEN`. Token never appears in `ps aux` argv, never persists on disk, scoped to a single podman child.
- Removed every `hosts.yml` reference from live Rust code (`github.rs`, `launch.rs`, `menu.rs`, `runner.rs`, `handlers.rs`, `embedded.rs`), shell entrypoints (`lib-common.sh`, `entrypoint-*.sh`), build scripts (`build-tools-overlay.sh`), top-level `gh-auth-login.sh` (deleted), `CLAUDE.md`, `SECRETS.md`, `docs/SECRETS.md`, and 5 cheatsheets. Negative "no D-Bus / no hosts.yml" wording remains in security-posture statements only.
- Consolidated `openspec/specs/secret-management/` (singular) into `openspec/specs/secrets-management/` (plural). Renamed `docs/cheatsheets/secret-management.md` → `secrets-management.md`. Rewired all `@trace spec:secret-management` → `@trace spec:secrets-management` across 17 live files.
- Configured `keyring = { version = "3", features = ["sync-secret-service", "crypto-rust", "apple-native", "windows-native"] }` in `src-tauri/Cargo.toml`. Without `apple-native` and `windows-native` the crate compiled into a no-op mock store on those platforms and writes silently failed.
- Added `zeroize = "1"` as a direct dep so `Zeroizing<String>` can wipe the OAuth token's heap allocation on Drop.
- New cheatsheet `docs/cheatsheets/windows-credential-manager.md` documenting the Wincred lifecycle, target-name format (`github-oauth-token.tillandsias`), and the explicit "what we cannot see" namespace boundary.
- Rewrote `docs/cheatsheets/os-vault-credentials.md` and `docs/cheatsheets/secrets-management.md` for the keyring-on-host architecture, with a headless-Linux caveat (SSH-only sessions need `gnome-keyring-daemon --unlock --daemonize` or `dbus-run-session` because there's no Secret Service daemon).
- `CLAUDE.md` gained a "Plugins & Skills" section documenting when to invoke installed skills (`simplify`, `security-review`, `review`, `less-permission-prompts`, `update-config`, etc.) and the OpenSpec workflow as the primary gate.

## Capabilities

### New Capabilities

None — every capability touched is a modification of an existing one.

### Modified Capabilities

- `secrets-management`: Replaces D-Bus-in-container forwarding with host-side keyring + ephemeral tmpfs token-file delivery. Adds startup orphan sweep. Drops the entire `hosts.yml` requirement family.
- `native-secrets-store`: Tightens to host-process-only API surface (`store_github_token` / `retrieve_github_token` / `delete_github_token` / `prepare_token_file` / `cleanup_token_file` / `cleanup_all_token_files`); enumerates per-platform backends (Linux libsecret, macOS Keychain, Windows Wincred); fixes the keyring-crate feature set so writes actually land in the OS vault on macOS/Windows.
- `gh-auth-script`: Replaces the deleted `gh-auth-login.sh` host wrapper with the unified `runner::run_github_login` flow (ephemeral container + host-side `gh auth token` extraction + keyring write + Drop-guard teardown). Tray and CLI are now one code path.
- `git-mirror-service`: Adds the `GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias.sh` runtime contract for the git-service container. Removes the D-Bus-mount requirement.

## Impact

- **Affected code**: `src-tauri/src/{secrets.rs, runner.rs, github.rs, handlers.rs, launch.rs, embedded.rs, menu.rs, cli.rs, main.rs}`, `crates/tillandsias-core/src/container_profile.rs`, `images/git/{Containerfile, git-askpass-tillandsias.sh}`, `images/default/lib-common.sh` and `entrypoint-*.sh`, `scripts/build-tools-overlay.sh`, `build-local.{sh,ps1}`, `scripts/install.ps1`.
- **Affected dependencies**: `src-tauri/Cargo.toml` adds `apple-native` + `windows-native` keyring features and a direct `zeroize = "1"` dep.
- **Affected docs/specs**: `CLAUDE.md`, `SECRETS.md`, `docs/SECRETS.md`, 6 cheatsheets (renamed `secret-management.md` → `secrets-management.md`; new `windows-credential-manager.md`); `openspec/specs/{secrets-management, native-secrets-store, gh-auth-script, git-mirror-service, secret-rotation, forge-offline, logging-accountability}/spec.md`. Singular `openspec/specs/secret-management/` directory deleted.
- **External CLI surface**: `--log-secret-management` flag removed in favor of `--log-secrets-management` (no alias retained — fail-fast policy). Bareword `init` subcommand removed in favor of `--init` only.
- **Windows build artifacts**: `tillandsias-tray.exe` is no longer produced or installed; only `tillandsias.exe` remains.
- **Runtime guarantee**: Forge containers continue to have zero credentials. Git-service container has *only* one credential artifact: the `:ro` tmpfs token file. No D-Bus socket, no keyring API, no hosts.yml — on any platform.
