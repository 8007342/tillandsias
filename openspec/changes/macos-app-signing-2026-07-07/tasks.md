# Operator Checklist: Establishing macOS Notarization

Follow these steps to wire up the new Apple Developer Program subscription to the build pipeline.

## 1. Generate Apple Certificates and Keys
- [ ] Log in to the [Apple Developer Portal](https://developer.apple.com/account).
- [ ] Navigate to **Certificates, Identifiers & Profiles** -> **Certificates**.
- [ ] Create a new **Developer ID Application** certificate. Download the `.cer` file and install it in your local macOS Keychain.
- [ ] Export the Certificate and Private Key from Keychain Access as a `.p12` file (you will need to set a password for the export).
- [ ] Navigate to **Users and Access** -> **Keys** in App Store Connect.
- [ ] Create a new **App Store Connect API Key** with **App Manager** access.
- [ ] Download the `.p8` key file. Note your **Issuer ID** and the **Key ID**.

## 2. Configure Local Environment (Optional for local testing)
- [ ] Add the following variables to your local shell profile (or a `.env` file):
  - `APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name/Org (TEAM_ID)"`
  - `APPLE_API_KEY_ID="<your-key-id>"`
  - `APPLE_API_ISSUER="<your-issuer-id>"`
  - `APPLE_API_KEY_PATH="/path/to/AuthKey_XYZ.p8"`

## 3. Implement the Build Script Changes
- [ ] Modify `scripts/build-macos-tray.sh` per the `proposal.md` to conditionally apply the hardened runtime (`--options runtime --timestamp`) and use `$APPLE_SIGNING_IDENTITY`.
- [ ] Modify `scripts/build-macos-dmg.sh` to sign the resulting `.dmg`.
- [ ] Append the `xcrun notarytool submit` and `xcrun stapler staple` logic to `build-macos-dmg.sh`, conditioned on the presence of the App Store Connect credentials.

## 4. Configure CI/CD Secrets
- [ ] Go to the GitHub repository Settings -> Secrets and variables -> Actions.
- [ ] Add the following Secrets:
  - `MAC_CERTS_P12` (Base64 encoded string of your `.p12` certificate file).
  - `MAC_CERTS_PASSWORD` (The password you set when exporting the `.p12`).
  - `MAC_API_KEY_P8` (The raw contents of the `.p8` key file).
  - `MAC_API_KEY_ID`
  - `MAC_API_ISSUER`
- [ ] Update `.github/workflows/release.yml` to import the keychain (e.g. via `apple-actions/import-codesign-certs`) and pass these secrets to the build script environment.

## 5. Verify the Release
- [ ] Trigger a release dry-run or push a tagged commit.
- [ ] Verify the GitHub Actions log shows successful `notarytool` submission (Status: Accepted).
- [ ] Download the `.dmg` from the release artifact.
- [ ] Run `spctl -a -t open --context context:primary-signature ./Tillandsias.app` to verify Gatekeeper acceptance.
- [ ] Double-click the `.dmg` and drag to Applications — confirm the "Unverified Developer" warning is completely gone!
