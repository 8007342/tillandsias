# Research: macOS App Signing and Notarization

## The Problem
Currently, Tillandsias for macOS is distributed via a `.dmg` built with ad-hoc signing (`codesign --force --sign -`). When users download the app outside of the Mac App Store, macOS Gatekeeper blocks execution with an "App is damaged" or "Unverified Developer" warning.

## Gatekeeper Requirements
To bypass these warnings and allow users to run the app seamlessly, Apple requires:
1. **Valid Code Signature**: The `.app` bundle must be signed using a "Developer ID Application" certificate obtained from a paid Apple Developer Program.
2. **Hardened Runtime**: The app must be signed with the `--options runtime` flag. This enforces strict memory and execution constraints.
3. **Notarization**: The final `.dmg` or `.zip` must be uploaded to Apple's notarization service (`notarytool`), where it is scanned for malicious content. 
4. **Stapling**: Apple provides a "ticket" after successful notarization. This ticket must be "stapled" to the `.dmg` (`xcrun stapler staple <file>`) so it can be verified offline.

## Authentication with Apple Servers
Apple replaced `altool` with `xcrun notarytool`. Notarytool requires authentication via either:
1. App-Specific Password (tied to an Apple ID).
2. App Store Connect API Key (recommended for CI/CD).

The API Key is preferred as it is scoped to the team rather than an individual developer. We will need to securely store this key in GitHub Actions (or HashiCorp Vault) for the CI pipeline.
