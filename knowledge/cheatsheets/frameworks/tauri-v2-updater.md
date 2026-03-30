---
id: tauri-v2-updater
title: Tauri v2 Updater Plugin
category: frameworks/tauri
tags: [tauri, updater, auto-update, ed25519, github-releases]
upstream: https://v2.tauri.app/plugin/updater/
version_pinned: "2.x"
last_verified: "2026-03-30"
authority: official
---

# Tauri v2 Updater Plugin

## Setup

### Cargo (src-tauri/Cargo.toml)

```toml
[target."cfg(not(any(target_os = \"android\", target_os = \"ios\")))".dependencies]
tauri-plugin-updater = "2"
```

Or via CLI: `cargo add tauri-plugin-updater --target 'cfg(any(target_os = "macos", windows, target_os = "linux"))'`

### JavaScript

```bash
npm add @tauri-apps/plugin-updater
```

### Rust initialization (lib.rs)

```rust
tauri::Builder::default()
    .setup(|app| {
        #[cfg(desktop)]
        app.handle().plugin(tauri_plugin_updater::Builder::new().build())?;
        Ok(())
    })
```

### Capabilities (src-tauri/capabilities/default.json)

Add `"updater:default"` to the `permissions` array.

## tauri.conf.json

```jsonc
{
  "bundle": {
    "createUpdaterArtifacts": true   // "v1Compatible" when migrating from v1
  },
  "plugins": {
    "updater": {
      "pubkey": "dW50cnVzdGVkIGNvbW1lbnQ...",           // contents of .key.pub
      "endpoints": [
        "https://github.com/USER/REPO/releases/latest/download/latest.json"
      ],
      "windows": {
        "installMode": "passive"     // "passive" | "basicUi" | "quiet"
      }
    }
  }
}
```

Endpoint URL variables (auto-replaced): `{{current_version}}`, `{{target}}` (linux/windows/darwin), `{{arch}}` (x86_64/aarch64/i686/armv7).

## Ed25519 Signature Verification

### Generate keypair

```bash
tauri signer generate -w ~/.tauri/myapp.key
# Prompts for password
# Creates: ~/.tauri/myapp.key (private) and ~/.tauri/myapp.key.pub (public)
```

- **Public key** goes in `tauri.conf.json` under `plugins.updater.pubkey`.
- **Private key** signs artifacts at build time. Set env vars for CI:
  - `TAURI_SIGNING_PRIVATE_KEY` — contents of the .key file
  - `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` — the password used during generation

Never commit the private key. Losing it means existing users cannot update.

The signature system uses Minisign (Ed25519). Each updater artifact gets a corresponding `.sig` file generated during `tauri build`.

## Update Endpoint Formats

### Static JSON (GitHub Releases / CDN)

Filename: `latest.json` — uploaded as a release asset.

```json
{
  "version": "1.2.0",
  "notes": "Bug fixes and performance improvements.",
  "pub_date": "2026-03-29T12:00:00Z",
  "platforms": {
    "linux-x86_64": {
      "url": "https://github.com/USER/REPO/releases/download/v1.2.0/myapp_1.2.0_amd64.AppImage.tar.gz",
      "signature": "dW50cnVzdGVkIGNvbW1lbnQ..."
    },
    "darwin-x86_64": {
      "url": "https://...myapp.app.tar.gz",
      "signature": "..."
    },
    "darwin-aarch64": {
      "url": "https://...myapp.app.tar.gz",
      "signature": "..."
    },
    "windows-x86_64": {
      "url": "https://...myapp_1.2.0_x64-setup.nsis.zip",
      "signature": "..."
    }
  }
}
```

Required keys: `version`, `platforms.<target>.url`. `signature` required when pubkey is configured. `pub_date` must be ISO 8601 if present.

Platform keys: `linux-x86_64`, `linux-aarch64`, `darwin-x86_64`, `darwin-aarch64`, `windows-x86_64`, `windows-i686`.

### Dynamic endpoint (custom server)

Server responds:
- **200 OK** + JSON when update available:
  ```json
  { "url": "https://...", "version": "1.2.0", "signature": "...", "notes": "...", "pub_date": "..." }
  ```
  Required keys: `url`, `version`, `signature`.
- **204 No Content** when no update available.

## Platform-Specific Artifacts

| Platform | Updater artifact | Source |
|----------|-----------------|--------|
| Linux | `.AppImage.tar.gz` + `.AppImage.tar.gz.sig` | AppImage wrapped in tar.gz |
| macOS | `.app.tar.gz` + `.app.tar.gz.sig` | Entire .app bundle in tar.gz |
| Windows | `_x64-setup.nsis.zip` + `.nsis.zip.sig` | NSIS installer in zip |

Generated automatically by `tauri build` when `createUpdaterArtifacts` is set.

## Update Lifecycle (JavaScript)

```javascript
import { check } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";

const update = await check();           // returns null if no update
if (update) {
  console.log(`Update to ${update.version}, notes: ${update.body}`);

  // Download with progress tracking
  let totalBytes = 0;
  await update.downloadAndInstall((event) => {
    if (event.event === "Started") {
      console.log(`Download size: ${event.data.contentLength}`);
    } else if (event.event === "Progress") {
      totalBytes += event.data.chunkLength;
    } else if (event.event === "Finished") {
      console.log("Download complete");
    }
  });

  await relaunch();                     // restart the app
}
```

Requires `"process:default"` in capabilities for `relaunch()`.

### Download events

- `Started` — `{ contentLength: number | undefined }`
- `Progress` — `{ chunkLength: number }`
- `Finished` — download complete, installation begins

## Manual vs Automatic Checking

**Manual** (recommended): Call `check()` in your own code on a button click, timer, or app startup. Full control over UI and timing.

**Automatic**: Not built-in for v2. Implement with a periodic timer:

```javascript
setInterval(async () => {
  const update = await check();
  if (update) { /* notify user */ }
}, 60 * 60 * 1000); // hourly
```

## Version Comparison

Versions are compared using semantic versioning. The updater only offers an update when the remote `version` is strictly greater than `current_version` from `tauri.conf.json`. Pre-release tags are supported per semver rules.

## Error Handling

```javascript
try {
  const update = await check();
  if (update) {
    await update.downloadAndInstall();
  }
} catch (e) {
  console.error("Update failed:", e);
  // Common errors:
  // - Network unreachable / endpoint 404
  // - Signature verification failed (wrong pubkey or tampered artifact)
  // - Invalid JSON response from endpoint
}
```

On signature mismatch, the update is rejected entirely — no partial install.

## Windows: UAC and Install Modes

| Mode | Behavior | UAC |
|------|----------|-----|
| `passive` | Small progress window, no interaction needed | Can request elevation |
| `basicUi` | Full UI, user clicks through steps | Can request elevation |
| `quiet` | No UI at all | Cannot self-elevate; only works for per-user installs or already-elevated processes |

Set in `plugins.updater.windows.installMode`. Default is `passive`.

NSIS installers that require admin privileges may have issues with UAC prompts during quiet updates. Use `passive` mode unless you have a specific reason not to.

## macOS: Code Signing for Updates

- Updater artifacts must be signed and notarized for Gatekeeper to allow installation.
- Sign with `codesign` and notarize with `xcrun notarytool` as part of your release pipeline.
- The Ed25519 signature (Minisign) is separate from Apple code signing — both are required. Minisign verifies integrity; Apple signing satisfies Gatekeeper.
- Unsigned local builds: users must run `xattr -cr /path/to/App.app` after manual update.

## GitHub Actions Integration

The official `tauri-apps/tauri-action` GitHub Action:
- Builds platform artifacts
- Signs them with `TAURI_SIGNING_PRIVATE_KEY`
- Generates `latest.json` with all platform URLs and signatures
- Uploads everything as release assets

Set `TAURI_SIGNING_PRIVATE_KEY` and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` as repository secrets.
