# OS Vault / Keyring Credentials

Cross-platform reference for native credential storage APIs used by Tillandsias.

@trace spec:native-secrets-store, spec:secret-management

## Platform APIs

| Platform | API | Entry Schema | CLI Inspection |
|----------|-----|-------------|----------------|
| **Linux/GNOME** | Secret Service D-Bus (`org.freedesktop.secrets`) | Attribute-based: `service` + `username` attrs | `secret-tool` |
| **Linux/KDE** | KWallet (+ Secret Service since KF 5.97) | Wallet > Folder > Entry key | `kwallet-query` |
| **macOS** | Keychain Services (Security framework) | Generic Password: `service` + `account` | `security` |
| **Windows** | Credential Manager (DPAPI) | `TargetName` + `Type` | `cmdkey` |

## Entry Identification

### Linux — Secret Service D-Bus

Items have **attributes** (string key/value pairs for lookup) and a **secret** (the encrypted value).
Attributes are NOT encrypted. No per-item ACL — any same-user process can read everything.

```bash
# Store
secret-tool store --label="My Token" service myapp username myuser

# Lookup (returns secret on stdout)
secret-tool lookup service myapp username myuser

# Search (shows all metadata, no secret)
secret-tool search --all service myapp

# Clear
secret-tool clear service myapp username myuser
```

**Storage location:** `~/.local/share/keyrings/`
**D-Bus address:** `$DBUS_SESSION_BUS_ADDRESS` (typically `unix:path=/run/user/$UID/bus`)
**Desktop support:** GNOME Keyring (auto-starts), KDE Wallet 5.97+ (via ksecretd), KeePassXC (optional provider)

> Ref: [GNOME Keyring — ArchWiki](https://wiki.archlinux.org/title/GNOME/Keyring)
> Ref: [freedesktop.org Secret Storage Spec](https://freedesktop.org/wiki/Specifications/secret-storage-spec/secrets-api-0.1.html)

### Linux — KDE Wallet

Hierarchical: **Wallet** (e.g., `kdewallet`) > **Folder** (e.g., `Passwords`) > **Entry** (key → secret).

```bash
# List folders in wallet
kwallet-query -l kdewallet

# List entries in folder
kwallet-query -l kdewallet -f Passwords

# Read entry
kwallet-query -r entryname kdewallet -f Passwords

# Write (via kwalletcli, third-party)
echo "secret" | kwalletcli -f Passwords -e entryname -P
```

**D-Bus interface:** `org.kde.kwalletd6` (native), plus `org.freedesktop.secrets` (since KF 5.97)
**Storage:** `~/.local/share/kwalletd/` (encrypted `.kwl` files, Blowfish or GPG)

> Ref: [KDE Wallet — ArchWiki](https://wiki.archlinux.org/title/KDE_Wallet)

### macOS — Keychain

Two item classes relevant to credential storage:

| Class | Identified by | Use case |
|-------|---------------|----------|
| **Generic Password** | `service` + `account` | App tokens (gh, Tillandsias) |
| **Internet Password** | `server` + `protocol` + `account` | Web credentials (git, browsers) |

```bash
# Read generic password
security find-generic-password -s "gh:github.com" -a "username" -w

# Store generic password (-U = update if exists)
security add-generic-password -s "myservice" -a "myaccount" -w "secret" -U

# Delete
security delete-generic-password -s "myservice" -a "myaccount"

# Read internet password (used by git-credential-osxkeychain)
security find-internet-password -s github.com -a "username" -w
```

**Per-item ACL:** Each entry has an access list of approved apps. First access by a new app triggers a user prompt.
**Storage:** `~/Library/Keychains/login.keychain-db`

> Ref: [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services)
> Ref: [Apple TN3137: On Mac keychains](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)

### Windows — Credential Manager

Flat store: `TargetName` + `Type` uniquely identify an entry.

| Field | Purpose |
|-------|---------|
| `TargetName` | Primary identifier (e.g., `git:https://github.com`) |
| `Type` | `CRED_TYPE_GENERIC` (1) or `CRED_TYPE_DOMAIN_PASSWORD` (2) |
| `UserName` | Associated account |
| `CredentialBlob` | The secret (byte array, DPAPI-encrypted at rest) |

```cmd
cmdkey /list
cmdkey /generic:MyTarget /user:MyUser /pass:MyPass
cmdkey /delete:MyTarget
```

**Storage:** DPAPI-encrypted in `%LOCALAPPDATA%\Microsoft\Credentials\` (opaque files)
**Limitation:** Does NOT work over SSH sessions.

> Ref: [CREDENTIAL structure — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/wincred/ns-wincred-credentiala)

## Tillandsias Keyring Entries

| Secret | Service | Account/Key | Backend |
|--------|---------|-------------|---------|
| GitHub OAuth token | `tillandsias` | `github-oauth-token` | `keyring` crate v3 (`sync-secret-service`, `crypto-rust`) |

**Rust crate attributes on Linux (GNOME):**
```
xdg:schema = org.freedesktop.Secret.Generic
application = rust-keyring
service = tillandsias
target = default
username = github-oauth-token
```

Source: `src-tauri/src/secrets.rs:31-35`, `Cargo.toml:24`

## D-Bus Forwarding into Containers

For `gh auth login` inside a container to write to the HOST keyring:

```bash
podman run -it --rm \
  --userns=keep-id \
  -v /run/user/$UID/bus:/run/user/$UID/bus:ro \
  -e DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID/bus \
  -e XDG_RUNTIME_DIR=/run/user/$UID \
  $IMAGE gh auth login
```

**Requirements:** `--userns=keep-id` (UID must match for D-Bus auth), bus socket mounted, env vars set.

**Security:** Only use for short-lived auth containers. Do NOT forward D-Bus into long-running dev containers — it exposes the entire keyring and all D-Bus services.

> Ref: [Podman D-Bus session discussion](https://github.com/containers/podman/discussions/16772)
> Ref: [Toolbox — containers/toolbox](https://github.com/containers/toolbox)

## Security Notes

- **Linux Secret Service has NO per-item ACL.** Any same-user process can read all entries once the collection is unlocked (typically at desktop login). CVE-2018-19358.
- **macOS Keychain HAS per-item ACL.** New apps trigger a user prompt on first access.
- **Windows Credential Manager** is accessible to any same-user process (similar to Linux).
- **Headless/SSH:** No Secret Service available — tools fall back to plaintext. Tillandsias gracefully degrades to `hosts.yml` if keyring is unavailable.
