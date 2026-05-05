---
tags: [keyring, credentials, security, linux, macos, windows]
languages: [rust]
since: 2024-01-01
last_verified: 2026-04-27
sources:
  - https://docs.rs/keyring/latest/keyring/
  - http://specifications.freedesktop.org/secret-service/latest/
authority: high
status: current
---

# OS Vault / Keyring Credentials

Cross-platform reference for the native credential vaults Tillandsias uses on Linux, macOS, and Windows. The host Rust process is the **sole consumer** of the OS keyring; containers never link against any keyring API and never receive a D-Bus, Keychain, or Wincred handle. This cheatsheet describes the per-OS vault, what the `keyring` crate does on top of it, and how to inspect entries from the command line.

@trace spec:native-secrets-store, spec:secrets-management

## Per-OS vault at a glance

| Platform | Vault | Backend API | On-disk store | CLI inspection |
|----------|-------|-------------|----------------|----------------|
| Linux | Secret Service (GNOME Keyring, KWallet 5.97+, KeePassXC, …) | libsecret over D-Bus (`org.freedesktop.secrets`) | `~/.local/share/keyrings/` (encrypted at rest, opened on desktop login) | `secret-tool` |
| macOS | Keychain Services (Generic Password class) | Security framework (in-process Mach IPC to `securityd`) | `~/Library/Keychains/login.keychain-db` | `security` |
| Windows | Credential Manager (Wincred) | `Advapi32.dll` — `CredWriteW` / `CredReadW` / `CredDeleteW` | `%LOCALAPPDATA%\Microsoft\Credentials\` (DPAPI-encrypted to user SID) | `cmdkey` |

Per-vendor canonical references:
- Linux: [Secret Service API specification](http://specifications.freedesktop.org/secret-service/latest/) (freedesktop.org)
- macOS: [Keychain services](https://developer.apple.com/documentation/security/keychain-services) (Apple Developer)
- Windows: [CREDENTIAL structure](https://learn.microsoft.com/en-us/windows/win32/api/wincred/ns-wincred-credentiala), [CredWriteW](https://learn.microsoft.com/en-us/windows/win32/api/wincred/nf-wincred-credwritew), [cmdkey](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cmdkey) (Microsoft Learn)

## How Tillandsias uses these vaults

Tillandsias talks to all three vaults through the Rust [`keyring`](https://crates.io/crates/keyring) crate (v4.0.0). The crate exposes a single platform-neutral API:

```rust
let entry = keyring::Entry::new("tillandsias", "github-oauth-token")?;
entry.set_password(&token)?;          // Linux: libsecret store; macOS: SecItemAdd; Windows: CredWriteW
let token = entry.get_password()?;    // matching reads via the same paths
entry.delete_credential()?;           // logout / rotation
```

Three rules constrain the call sites:

1. The keyring is touched **only** by the host Tillandsias binary. No container, entrypoint script, or subprocess opens a keyring handle.
2. The entry coordinates are fixed: service `tillandsias`, key `github-oauth-token`. Constructing an `Entry` requires both, so Tillandsias cannot read or write any other application's row.
3. After `retrieve_github_token()` returns, the host writes the token to a per-container ephemeral file (mode `0600` on Unix; per-user NTFS ACL on Windows), bind-mounts that file read-only at `/run/secrets/github_token` into the git-service container, and unlinks it on container stop. No container ever sees the keyring itself.

Source: `src-tauri/src/secrets.rs` (`store_github_token`, `retrieve_github_token`, `delete_github_token`, `prepare_token_file`, `cleanup_token_file`).

## Linux — Secret Service

Items are stored as **attributes** (string key/value pairs, used for lookup) plus a **secret blob**. Attributes are not encrypted; the blob is. There is no per-item ACL — once the user's collection is unlocked (typically at desktop login), any process running as the same user can read every entry in it.

The Secret Service specification (freedesktop.org, version 0.2 DRAFT as of 2026-04-08) defines the D-Bus interface (`org.freedesktop.secrets`) covering collections, items, sessions, and prompts. The spec uses AES-128-CBC for secret transport encryption.

```bash
# Store a row
secret-tool store --label="My Token" service tillandsias username github-oauth-token

# Lookup (returns the secret on stdout)
secret-tool lookup service tillandsias username github-oauth-token

# Search metadata for a service (no secret returned)
secret-tool search --all service tillandsias

# Clear
secret-tool clear service tillandsias username github-oauth-token
```

The `keyring` crate (with `sync-secret-service` + `crypto-rust`) writes the row with these attributes:

```
xdg:schema  = org.freedesktop.Secret.Generic
service     = tillandsias
username    = github-oauth-token
application = rust-keyring
target      = default
```

KWallet 5.97+ exposes the same `org.freedesktop.secrets` interface, so the crate works unchanged on Plasma desktops.

> Ref: [Secret Service API specification](http://specifications.freedesktop.org/secret-service/latest/)

### Headless-Linux caveat

A bare SSH session into a Linux box has **no desktop session, no Secret Service daemon, no D-Bus session bus**. `tillandsias --github-login` will surface an error like `NoStorageAccess` from the `keyring` crate when it tries to call `store_github_token`. To enable the keyring on a headless host, run one of these before invoking Tillandsias:

```bash
# Option 1: start gnome-keyring-daemon manually and unlock it
eval "$(gnome-keyring-daemon --unlock --daemonize)"

# Option 2: wrap Tillandsias in a fresh dbus session
dbus-run-session -- tillandsias --github-login
```

This caveat is purely about the **host** reaching its **own** keyring. No container ever needs D-Bus.

## macOS — Keychain

Tillandsias uses the Generic Password item class (`kSecClassGenericPassword`), keyed on `service` + `account`.

| Class | Identified by | Use case |
|-------|---------------|----------|
| Generic Password | `service` + `account` | App tokens (Tillandsias) |
| Internet Password | `server` + `protocol` + `account` | Web credentials (browsers, git-credential-osxkeychain) |

```bash
# Read the Tillandsias entry
security find-generic-password -s "tillandsias" -a "github-oauth-token" -w

# Store / update (-U overwrites if it exists)
security add-generic-password -s "tillandsias" -a "github-oauth-token" -w "<token>" -U

# Delete
security delete-generic-password -s "tillandsias" -a "github-oauth-token"
```

Per-item ACL: each entry carries an access list of approved binaries. The first time a freshly-rebuilt Tillandsias touches the entry, macOS prompts the user for keychain unlock; subsequent calls from the same code-signed binary are silent.

> Ref: [Keychain services](https://developer.apple.com/documentation/security/keychain-services)

## Windows — Credential Manager

Credential Manager is a flat per-user vault. `TargetName` + `Type` uniquely identify an entry. The blob is encrypted at rest by DPAPI using a master key derived from the user's logon credential, so another Windows account on the same machine cannot decrypt it without first unlocking that user's profile.

| Field | Value used by Tillandsias |
|-------|----------------------------|
| `Type` | `CRED_TYPE_GENERIC` (1) |
| `TargetName` | `github-oauth-token.tillandsias` (`keyring` crate format: `"{user}.{service}"`) |
| `UserName` | `github-oauth-token` |
| `Persist` | `CRED_PERSIST_ENTERPRISE` (3) — survives reboot |

```cmd
:: List all credentials (filter to ours)
cmdkey /list | findstr tillandsias

:: Delete the Tillandsias entry
cmdkey /delete:github-oauth-token.tillandsias
```

The blob value is **not** exposed by `cmdkey`; DPAPI hands it back only via `CredReadW` running in the user's logon session. Service accounts and pure network logons cannot use Credential Manager — `CredWriteW` returns `ERROR_NO_SUCH_LOGON_SESSION`. SSH sessions into Windows are subject to the same restriction.

For the full Windows-side lifecycle, including the GUI inspection path and what happens when a user manually deletes the entry, see `docs/cheatsheets/windows-credential-manager.md`.

> Ref: [CREDENTIAL structure](https://learn.microsoft.com/en-us/windows/win32/api/wincred/ns-wincred-credentiala) · [CredWriteW](https://learn.microsoft.com/en-us/windows/win32/api/wincred/nf-wincred-credwritew) · [cmdkey](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cmdkey)

## Tillandsias keyring entries

| Secret | `keyring` service | `keyring` key | TargetName on Windows | Backend per OS |
|--------|-------------------|---------------|------------------------|----------------|
| GitHub OAuth token | `tillandsias` | `github-oauth-token` | `github-oauth-token.tillandsias` | libsecret / Keychain / Wincred |

Source: `src-tauri/src/secrets.rs` (`SERVICE`, `GITHUB_TOKEN_KEY` constants).

## What Tillandsias deliberately does NOT do

- No container is launched with `DBUS_SESSION_BUS_ADDRESS` set, no D-Bus socket bind-mount, no Secret Service forwarding of any kind. Forge, terminal, proxy, inference, and git-service containers all run without any keyring transport.
- No fallback to plaintext on disk. If the host keyring is unreachable, `store_github_token` and `retrieve_github_token` return `Err` and the caller surfaces the failure rather than degrade.
- No enumeration of other apps' entries. `keyring::Entry::new(SERVICE, KEY)` requires both coordinates up front; the crate never iterates the vault, so Tillandsias only ever touches its own row.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `Keyring unavailable` on Linux desktop | Secret Service daemon not yet running, or login keyring still locked | Open Seahorse / KWalletManager, unlock; retry |
| `NoStorageAccess` on headless Linux | No D-Bus session bus, no Secret Service | Run `gnome-keyring-daemon --unlock --daemonize` or wrap with `dbus-run-session` (see Headless-Linux caveat) |
| macOS prompts on every launch | Code signature changed (typical for local dev builds) | Approve once, or sign the build with the same identity |
| Windows `ERROR_NO_SUCH_LOGON_SESSION` | Running as a service / network logon / over SSH | Run Tillandsias as the interactive desktop user |
| Entry vanished from vault | User deleted it via `cmdkey /delete`, Seahorse, or Keychain Access | `retrieve_github_token` returns `Ok(None)`; user is prompted to re-run `tillandsias --github-login` |

## Security notes

- **Linux Secret Service has no per-item ACL.** Once unlocked, any same-user process reads every entry. CVE-2018-19358 is the canonical reference. Tillandsias mitigates by keeping forge containers entirely off the keyring path.
- **macOS Keychain has per-item ACL** with first-access prompts.
- **Windows Credential Manager** has no per-app ACL but DPAPI binds blobs to the user SID, so cross-account reads are blocked.
- All three vaults are **only as strong as the user's login**. A compromised desktop session is a compromised vault — for that threat model see the `fine-grained-pat-rotation` design which scopes tokens to single repos with short expiry.

## Related

**Cheatsheets:**
- `docs/cheatsheets/secrets-management.md` — overall secret architecture (start here)
- `docs/cheatsheets/windows-credential-manager.md` — Windows-specific lifecycle and GUI inspection
- `docs/cheatsheets/github-credential-tools.md` — how `gh`, GCM, and git credential helpers store tokens
- `docs/cheatsheets/token-rotation.md` — refresh task that touches the keyring on a timer

**Source files:**
- `src-tauri/src/secrets.rs` — `keyring` crate calls and ephemeral-file delivery
- `src-tauri/src/runner.rs` — `--github-login` flow that populates the keyring
- `src-tauri/src/launch.rs` — bind-mount of `/run/secrets/github_token`

**Specs:**
- `openspec/specs/native-secrets-store/spec.md`
- `openspec/specs/secrets-management/spec.md`

## Provenance

- https://docs.rs/keyring/latest/keyring/ — keyring crate v4.0.0; platform-neutral credential storage API with backends for Linux (libsecret), macOS (Keychain), and Windows (Wincred)
- http://specifications.freedesktop.org/secret-service/latest/ — Secret Service API spec v0.2 DRAFT (2026-04-08); D-Bus interface `org.freedesktop.secrets`, collections, items, sessions, AES-128-CBC secret transport
- **Last updated:** 2026-04-27
