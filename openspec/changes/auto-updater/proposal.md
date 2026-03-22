## Why

Without automatic updates, users must manually check GitHub Releases, download the correct platform artifact, verify its integrity, and replace the running binary. Most users will never do this. They will run outdated versions with known bugs and missing security patches indefinitely. For a privacy-focused application, running stale software is a direct security risk.

Tauri v2 includes a built-in updater plugin (`tauri-plugin-updater`) that checks for new versions, downloads the update, verifies its signature, and replaces the binary -- all without the user needing to understand any of those steps. The UX is: a small notification appears, the user approves, and the update happens. Security is automatic and invisible, matching the guiding principle from TILLANDSIAS-RELEASE.md: "Verification must be invisible."

This is Phase 3 of the release strategy. It depends on Phase 1 (release-pipeline) for artifact hosting on GitHub Releases and Phase 2 (cosign-signing) for the trust foundation. The Tauri updater uses its own signature scheme (Ed25519 via a Tauri signing key), which provides the fast, offline-capable verification needed for the update flow. Cosign signatures remain available for independent manual verification.

## What Changes

- **Tauri updater plugin** (`tauri-plugin-updater`) added to the Tauri app configuration and Rust dependencies
- **Update endpoint** configured to read from GitHub Releases using Tauri's built-in GitHub release provider
- **Tauri signing key** generated and stored as a GitHub Actions secret for signing update bundles during CI
- **Update check logic** in the tray app: silent background check on startup and periodic interval, non-intrusive notification when an update is available, user-initiated install
- **CI workflow update** to sign Tauri bundles with the updater key during the build process
- **Update UX flow** designed for zero-friction: notification in tray, one-click approve, automatic restart

## Capabilities

### New Capabilities
- `update-system`: Tauri auto-updater integration -- silent version checks against GitHub Releases, background download of update artifacts, Ed25519 signature verification before install, user-approved installation with single-click approval, automatic restart after update, configurable check interval, offline resilience

### Modified Capabilities
<!-- Depends on ci-release and binary-signing but does not modify them; adds Tauri signing step to CI -->

## Impact

- **Modified files**: `src-tauri/tauri.conf.json` (updater configuration), `src-tauri/Cargo.toml` (add `tauri-plugin-updater`), `.github/workflows/release.yml` (add Tauri signing step)
- **New code**: Update check and notification logic in the tray app (Rust)
- **Secrets**: `TAURI_SIGNING_PRIVATE_KEY` and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` added to GitHub repository secrets
- **Key management**: One-time generation of a Tauri signing keypair; public key embedded in the app binary, private key stored only in CI secrets
- **UX surface**: New tray menu item "Update available" appears when an update is found; notification disappears after update or dismissal
- **Network**: App makes HTTPS requests to GitHub Releases API on startup and periodically (configurable, default every 6 hours) to check for updates
