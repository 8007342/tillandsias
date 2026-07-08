# Implementation Proposal: Integrating Code Signing & Notarization

## Objective
Update the macOS build and release scripts to automatically sign and notarize `Tillandsias.app` and `Tillandsias.dmg` when valid Developer ID credentials are provided. Fall back to ad-hoc signing gracefully in local development.

## 1. Modify `build-macos-tray.sh` (App Bundle Signing)
- Introduce a check for `APPLE_SIGNING_IDENTITY` (e.g., `Developer ID Application: Team Name (ID)`).
- If present, replace `codesign --force --sign -` with `codesign --force --sign "$APPLE_SIGNING_IDENTITY" --options runtime --timestamp`.
- Retain the existing `--entitlements` flag, as Virtualization.framework requires specific entitlements which must now be hardened.

## 2. Modify `build-macos-dmg.sh` (DMG Signing & Notarization)
- After the `.dmg` is created by `create-dmg` or `hdiutil`, sign the `.dmg` itself using the same `APPLE_SIGNING_IDENTITY`.
- Implement a Notarization subroutine using `xcrun notarytool`:
  - Check for App Store Connect API keys (e.g., `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`, and the actual p8 key path).
  - Invoke `xcrun notarytool submit "$DMG_PATH" --key "$KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" --wait`.
  - Check the exit code. If successful, run `xcrun stapler staple "$DMG_PATH"`.
- If credentials are not provided (local dev), skip notarization and print a warning.

## 3. CI/CD Integration (`.github/workflows/release.yml`)
- Create GitHub Actions Secrets for the Apple certificates and API key.
- Inject a step before `scripts/build-macos-dmg.sh` to install the Apple certificate into the macOS keychain (using standard Actions or `apple-actions/import-codesign-certs`).
- Pass the necessary environment variables to the build scripts.
