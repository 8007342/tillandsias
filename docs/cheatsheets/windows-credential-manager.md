---
tags: [windows, credentials, wincred, dpapi, security]
languages: [rust]
since: 2024-01-01
last_verified: 2026-04-27
sources:
  - https://learn.microsoft.com/en-us/windows/win32/api/wincred/
authority: high
status: current
---

# Windows Credential Manager

How Tillandsias stores the GitHub OAuth token on Windows. The token lives exclusively in the per-user Credential Manager vault; the host filesystem never holds a `hosts.yml` or any other plaintext copy.

@trace spec:native-secrets-store, spec:secrets-management

## Architecture in one paragraph

The host Tillandsias binary is the **sole consumer** of Credential Manager. It calls the Rust [`keyring`](https://crates.io/crates/keyring) crate, which routes to `Advapi32.dll` (`CredWriteW` / `CredReadW` / `CredDeleteW`). The blob is encrypted by DPAPI to the current user's SID and persisted under `%LOCALAPPDATA%\Microsoft\Credentials\`. No container ever links against `Advapi32.dll`, receives a Wincred handle, or sees `DBUS_SESSION_BUS_ADDRESS` (Wincred is a Win32 API, not a socket — there is nothing to forward, and we deliberately don't invent a substitute). When the git-service container needs the token, the host writes it to a per-container ephemeral file under `%LOCALAPPDATA%\Temp\tillandsias-tokens\<container>\github_token` and bind-mounts that file read-only at `/run/secrets/github_token`. The file is unlinked on container stop.

## Credential Manager at a glance

Credential Manager is the Win32 equivalent of the macOS Keychain or the Linux Secret Service. Per-user vault, DPAPI-backed, no daemon, no IPC — just a Win32 API callable from any process running as the user.

| Layer | Component |
|-------|-----------|
| User-mode API | `wincred.h` — `CredWriteW`, `CredReadW`, `CredDeleteW`, `CredEnumerateW` |
| Implementation DLL | `Advapi32.dll` (`sechost.dll`, `API-MS-Win-Security-credentials-l1-1-0.dll`) |
| Encryption at rest | DPAPI, master key derived from the user's logon credential |
| On-disk store | `%LOCALAPPDATA%\Microsoft\Credentials\` (opaque per-credential files) |
| Inspection tools | `cmdkey.exe`, Control Panel → User Accounts → Credential Manager |

> Ref: [CREDENTIAL structure — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/wincred/ns-wincred-credentiala)
> Ref: [CredWriteW — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/wincred/nf-wincred-credwritew)

## API surface used by Tillandsias

| API | Purpose | Visibility |
|-----|---------|------------|
| `CredWriteW` | Create or overwrite a credential | Caller must be in the user's interactive logon session with the SID enabled |
| `CredReadW` | Read a credential by `TargetName` + `Type`; DPAPI decrypts transparently | Same user account only; cross-account reads are blocked even with admin |
| `CredDeleteW` | Remove a credential by `TargetName` + `Type` | Same user account |
| `CredEnumerateW` | List credentials matching a filter — used by `cmdkey /list` | Same user account |

None require elevation. None work for service accounts or pure network logons (`ERROR_NO_SUCH_LOGON_SESSION`). SSH sessions into Windows hit the same restriction.

## `CREDENTIAL` fields Tillandsias sets

| Field | Value | Notes |
|-------|-------|-------|
| `Type` | `CRED_TYPE_GENERIC` (1) | Generic application credential, no NTLM/Kerberos coupling |
| `TargetName` | `github-oauth-token.tillandsias` | `keyring` crate format `"{user}.{service}"`; verified by `cmdkey /delete:github-oauth-token.tillandsias` |
| `UserName` | `github-oauth-token` | Informational for `CRED_TYPE_GENERIC` |
| `CredentialBlob` | Token bytes (UTF-8, no trailing NUL) | Max 2560 bytes (`CRED_MAX_CREDENTIAL_BLOB_SIZE`); a GitHub OAuth token is ~40 bytes |
| `Persist` | `CRED_PERSIST_ENTERPRISE` (3) | Survives reboot; degrades to local on non-roaming profiles |
| `Comment` | `keyring-rs` | Set by the crate, cosmetic |

Persistence chosen: `CRED_PERSIST_ENTERPRISE` is the `keyring` crate default. On a non-domain machine it behaves identically to `CRED_PERSIST_LOCAL_MACHINE` (the OS falls back to local), so there is no practical exposure increase.

> Ref: [CREDENTIAL.Persist enumeration](https://learn.microsoft.com/en-us/windows/win32/api/wincred/ns-wincred-credentiala#members)

## `keyring` crate mapping

The crate v4 with the `windows-native` feature maps `Entry::new(service, username)` into Wincred as follows.

| Rust call | Windows translation |
|-----------|---------------------|
| `Entry::new("tillandsias", "github-oauth-token")` | Builds `TargetName = "github-oauth-token.tillandsias"` |
| `entry.set_password(&token)` | `CredWriteW` with `Type = CRED_TYPE_GENERIC`, `Persist = CRED_PERSIST_ENTERPRISE`, `CredentialBlob = token.as_bytes()` |
| `entry.get_password()` | `CredReadW` by `TargetName` + `Type`; returns `CredentialBlob` decoded as UTF-8 |
| `entry.delete_credential()` | `CredDeleteW` by `TargetName` + `Type` |

Bytes are stored raw: no base64, no JSON wrapping.

> Ref: [keyring-rs — crates.io](https://crates.io/crates/keyring)

## Tillandsias entry on Windows

| Secret | `keyring` service | `keyring` key | Wincred TargetName | Type |
|--------|-------------------|---------------|---------------------|------|
| GitHub OAuth token | `tillandsias` | `github-oauth-token` | `github-oauth-token.tillandsias` | `CRED_TYPE_GENERIC` |

Source: `src-tauri/src/secrets.rs` (`SERVICE` and `GITHUB_TOKEN_KEY` constants).

## What we CAN'T see

`keyring::Entry::new(SERVICE, KEY)` requires both coordinates up front. The crate exposes no `enumerate` or `list` API, and Tillandsias does not call `CredEnumerateW` directly. Practical consequences:

- Tillandsias cannot read or write **any** other application's credential, including the row that the standalone `gh` CLI writes (`gh:github.com`).
- Tillandsias cannot detect what other tokens the user has stored — `cmdkey /list` is the user's tool, not ours.
- The only row Tillandsias ever touches is `github-oauth-token.tillandsias`. Logout deletes exactly that row; everything else in Credential Manager is untouched.

## End-to-end token lifecycle

Numbered transitions. "Process" is the OS process actually holding the token bytes. "Location" is where the bytes physically reside at the end of the step.

| # | Step | Process | API / call | Location after step |
|---|------|---------|------------|---------------------|
| 1 | User runs `tillandsias --github-login` (CLI) or clicks "GitHub Login" (tray) | Tillandsias host (Rust) | `runner::run_github_login` → `run_github_login_git_service` | Not in memory yet |
| 2 | Host prompts for git identity, writes `<cache>\secrets\git\.gitconfig` | Tillandsias host | `std::fs::write` | Cache file (no token, just `user.name` / `user.email`) |
| 3 | Host launches keep-alive container `tillandsias-gh-login` from the git-service image with `--cap-drop=ALL --security-opt=no-new-privileges --userns=keep-id`, default bridge network, `sleep infinity` entrypoint | podman | `podman run -d --init --entrypoint sleep …` | Container running, no token yet |
| 4 | Host runs `podman exec -it tillandsias-gh-login gh auth login --git-protocol https` with the real TTY inherited | `gh` inside container | OAuth device flow over the internet | Container RAM + a throwaway `/home/git/.config/gh/hosts.yml` inside the container layer |
| 5 | Host runs `podman exec tillandsias-gh-login gh auth token`, captures stdout | `gh` → host pipe | RAM-only pipe | Tillandsias host process RAM |
| 6 | Host calls `secrets::store_github_token(&token)` | Tillandsias host | `keyring::Entry::new(...).set_password(token)` → `CredWriteW` | `%LOCALAPPDATA%\Microsoft\Credentials\` (DPAPI-encrypted) |
| 7 | `LoginContainerGuard::drop` runs `podman rm -f tillandsias-gh-login` | podman | `--rm` semantics | Container destroyed; the throwaway `hosts.yml` dies with it |
| 8 | Later: project's git-service container starts | Tillandsias host | `secrets::prepare_token_file(<container>)` → `retrieve_github_token` → `CredReadW` → atomic write to `%LOCALAPPDATA%\Temp\tillandsias-tokens\<container>\github_token` | Per-container file, NTFS ACL inherited from `%LOCALAPPDATA%` (per-user) |
| 9 | Host bind-mounts the file at `/run/secrets/github_token:ro` and sets `GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias.sh` on the git-service container | podman | `-v <host>:/run/secrets/github_token:ro -e GIT_ASKPASS=…` | Read-only inside git-service only |
| 10 | Forge does `git push origin <branch>` against the enclave-internal git-service over plain git protocol | forge → git-service over enclave network | No auth at the forge boundary | Forge has zero credentials throughout |
| 11 | git-service forwards to `github.com` via the proxy; git invokes the askpass script, which reads `/run/secrets/github_token` and returns it as the password | git-service container | Standard `GIT_ASKPASS` protocol | Token only ever in git-service memory + the `:ro` bind-mounted file |
| 12 | git-service container stops | Tillandsias host | `cleanup_token_file(<container>)` | File and parent directory unlinked |
| 13 | Tillandsias exits (clean or panic) | Tillandsias host | `cleanup_all_token_files()` Drop guard | Entire `%LOCALAPPDATA%\Temp\tillandsias-tokens\` tree removed |
| 14 | User chooses "Log out" (future tray action) | Tillandsias host | `keyring::Entry::delete_credential()` → `CredDeleteW` | Row removed from Credential Manager |

Source: `src-tauri/src/runner.rs::run_github_login_git_service`, `src-tauri/src/secrets.rs::prepare_token_file` / `cleanup_token_file` / `cleanup_all_token_files`.

## Inspection and troubleshooting

### List the Tillandsias entry from cmd

```cmd
cmdkey /list | findstr tillandsias
```

Expected output:

```
Target: LegacyGeneric:target=github-oauth-token.tillandsias
Type: Generic
User: github-oauth-token
```

### GUI inspection

`Control Panel` → `User Accounts` → `Credential Manager` → **Windows Credentials** tab → scroll to `github-oauth-token.tillandsias`. The UI shows TargetName, UserName, and modification time. The blob is not displayed unless the user expands the entry and re-authenticates with their Windows password.

Use the **Windows Credentials** tab, not **Web Credentials**. Web Credentials holds Edge / Internet Explorer site logins; `CRED_TYPE_GENERIC` entries always live under Windows Credentials.

### Read the blob (debug only)

`cmdkey` does not print `CredentialBlob` — DPAPI deliberately blocks it. To dump the secret during local debugging:

```powershell
Install-Module -Name CredentialManager -Scope CurrentUser
$c = Get-StoredCredential -Target "github-oauth-token.tillandsias"
$c.Password | ConvertFrom-SecureString -AsPlainText
```

The `SecureString` decryption runs as the current user via DPAPI; no elevation is required after the module is installed.

### Delete manually

```cmd
cmdkey /delete:github-oauth-token.tillandsias
```

If a user deletes the entry — via this command, the GUI, or any other tool — the next call to `secrets::retrieve_github_token` returns `Ok(None)`. Tillandsias does **not** treat this as an error: `prepare_token_file` returns `Ok(None)`, the bind-mount is skipped, and the user is prompted to re-run `tillandsias --github-login` the next time an authenticated git operation is attempted.

### Common failure modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Keyring unavailable` / `ERROR_NO_SUCH_LOGON_SESSION` | Running as a service account, network logon, or over SSH — no interactive logon session | Run Tillandsias as the interactive desktop user |
| `cmdkey /list` shows the entry, but git push inside the forge fails with auth error | git-service container was started before the entry was written | Restart the git-service container (or re-run `--github-login`, which restarts it implicitly) |
| Entry persists after "Log out" | `delete_credential` skipped due to an earlier error | Run `cmdkey /delete:github-oauth-token.tillandsias` manually |
| PowerShell `Get-StoredCredential` returns an empty password | DPAPI cannot decrypt — typically the user's Windows password was reset without a password reset disk, destroying the master key | Re-authenticate via `tillandsias --github-login` |
| `prepare_token_file` returns `Ok(None)` unexpectedly | Entry was deleted from Credential Manager | Re-run `tillandsias --github-login` |

> Ref: [cmdkey command reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cmdkey)

## Cross-platform contract

The three platforms share the same invariants:

| Aspect | Linux | macOS | Windows |
|--------|-------|-------|---------|
| Vault | Secret Service (libsecret over D-Bus) | Keychain Services | Credential Manager (Wincred + DPAPI) |
| Caller | Host Tillandsias process **only** | Host Tillandsias process **only** | Host Tillandsias process **only** |
| Container reaches vault? | **No** (no D-Bus mount, no `DBUS_SESSION_BUS_ADDRESS`) | **No** (no IPC socket forwarded) | **No** (Wincred is a Win32 API, no IPC to forward) |
| Token delivery into git-service | Bind-mount `/run/secrets/github_token:ro` from `$XDG_RUNTIME_DIR/tillandsias/tokens/<container>/github_token` | Bind-mount from `$TMPDIR/tillandsias-tokens/<container>/github_token` | Bind-mount from `%LOCALAPPDATA%\Temp\tillandsias-tokens\<container>\github_token` |
| Forge credentials | Zero | Zero | Zero |
| Survives reboot | Yes (after desktop login unlocks the keyring) | Yes (login keychain auto-unlocks) | Yes (DPAPI master key derived from logon) |
| Available headless / SSH | No (no D-Bus session bus) | Limited (login keychain locked) | No (`ERROR_NO_SUCH_LOGON_SESSION`) |

The OS keyring is the single source of truth for the token on every platform; the host filesystem never holds a `hosts.yml` or any other plaintext copy.

## Related

**Cheatsheets:**
- `docs/cheatsheets/secrets-management.md` — overall secret architecture
- `docs/cheatsheets/os-vault-credentials.md` — cross-platform keyring API reference
- `docs/cheatsheets/github-credential-tools.md` — `gh` CLI, GCM, libsecret storage conventions
- `docs/cheatsheets/token-rotation.md` — refresh task that re-reads from Credential Manager
- `docs/cheatsheets/windows-networking.md` — WSL2 + podman-machine details

**Source files:**
- `src-tauri/src/secrets.rs` — `keyring` crate calls and ephemeral-file delivery
- `src-tauri/src/runner.rs` — `run_github_login_git_service` (`--github-login` flow)
- `src-tauri/src/launch.rs` — bind-mount of `/run/secrets/github_token`
- `crates/tillandsias-core/src/container_profile.rs` — `SecretKind::GitHubToken`, `LaunchContext::token_file_path`

**Specs:**
- `openspec/specs/native-secrets-store/spec.md`
- `openspec/specs/secrets-management/spec.md`

**External references:**
- [CREDENTIAL structure — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/wincred/ns-wincred-credentiala)
- [CredWriteW function — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/wincred/nf-wincred-credwritew)
- [cmdkey — Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cmdkey)
- [keyring-rs — crates.io](https://crates.io/crates/keyring)
- [keyring::windows — docs.rs](https://docs.rs/keyring/latest/x86_64-pc-windows-msvc/keyring/windows/index.html)

## Provenance

- https://learn.microsoft.com/en-us/windows/win32/api/wincred/ — wincred.h API reference; `CredWriteW`, `CredReadW`, `CredDeleteW`, `CredEnumerateW` functions; `CREDENTIAL` and `CREDENTIALW` structures; DPAPI-backed per-user credential vault
- **Last updated:** 2026-04-27
