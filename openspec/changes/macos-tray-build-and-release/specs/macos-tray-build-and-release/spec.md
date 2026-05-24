## ADDED Requirements

### Requirement: `scripts/build-macos-tray.sh` produces a signed `Tillandsias.app` bundle

A new shell script `scripts/build-macos-tray.sh` SHALL exist at the repository root that, when run on an Apple Silicon macOS host with the Rust toolchain installed, produces a complete `Tillandsias.app` bundle ready for distribution. The script SHALL:

1. Resolve the version string via `scripts/bump-version.sh --print`.
2. Run `cargo build --release -p tillandsias-macos-tray --target aarch64-apple-darwin`.
3. Assemble the bundle structure: `dist/Tillandsias.app/Contents/{MacOS, Resources}`.
4. Copy the built binary to `Contents/MacOS/tillandsias-tray`.
5. Substitute `@VERSION@` (full CalVer), `@VERSION_SHORT@` (major.minor only), and `@MIN_MACOS@` (`14.0`) in `crates/tillandsias-macos-tray/assets/Info.plist.template` and write the result to `Contents/Info.plist`.
6. Copy `crates/tillandsias-macos-tray/assets/icon.icns` (or a placeholder if absent) to `Contents/Resources/icon.icns`.
7. Ad-hoc codesign: `codesign --force --sign - --entitlements crates/tillandsias-macos-tray/assets/Tillandsias.entitlements --options runtime dist/Tillandsias.app`.
8. Verify the signature: `codesign --verify --deep --strict --verbose=2 dist/Tillandsias.app`. Exit non-zero if verification fails.
9. Tar+gzip the bundle: `tar -czf dist/tillandsias-tray-<version>-macos-arm64.tar.gz -C dist Tillandsias.app`.
10. Emit a `SHA256SUMS` line for the .tar.gz to `dist/SHA256SUMS`.

@trace spec:macos-tray-build-and-release

#### Scenario: Successful build produces all artifacts
- **WHEN** the script runs on a clean macOS host with `cargo`, `codesign`, `tar`, `shasum` available
- **THEN** `dist/Tillandsias.app/` SHALL exist with the expected structure
- **AND** `dist/tillandsias-tray-<version>-macos-arm64.tar.gz` SHALL exist
- **AND** `dist/SHA256SUMS` SHALL contain a line for the tarball
- **AND** `codesign --verify --deep --strict dist/Tillandsias.app` SHALL exit zero

#### Scenario: Build fails clearly on missing toolchain
- **WHEN** the `aarch64-apple-darwin` Rust target is not installed
- **THEN** the script SHALL exit non-zero with the message `error: install with 'rustup target add aarch64-apple-darwin'`

#### Scenario: Build fails clearly on non-Apple-Silicon host
- **WHEN** the script runs on an Intel Mac (`uname -m` returns `x86_64`)
- **THEN** the script SHALL exit non-zero with the message `error: build host must be Apple Silicon (uname -m must be arm64)`

### Requirement: `Tillandsias.app` Info.plist contract

The produced `Contents/Info.plist` SHALL contain:
- `CFBundleIdentifier = com.tillandsias.tray`
- `CFBundleExecutable = tillandsias-tray`
- `CFBundleShortVersionString = @VERSION_SHORT@` (substituted to the major.minor of the build, e.g. `0.2`)
- `CFBundleVersion = @VERSION@` (substituted to the full CalVer, e.g. `0.2.260524.7`)
- `LSMinimumSystemVersion = @MIN_MACOS@` (substituted to `14.0`)
- `LSUIElement = true` (menubar-only, no Dock icon)
- `NSPrincipalClass = NSApplication`

@trace spec:macos-tray-build-and-release, spec:macos-native-tray

#### Scenario: LSUIElement is true so the app stays out of the Dock
- **WHEN** the built `.app` is inspected with `/usr/libexec/PlistBuddy -c "Print :LSUIElement" Contents/Info.plist`
- **THEN** the output SHALL be `true`

#### Scenario: Version strings are correctly substituted
- **WHEN** the build runs at VERSION=0.2.260524.7
- **THEN** `Contents/Info.plist` SHALL contain `<key>CFBundleShortVersionString</key><string>0.2</string>`
- **AND** SHALL contain `<key>CFBundleVersion</key><string>0.2.260524.7</string>`

### Requirement: `Tillandsias.entitlements` declares the virtualization entitlement

A new entitlements plist `crates/tillandsias-macos-tray/assets/Tillandsias.entitlements` SHALL exist with at minimum:
```xml
<key>com.apple.security.virtualization</key><true/>
<key>com.apple.security.get-task-allow</key><true/>
```
The `com.apple.security.virtualization` entitlement SHALL be present because `Virtualization.framework` rejects unentitled processes at runtime. The `get-task-allow` entitlement is dev-mode only and MAY be removed in a future Developer ID signed release.

@trace spec:macos-tray-build-and-release

#### Scenario: Entitlements file exists and is plist-parseable
- **WHEN** `/usr/libexec/PlistBuddy -c "Print" crates/tillandsias-macos-tray/assets/Tillandsias.entitlements` runs
- **THEN** it SHALL exit zero
- **AND** the output SHALL contain `com.apple.security.virtualization = true`

#### Scenario: Codesigned app retains the virtualization entitlement
- **WHEN** the built and signed `.app` is queried with `codesign -d --entitlements - Tillandsias.app`
- **THEN** the output SHALL contain `<key>com.apple.security.virtualization</key><true/>`

### Requirement: `scripts/install-macos.sh` is the curl-installable entry point

A new shell script `scripts/install-macos.sh` SHALL exist that performs an idempotent installation when invoked via `curl -fsSL <url> | bash` on Apple Silicon macOS 14+. The script SHALL:

1. Refuse to run on non-Apple-Silicon hosts (`uname -m != arm64` → exit non-zero with a clear diagnostic).
2. Refuse to run on macOS < 14 (`sw_vers -productVersion` major version check → exit non-zero).
3. Resolve the latest release tag via the GitHub releases API (or accept `TILLANDSIAS_VERSION=<version>` env var to pin).
4. Download `tillandsias-tray-<version>-macos-arm64.tar.gz` and `SHA256SUMS` from the release.
5. Verify SHA-256 of the tarball against `SHA256SUMS`. Abort and clean up on mismatch.
6. Determine install location: `/Applications/` if writable without sudo, else `~/Applications/`. If neither, ask the user to choose.
7. If a previous `Tillandsias.app` exists at the install location: stop the running tray (`osascript -e 'tell application "tillandsias-tray" to quit'` with a 5-second wait, then `pkill -f tillandsias-tray`), back up to `Tillandsias.app.bak`, remove the old version.
8. Extract the .tar.gz to the install location.
9. If invoked with `--login-item`, register the .app as a Login Item via `osascript -e 'tell application "System Events" to make login item ...'`.
10. Print the Gatekeeper hint: `On first launch, macOS Gatekeeper may block the app. Right-click Tillandsias.app in /Applications/ and choose Open to bypass.`
11. `open -a Tillandsias.app` to launch and drop the menubar icon.

@trace spec:macos-tray-build-and-release

#### Scenario: Fresh install on Apple Silicon macOS 14
- **WHEN** `curl -fsSL <install-url> | bash` runs on a fresh Apple Silicon macOS 14.5 host
- **THEN** the script SHALL download the latest release artifact, verify SHA-256, extract to `/Applications/Tillandsias.app`, and `open` the app
- **AND** the menubar SHALL show the tillandsias icon within 5 seconds

#### Scenario: Install fails clearly on Intel Mac
- **WHEN** the script runs on a host where `uname -m` returns `x86_64`
- **THEN** the script SHALL exit non-zero with the message `error: Tillandsias v0.0.1 requires Apple Silicon (uname -m must be arm64; this host is x86_64)`

#### Scenario: Install fails clearly on macOS < 14
- **WHEN** the script runs on macOS 13.5
- **THEN** the script SHALL exit non-zero with the message `error: Tillandsias requires macOS 14.0 or later (this host: 13.5)`

#### Scenario: Idempotent re-install replaces previous version cleanly
- **WHEN** the script is run a second time with a newer version available
- **THEN** the running tray SHALL be asked to quit cleanly
- **AND** the previous `Tillandsias.app` SHALL be backed up to `Tillandsias.app.bak` before extraction
- **AND** the new version SHALL be opened automatically

### Requirement: `macos-build` CI job runs on every push to `linux-next` and on PRs

A new job `macos-build` SHALL exist in `.github/workflows/ci.yml` with `runs-on: macos-latest`. It SHALL:
1. Check out the repo.
2. Install Rust stable with `aarch64-apple-darwin` target.
3. Run `scripts/build-macos-tray.sh`.
4. Upload `dist/tillandsias-tray-*-macos-arm64.tar.gz` as a workflow artifact named `macos-tray-build`.
5. Job duration target: under 8 minutes typical (includes Rust toolchain + dependency cache hits).

@trace spec:macos-tray-build-and-release, spec:ci-release

#### Scenario: macos-build job runs on push to linux-next
- **WHEN** a commit is pushed to `linux-next`
- **THEN** the CI workflow SHALL execute the `macos-build` job
- **AND** the job SHALL produce a downloadable artifact named `macos-tray-build`

#### Scenario: macos-build is independent of the Linux build job
- **WHEN** the Linux build fails
- **THEN** the macos-build job SHALL still execute (parallel jobs, no inter-dependency)
- **AND** failure of one SHALL NOT mark the other failed

### Requirement: `macos-release` job uploads the artifact + install script + cosign bundle

A new job `macos-release` SHALL exist in `.github/workflows/release.yml` with `runs-on: macos-latest`. It SHALL:
1. Resolve the release version (same logic as the Linux job).
2. Run `scripts/build-macos-tray.sh`.
3. Sign the artifact with Cosign keyless OIDC (reuse the existing pattern from the Linux job).
4. Upload to the GitHub release: `tillandsias-tray-<version>-macos-arm64.tar.gz`, `tillandsias-tray-<version>-macos-arm64.tar.gz.cosign.bundle`, `install-macos.sh`, and a per-asset `SHA256SUMS` extension.
5. Job duration target: under 12 minutes typical.

@trace spec:macos-tray-build-and-release, spec:ci-release, spec:binary-signing

#### Scenario: Tagged release uploads macOS artifacts
- **WHEN** `gh workflow run release.yml -f version=v0.2.260524.7` is triggered
- **AND** the Linux release job completes
- **THEN** the GitHub release for the tag SHALL contain the macOS .tar.gz, its .cosign.bundle, and install-macos.sh

#### Scenario: Cosign verification succeeds on the published artifact
- **WHEN** a downloaded `tillandsias-tray-*-macos-arm64.tar.gz` and its `.cosign.bundle` are run through `cosign verify-blob --bundle <bundle> <artifact>`
- **THEN** verification SHALL succeed
- **AND** the certificate identity SHALL be the expected GitHub Actions OIDC identity

### Requirement: Curl-installable command exists in the release notes

Release notes for each tagged release SHALL include the macOS install command verbatim:
```
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install-macos.sh | bash
```
For pinned versions, the URL pattern `https://github.com/8007342/tillandsias/releases/download/<tag>/install-macos.sh` SHALL also work.

@trace spec:macos-tray-build-and-release

#### Scenario: Release notes include the macOS install command
- **WHEN** a release is published
- **THEN** its body SHALL contain the literal `curl -fsSL .../install-macos.sh | bash` line
- **AND** the URL SHALL resolve to the install script asset of that release
