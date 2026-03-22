## Why

Tillandsias targets three platforms (Linux, macOS, Windows) and must be distributed as a single download-and-run binary per platform. Without automated release builds, every release requires manual compilation on three operating systems, manual checksum generation, and manual upload to GitHub Releases. This is error-prone, time-consuming, and blocks the release cadence needed for an early-stage project iterating quickly.

GitHub Actions provides free CI/CD with access to Linux, macOS, and Windows runners. A matrix build triggered by version tags produces all platform artifacts in a single automated pipeline. SHA256 checksums are generated alongside artifacts, giving users a baseline integrity check before Cosign signing is added in Phase 2.

This is Phase 1 of the release strategy defined in TILLANDSIAS-RELEASE.md. It establishes the foundation that Phase 2 (Cosign signing) and Phase 3 (auto-updater) build upon.

## What Changes

- **New GitHub Actions workflow** (`.github/workflows/release.yml`) triggered on `v*` tag pushes, building Tauri desktop bundles for Linux (AppImage), macOS (.app in .dmg), and Windows (.exe) via a matrix strategy
- **SHA256 checksum generation** as a post-build step, producing a `SHA256SUMS` file covering all release artifacts
- **GitHub Release automation** that creates a draft release, uploads all artifacts and checksums, then publishes with auto-generated release notes
- **Artifact naming convention** using `tillandsias-{version}-{target}` pattern for predictable, scriptable downloads
- **Dependency pinning** with hash-pinned actions to prevent supply chain attacks on the CI pipeline itself

## Capabilities

### New Capabilities
- `ci-release`: GitHub Actions release pipeline -- matrix builds across Linux/macOS/Windows, Tauri bundle packaging, SHA256 checksum generation, GitHub Releases upload, artifact naming convention, dependency pinning

### Modified Capabilities
<!-- None -- this is new CI infrastructure -->

## Impact

- **New files**: `.github/workflows/release.yml`, `scripts/checksum.sh`
- **GitHub configuration**: Repository needs `contents: write` permission for the release workflow GITHUB_TOKEN
- **Tauri build**: Relies on existing `src-tauri/tauri.conf.json` bundle configuration (`targets: "all"`)
- **No code changes**: The Rust codebase and Tauri configuration are not modified; this change only adds CI infrastructure
- **Release cadence**: Developers push a `v*` tag; the pipeline handles everything else
