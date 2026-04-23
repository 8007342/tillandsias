## Context

Tillandsias ships a multi-container enclave for developer environments. The central security promise is: the forge container, which runs AI agents + npm + build tools, has **zero** credentials. Authenticated GitHub traffic flows through a sibling `tillandsias-git` container that holds the OAuth token and pushes to `github.com` on the forge's behalf.

Pre-migration, the token delivery mechanism to the git-service container was *supposed* to be "D-Bus session bus socket forwarded from the host, so libsecret inside the container calls through to the host's GNOME Keyring." In practice this was broken in three ways:

1. On Windows and macOS, there is no D-Bus on the host. The mount path was dead on those platforms, and the code had silent-fallback branches that "succeeded" without persisting anything — leaving the user with "token saved" messages and an empty vault.
2. Even on Linux, mounting the host D-Bus session bus socket into a container exposes the *entire* keyring (browser passwords, SSH passphrases, WiFi PSKs) to anything running inside that container. Secret Service has no per-caller ACL — `dbus-send` from a compromised binary reads any unlocked collection. This is a lateral-access vector out of proportion with the one credential the container actually needs.
3. The `hosts.yml` pathway — gh's default credential file — was half-removed. References remained in code, specs, and docs as "fallback" or "deprecated" — creating false alternatives that masked real failures.

The `keyring` crate (v3) is a well-vetted abstraction over libsecret / Keychain / Wincred, used by rustup, cargo, zed, warg-client. It can be called directly from the host Rust process without ever needing to cross into a container. This change replaces the D-Bus-in-container pattern with host-process-only keyring access and a minimal per-container secret mount.

## Goals / Non-Goals

**Goals:**

- Forge container invariant preserved: **zero credentials** — not even a token file.
- Git-service container receives **exactly one** credential artifact: a `:ro` bind-mounted tmpfs file at `/run/secrets/github_token`.
- Host is the sole consumer of the OS keyring (`keyring::Entry::new("tillandsias", "github-oauth-token")`). No D-Bus socket crosses the enclave boundary on any platform.
- No `hosts.yml` anywhere — code, specs, docs, shell scripts. Not "deprecated", not "fallback" — gone.
- Identical behavior + identical code path on Linux / macOS / Windows. Where a platform needs a different primitive (e.g. Windows Credential Manager vs Secret Service), the platform-specific feature flag on `keyring` handles it; Tillandsias code does not branch.
- Crash recovery: a `TerminateProcess` / SIGKILL of the tray leaves no secret state on disk. Next tray start detects and cleans up orphan containers + dangling token files.
- The `--github-login` CLI flow and tray > Settings > GitHub Login are **the same code path** (tray spawns `tillandsias --github-login` in a new terminal).
- Token bytes never flow to a terminal device. Extraction from the container via `gh auth token` is via a kernel pipe captured by the host process; host-side heap allocation wrapped in `Zeroizing<String>`.

**Non-Goals:**

- Biometric-guarded vault access (keyring crate doesn't support LAContext / Touch ID; documented in `windows-credential-manager.md`).
- Automated headless-Linux Secret Service provisioning (user must run `dbus-run-session` or unlock keyring manually; documented as a caveat).
- Token rotation, refresh flows, multiple github.com accounts, GitHub Enterprise — all deliberately out of scope.
- A "password unmask" input prompt inside Tillandsias. `gh` itself handles masking during `--paste-token` via its Go `term` library; Tillandsias never directly prompts for a secret.
- Preserving bareword `tillandsias init` / the `--log-secret-management` singular flag / `tillandsias-tray.exe` binary name. All three are removed outright — no alias, no back-compat shim (aligns with fail-fast / no-fallback policy).

## Decisions

### D1: Host-process-only keyring access (Option A from research)

The Opus keyring-maturity research enumerated four bridge designs:

- **A. Host-side extraction** — container runs `gh auth login`, host captures token via `podman exec gh auth token` stdout pipe, host writes to keyring, container torn down. Runtime re-delivery is the tmpfs file.
- **B. D-Bus secret-service proxy on Windows** — custom Rust daemon listens on a Unix socket inside WSL, speaks the Secret Service D-Bus protocol, proxies to Wincred.
- **C. Named-pipe RPC** — custom shim in the container talks to a host named-pipe server.
- **D. Custom gh credential helper** — gh's credential-helper protocol invoked against a helper binary the container exec's into.

**Chosen: A.** Rationale — B/C/D all require writing and maintaining a new component just to route bytes that `podman exec gh auth token` already exposes cleanly. None of them buy additional isolation over A; the token always eventually crosses the WSL2 boundary as plaintext bytes, because that is the only way the host can store it in Wincred. A uses existing infrastructure (`podman exec`, `keyring` crate) with zero new surface area. See `docs/cheatsheets/windows-credential-manager.md` for the full lifecycle table.

### D2: `SecretKind::GitHubToken` + `LaunchContext.token_file_path`

Replaces `SecretKind::DbusSession`. The enum variant is part of the container profile (compile-time declaration of what secrets a container wants); the `Option<PathBuf>` on the context is filled in by the orchestrator at launch time from `secrets::prepare_token_file(container_name)`.

Why the two-level split: the profile declares *intent* (this container needs the GitHub token); the context carries the *realization* (the actual on-disk path the orchestrator materialized, or `None` if no token is in the keyring — in which case the mount is skipped and authenticated git operations will fail loudly, which is the correct fail-fast UX when the user hasn't logged in yet).

### D3: Ephemeral token-file path per OS

- Linux: `$XDG_RUNTIME_DIR/tillandsias/tokens/<container>/github_token` (real tmpfs)
- macOS: `$TMPDIR/tillandsias-tokens/<container>/github_token` (per-user tmpfs under `/var/folders`)
- Windows: `%LOCALAPPDATA%\Temp\tillandsias-tokens\<container>\github_token` (NTFS, per-user ACL)

Alternatives considered:

- **VM-internal tmpfs on Windows** — would be truer to "tmpfs", but requires writing into `podman-machine-default`'s /tmp from the Windows host, which needs an extra WSL shell-out per token write. Adds latency and a new failure mode. Rejected.
- **`--env-file` instead of bind-mount** — would put the token into podman's argv-less env-file reader, but podman reads the file and embeds its *contents* in the container spec, so the token still transits to the container as an env var. We want the container to read from a file it can zap (its view of the file vanishes when `--rm` drops the container), not have the contents persisted in podman's DB. Rejected.
- **`podman exec -i` stdin at push-time** — would keep the token in-memory only, but git's HTTPS auth calls `GIT_ASKPASS` *after* the connection is established — there's no hook to supply stdin at that moment. Rejected.

Atomic-write via `.tmp` + rename ensures the mount target is never partially-written. Mode `0600` on Unix; NTFS inherits the per-user ACL from `%LOCALAPPDATA%`.

### D4: `git-askpass-tillandsias.sh` instead of `gh auth setup-git`

The git-service container pushes to `https://github.com/...` from its post-receive hook. git requires credentials via one of:

1. Credential helper (`gh auth setup-git` configures `credential.helper=!gh auth git-credential`).
2. `GIT_ASKPASS`.

Option 1 requires gh to be preconfigured with the token inside the container. With our architecture, gh in the git-service container has no state — we deliver only a raw token file. Running `gh auth login --with-token < /run/secrets/github_token` at container start would work but adds a gh-specific init step. **Chosen: GIT_ASKPASS** — a one-screen `/bin/sh` script that `cat`s the token file for "Password" prompts and echoes `x-access-token` for "Username" prompts. No gh state, no init dance, no dependency on gh's internals.

### D5: Keyring target-name format: host-only, one entry, hardcoded

Entry: `keyring::Entry::new("tillandsias", "github-oauth-token")`. Both strings are `const &'static str` at module scope in `secrets.rs`. The keyring crate's v3 API has no enumeration function; to read *any* entry you must construct it with an exact `(service, user)` pair. This makes the binary structurally incapable of reading other apps' vault entries (e.g. `gh:github.com` from the native gh install). Documented in `windows-credential-manager.md` and `os-vault-credentials.md` as "what we cannot see".

### D6: Explicit `Stdio::null/piped/piped` on extraction + `Zeroizing<String>`

Belt-and-suspenders. `Command::output()` already overrides stdout/stderr to piped; the explicit calls in `runner::run_github_login_git_service` prevent a future change to `podman_cmd_sync()` defaults from silently leaking. `Zeroizing<String>` wipes the heap buffer on Drop, mitigating core-dump / process-memory scrape.

### D7: Unconditional startup orphan sweep (not just on stale-lock takeover)

The sweep runs every tray startup. Rationale: our runtime containers all have `--rm`, so a clean exit leaves nothing to sweep (no-op). A crashed or force-killed prior session leaves orphan `tillandsias-*` containers that would otherwise (a) show up in the tray menu as un-controllable ghosts, (b) hold the token-file mount alive past the parent process, and (c) collide with new container name allocations. Unconditionally sweeping is strictly safer than conditionally sweeping on stale-lock detection — simpler state machine, same cost.

### D8: `Command::env("GH_TOKEN", ...)` + bare-name `-e GH_TOKEN` for ad-hoc gh invocations

For `github::fetch_repos` / `github::clone_repo` (short-lived `gh` calls, not the long-running git-service), we don't need the full tmpfs-file dance. `Command::env` puts the token in the *child* podman process's environment only; bare `-e GH_TOKEN` in argv tells podman to inherit that variable's value and forward to the container. The token never appears in `ps aux` argv. Visible in `/proc/<podman-pid>/environ` for the single podman call's lifetime, readable only by the same UID.

### D9: Spec directory naming: plural `secrets-management/`

The tree had both `openspec/specs/secret-management/` (singular, canonical) and `openspec/specs/secrets-management/` (plural, malformed delta-shaped). Consolidated to plural since that's what the user preferred. All `@trace spec:secret-management` references renamed to `spec:secrets-management` in 17 live files (Rust + shell + docs + other specs). Archived change-files under `openspec/changes/archive/**` retain their original spec names as historical record.

## Risks / Trade-offs

- **[Headless-Linux breaks]** SSH-only sessions without a desktop don't have a Secret Service daemon; `gh auth login` will fail with `NoStorageAccess`. **Mitigation**: documented in `docs/cheatsheets/secrets-management.md` and `os-vault-credentials.md` with the `gnome-keyring-daemon --unlock --daemonize` workaround. The pre-change architecture had the same failure mode (D-Bus-in-container needs the same Secret Service daemon on the host), so this is documentation, not a regression.

- **[Token on NTFS (Windows)]** On Windows the "tmpfs" token file lives on NTFS with a per-user ACL. Not true tmpfs; content could theoretically persist in the filesystem journal / page file. **Mitigation**: `cleanup_token_file` deletes on stop; `cleanup_all_token_files` wipes on startup; Windows NTFS ACL restricts to the user. Accept the trade-off; writing into the podman-machine VM's /tmp would require a WSL shell-out per write which is operationally worse.

- **[`ps -e f` inheritance window]** For `GH_TOKEN` injection, the token sits in podman's environ for the podman process's lifetime. `/proc/<pid>/environ` is user-only, but a co-resident attacker with the same UID could read it. **Mitigation**: accept — attacker with same UID has far more reach than this; the mitigation budget is better spent on the forge-container credential invariant.

- **[Crash leaves token on disk briefly]** If tillandsias crashes between `prepare_token_file` and container launch, or between container stop and `cleanup_token_file`, the token file persists on disk until next startup's sweep. **Mitigation**: `cleanup_all_token_files` at startup recursively wipes the entire tokens root; the file is user-ACL restricted and small; the risk window is bounded by "next tray launch".

- **[Keyring crate v4 churn]** v3.6.3 is max-stable; v4 is in rc. Staying on v3 until v4 ships GA. **Mitigation**: nothing to do; re-evaluate at v4.0 release.

- **[Single-account assumption]** The hardcoded `github-oauth-token` key means one GitHub identity per Tillandsias install. **Mitigation**: out of scope — this is a dev tool, not a multi-tenant CI runner. Document if it ever becomes a real use case.

- **[Removed CLI flag `--log-secret-management`]** Users with shell aliases break. **Mitigation**: release notes; fail-fast policy disallows alias retention.

- **[`tillandsias-tray.exe` binary rename]** Windows Start-menu shortcuts / scheduled tasks pointing at `tillandsias-tray.exe` break. **Mitigation**: `scripts/install.ps1` was updated to install only `tillandsias.exe`; NSIS installer already ships `tillandsias.exe`; users on pre-rename installs will see the shortcut break on upgrade and re-pin. Accept.

## Migration Plan

Single-step — all changes ship together. Downstream users:

1. First launch of the new binary runs `sweep_orphan_containers()` + `cleanup_all_token_files()` before any other work. Any stale state from the prior version is scrubbed.
2. Stored keyring entry (if any) from pre-migration is at the same target name `github-oauth-token.tillandsias` and is reused. No re-login required.
3. If the user had no keyring backend working on Windows/macOS pre-migration (common — the no-op mock crate store), they will be prompted to re-login on first remote-repo fetch. Expected.
4. Shell aliases / Start-menu shortcuts referencing `--log-secret-management` or `tillandsias-tray.exe` need to be updated manually. Documented in release notes.

Rollback: install the prior version. Keyring entry persists and will be read by the D-Bus-mount path if that version's keyring feature-set was right for the platform (it wasn't on Windows/macOS, so rollback on those platforms returns to the broken state).

## Open Questions

None blocking archive. Follow-up items flagged in memory / prior reports:

- Non-archived orphan `@trace spec:forge-launch` / `spec:forge-staleness` / `spec:forge-forward-compat` annotations point at change names whose archives didn't fold into a canonical spec. Separate cleanup pass — not in this change's scope.
- Some open changes under `openspec/changes/` (async-inference-launch, direct-podman-calls, fix-windows-*, persistent-git-service, etc.) are already implemented in commits on `windows-next` but not yet archived. Separate archival wave — not in this change's scope.
