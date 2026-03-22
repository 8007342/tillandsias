## 1. Tauri Updater Plugin Setup

- [x] 1.1 Add `tauri-plugin-updater` dependency to `src-tauri/Cargo.toml`
- [x] 1.2 Register the updater plugin in the Tauri builder setup (`tauri::Builder::default().plugin(tauri_plugin_updater::Builder::new().build())`)
- [x] 1.3 Generate Tauri signing keypair using `tauri signer generate -w ~/.tauri/tillandsias.key` and record the public key

## 2. Update Endpoint Configuration

- [x] 2.1 Add `plugins.updater` section to `src-tauri/tauri.conf.json` with the GitHub Releases endpoint URL and the Ed25519 public key
- [x] 2.2 Configure platform-specific artifact targets in the updater config (AppImage for Linux, .app for macOS, .exe for Windows)
- [x] 2.3 Add updater permissions to `src-tauri/capabilities/` if required by Tauri v2 permission model

## 3. CI Signing Integration

- [x] 3.1 Add `TAURI_SIGNING_PRIVATE_KEY` and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` as GitHub repository secrets
- [x] 3.2 Update `.github/workflows/release.yml` to expose signing key secrets as environment variables during the Tauri build step
- [x] 3.3 Verify that `tauri build` produces signed update bundles when the signing key environment variables are set
- [x] 3.4 Verify that the CI build fails when the signing secrets are missing (preventing unsigned releases)

## 4. Update Check Logic

- [x] 4.1 Implement background update check as an async tokio task that runs after a 5-second post-startup delay
- [x] 4.2 Implement periodic update check using a configurable interval (default 6 hours) via a tokio timer
- [x] 4.3 Read `check_interval_hours` and `check_on_launch` from the global config at `~/.config/tillandsias/config.toml`
- [x] 4.4 Ensure the update check task never blocks the main event loop or the tray UI thread

## 5. Update Notification UX

- [x] 5.1 Add an "Update available (vX.Y.Z)" dynamic menu item to the tray menu when a new version is detected
- [x] 5.2 Ensure the update menu item persists across tray menu rebuilds (container state changes, project detection events)
- [x] 5.3 Fire a platform-native system notification (toast) on first detection of a new version during a session
- [x] 5.4 Add a progress indicator to the tray menu during update download (e.g., "Downloading update..." replacing the update menu item)

## 6. Signature Verification

- [x] 6.1 Verify that the Tauri updater plugin enforces Ed25519 signature verification before applying any update (this is default behavior — confirm it is not disabled)
- [x] 6.2 Test that an update bundle with a mismatched signature is rejected and no binary replacement occurs
- [x] 6.3 Test that an update bundle with no signature is rejected
- [x] 6.4 Confirm the public key in `tauri.conf.json` matches the private key used in CI

## 7. Graceful Restart

- [x] 7.1 Wire the update installation trigger to the existing graceful shutdown sequence: stop all managed containers (SIGTERM → 10s grace → SIGKILL), flush state, then allow binary replacement and relaunch
- [x] 7.2 Disable the update menu item during shutdown and restart to prevent duplicate actions
- [x] 7.3 Verify the application relaunches with the new version after binary replacement and the tray icon reappears

## 8. Offline Resilience

- [x] 8.1 Ensure update check failures (network timeout, DNS failure, HTTP errors) are caught and logged without surfacing error dialogs to the user
- [x] 8.2 Handle GitHub API rate limiting (HTTP 403/429) by silently deferring the check to the next scheduled interval
- [x] 8.3 Handle mid-download network loss by aborting the download and reverting the tray menu to "Update available" so the user can retry
- [x] 8.4 Verify that the application starts and runs normally with no network connectivity (no crash, no error dialog)

## 9. End-to-End Testing

- [x] 9.1 Publish a test release (e.g., `v0.1.1-rc.1`) and verify the running app detects it as an available update
- [x] 9.2 Approve the update via the tray menu and verify the download, signature verification, and binary replacement complete successfully
- [x] 9.3 Verify the application restarts with the new version after update
- [x] 9.4 Test the full flow on all three platforms (Linux AppImage, macOS .dmg, Windows .exe)
- [x] 9.5 Test offline behavior: disconnect network, launch app, verify no crash or error dialog
