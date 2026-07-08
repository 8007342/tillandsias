---
status: interactive
owner_host: macos
capability_tags: [macos, codesign, notarization]
---
# Interactive Plan: macOS App Signing and Notarization

Since you've acquired an Apple Developer Program subscription, we need to properly sign and notarize the `.app` bundle and `.dmg` to avoid Gatekeeper "unsigned" warnings.

## Prerequisites
1. Open **Keychain Access** and ensure you have a `Developer ID Application` certificate installed (for signing the `.app` and `.dmg`).
2. Generate an **app-specific password** for your Apple ID, or set up an App Store Connect API Key.
3. Have `xcrun` and Xcode Command Line Tools installed.

## Step 1: Sign the `.app` Bundle
The build script currently uses ad-hoc signing (`codesign --sign -`). We need to sign it with your certificate.
Run this in the terminal:
```bash
codesign --force --deep --options runtime --sign "Developer ID Application: YOUR_NAME (TEAM_ID)" dist/Tillandsias.app
```
(Replace `YOUR_NAME (TEAM_ID)` with the exact name from Keychain Access).

## Step 2: Build and Sign the DMG
Build the DMG as usual, then sign it:
```bash
scripts/build-macos-dmg.sh
codesign --force --sign "Developer ID Application: YOUR_NAME (TEAM_ID)" dist/Tillandsias.dmg
```

## Step 3: Notarize the DMG
Submit the `.dmg` to Apple's notarization service:
```bash
xcrun notarytool submit dist/Tillandsias.dmg --apple-id "YOUR_APPLE_ID" --password "YOUR_APP_SPECIFIC_PASSWORD" --team-id "YOUR_TEAM_ID" --wait
```

## Step 4: Staple the Ticket
Once notarization is approved, staple the ticket to the DMG so it works offline:
```bash
xcrun stapler staple dist/Tillandsias.dmg
```

## Step 5: Verify
Verify that the DMG is properly signed and notarized:
```bash
spctl -a -t open --context context:primarySignature -v dist/Tillandsias.dmg
```
