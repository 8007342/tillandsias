# fix-appimage-autoupdate Specification

## Purpose
Fix the five broken links in the AppImage auto-update chain so both the Tauri built-in updater and the `--update` CLI flag can discover, download, and apply updates from GitHub Releases.

## Requirements

### Requirement: Release workflow produces latest.json
The release CI workflow SHALL generate a valid `latest.json` manifest and upload it as a GitHub Release asset so the Tauri updater plugin and `--update` CLI can discover available updates.

#### Scenario: latest.json is present in every release
- **WHEN** the release workflow completes successfully
- **THEN** a `latest.json` file exists as a release asset at the URL configured in `tauri.conf.json`

#### Scenario: latest.json contains all platform entries
- **WHEN** the release workflow generates `latest.json`
- **THEN** it contains entries for `linux-x86_64`, `darwin-aarch64`, `darwin-x86_64`, and `windows-x86_64` with download URLs and Ed25519 signatures

#### Scenario: latest.json version matches the release tag
- **WHEN** `latest.json` is generated
- **THEN** the `version` field matches the 3-part semver from Cargo.toml (not the 4-part VERSION file)

### Requirement: Updater artifacts are collected and uploaded
The release workflow SHALL collect `.AppImage.tar.gz` (and its `.sig`) alongside the raw `.AppImage` so the Tauri updater has a valid download target.

#### Scenario: AppImage tar.gz in release assets
- **WHEN** the Linux build completes
- **THEN** `Tillandsias-linux-x86_64.AppImage.tar.gz` and `Tillandsias-linux-x86_64.AppImage.tar.gz.sig` appear in the release assets

### Requirement: Version comparison handles mixed formats
The `--update` CLI SHALL correctly compare 3-part CARGO_PKG_VERSION against potentially 4-part latest.json versions without false positives.

#### Scenario: Same base version is not newer
- **WHEN** CARGO_PKG_VERSION is `0.1.65` and latest.json reports `0.1.65.38`
- **THEN** `--update` reports "Already up to date" (build suffix is ignored)

#### Scenario: Higher minor version is newer
- **WHEN** CARGO_PKG_VERSION is `0.1.65` and latest.json reports `0.2.0`
- **THEN** `--update` reports an update is available

### Requirement: HTTPS requests use rustls
The `reqwest` dependency SHALL have the `rustls-tls` feature enabled so HTTPS requests succeed without system OpenSSL.

#### Scenario: --update fetches latest.json over HTTPS
- **WHEN** the user runs `tillandsias --update`
- **THEN** the HTTPS request to GitHub Releases succeeds using rustls (no system libssl dependency)
