---
id: os-keyring
title: OS Keyring / Secret Storage APIs
category: infra/security
tags: [keyring, secrets, dbus, secret-service, macos-keychain, windows-credential-manager]
upstream: https://specifications.freedesktop.org/secret-service/latest/
version_pinned: "0.2"
last_verified: "2026-03-30"
authority: official
---

# OS Keyring / Secret Storage APIs

## Linux: D-Bus Secret Service API

The [freedesktop Secret Service spec (v0.2)](https://specifications.freedesktop.org/secret-service/0.2/) defines a D-Bus interface for storing secrets. GNOME Keyring and KWallet both implement it.

**Object model:**
- **Service** (`org.freedesktop.Secret.Service`) -- manages sessions and collections
- **Collection** -- a named group of items (like a keychain). The `default` alias points to the user's default collection
- **Item** -- holds a secret value, a label, and lookup attributes (string key-value pairs, stored unencrypted for efficient lookup)
- **Session** -- negotiates encryption algorithm (plain or DH) for secret transfer over D-Bus

**Core operations** (D-Bus methods on the Service interface):
| Operation | Method |
|-----------|--------|
| Find secrets | `SearchItems(attributes) -> items[]` |
| Store secret | `CreateItem(collection, properties, secret, replace)` |
| Read secret | `GetSecrets(items[], session) -> secrets{}` |
| Delete secret | `Item.Delete()` |
| Lock/Unlock | `Lock(objects[]) / Unlock(objects[])` -- may trigger a prompt |

**Implementations:** GNOME Keyring (`gnome-keyring-daemon`), KWallet (`kwalletd5`/`kwalletd6`), `keepassxc` (partial).

**Access control:** Effectively all-or-nothing per session. Any process on the user's D-Bus session bus can read any unlocked item. No per-app ACLs in the spec.

**keyutils alternative:** Linux also has the kernel keyring (`keyctl`), which provides per-session/per-user/per-process keyrings. Faster but not persistent across reboots unless explicitly linked to a user keyring.

## macOS: Keychain Services (Security.framework)

Apple's [Keychain Services](https://developer.apple.com/documentation/security/keychain-services) stores secrets in encrypted SQLite databases protected by the user's login password.

**Two keychain implementations** (see [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)):
- **Data protection keychain** (modern, iOS-derived) -- preferred. Available only in user login context
- **File-based keychain** (legacy) -- avoid for new code

**Core operations** (C / Swift via Security.framework):
| Operation | Function |
|-----------|----------|
| Store | `SecItemAdd(attributes)` |
| Retrieve | `SecItemCopyMatching(query)` |
| Update | `SecItemUpdate(query, newAttributes)` |
| Delete | `SecItemDelete(query)` |

Items are identified by `kSecClass` (generic password, internet password, key, certificate) plus `kSecAttrService` and `kSecAttrAccount`.

**Access control:** Per-app via code signing. The `keychain-access-groups` entitlement controls which apps can share items. Unsigned or ad-hoc signed apps get their own implicit group. Users see an "allow" prompt for first access from a new app (file-based keychain only).

**Headless note:** Keychain requires a login session. On CI, use `security create-keychain` and `security unlock-keychain` to create a temporary keychain, or skip keychain entirely.

## Windows: Credential Manager (wincred.h)

[Credential Manager](https://learn.microsoft.com/en-us/windows/win32/secauthn/credential-management-portal) stores credentials encrypted with DPAPI, tied to the Windows user profile.

**Core operations** (Win32 API):
| Operation | Function |
|-----------|----------|
| Store | `CredWriteW(&credential, 0)` |
| Retrieve | `CredReadW(targetName, type, 0, &pCredential)` |
| Delete | `CredDeleteW(targetName, type, 0)` |
| Enumerate | `CredEnumerateW(filter, 0, &count, &pCredentials)` |
| Free | `CredFree(pCredential)` |

**Target naming convention:** `<application>/<service>/<account>` or URI-style. The `TargetName` field (max 32767 chars) is the primary lookup key. Credential `Type` is typically `CRED_TYPE_GENERIC` for app secrets.

**Credential blob:** Max 2560 bytes (512 for `CRED_TYPE_DOMAIN_PASSWORD`). Binary data, not null-terminated.

**Access control:** Per-user only. Any process running as the user can read any credential. No per-app isolation. DPAPI encryption is tied to user login credentials.

## Rust: `keyring` Crate (v3.6.x)

The [`keyring`](https://crates.io/crates/keyring) crate (v3.6.3 as of early 2026) provides a unified cross-platform API. No default features -- you must opt in to backends.

**Feature flags:**
| Feature | Backend | Platform |
|---------|---------|----------|
| `apple-native` | macOS Keychain (Security.framework) | macOS, iOS |
| `linux-native` | kernel keyutils (session keyring, not persistent) | Linux |
| `linux-secret-service-sync` | D-Bus Secret Service (sync, via `dbus-secret-service`) | Linux |
| `linux-native-sync-persistent` | keyutils + sync secret-service combo | Linux |
| `windows-native` | Credential Manager (wincred) | Windows |

**Usage:**
```rust
use keyring::Entry;

let entry = Entry::new("my-service", "my-username")?;

// Store
entry.set_password("s3cret")?;

// Retrieve
let password = entry.get_password()?;

// Binary data (v3+)
entry.set_secret(b"binary-blob")?;
let secret: Vec<u8> = entry.get_secret()?;

// Delete
entry.delete_credential()?;
```

**v3 changes from v2:** Synchronous Secret Service support (no async runtime needed). New `set_secret`/`get_secret` for binary data. Feature-gated backends (no defaults).

## Common Patterns

**Store/retrieve/delete** -- all three platforms follow the same pattern: identify by (service, account) pair, store an opaque blob, retrieve by the same pair, delete when done.

**Session vs persistent storage:**
- **Persistent:** Secret Service (default collection), macOS Keychain, Windows Credential Manager -- all survive reboots
- **Session-only:** Linux keyutils session keyring, Secret Service session collections -- cleared on logout

**Headless / CI environments:**
- No D-Bus session bus = no Secret Service. Detect with `$DBUS_SESSION_BUS_ADDRESS` or attempt connection and handle error
- No GUI = no unlock prompts. Pre-unlock or use alternative storage
- Common fallback: environment variables, encrypted files, or vault services (HashiCorp Vault, AWS Secrets Manager)
- The `keyring` crate returns `NoStorageAccess` or `NoEntry` errors -- handle gracefully

**Migration from file-based secrets:**
1. Read existing secret from file
2. Store into keyring via OS API
3. Verify retrieval succeeds
4. Delete file (secure wipe if possible: `shred` on Linux, normal delete elsewhere since SSD TRIM makes secure delete unreliable)
5. Update code to read from keyring first, file as fallback during transition

## Security Considerations

| Platform | Isolation | Encryption | Risk |
|----------|-----------|------------|------|
| Linux (Secret Service) | None (any D-Bus client) | At rest via keyring daemon | Session hijack exposes all |
| Linux (keyutils) | Per-process/session/user | Kernel-managed | Session keyring lost on logout |
| macOS | Per-app (code signing) | AES-256-GCM, hardware-backed on Apple Silicon | Best isolation model |
| Windows | Per-user only | DPAPI (user login key) | Any user process can read |

All platforms: secrets are exposed in process memory after retrieval. Zeroize sensitive buffers after use (`zeroize` crate in Rust).
