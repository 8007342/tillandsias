# ci-release Specification

## Purpose
TBD - created by archiving change release-pipeline. Update Purpose after archive.
## Requirements
### Requirement: Tag-triggered release workflow
The release pipeline SHALL be triggered exclusively by git tag pushes matching the `v*` pattern. No other event SHALL trigger release builds.

#### Scenario: Version tag pushed
- **WHEN** a tag matching `v*` (e.g., `v0.1.0`, `v1.0.0-rc.1`) is pushed to the repository
- **THEN** the release workflow starts and builds artifacts for all configured platform targets

#### Scenario: Non-version tag pushed
- **WHEN** a tag not matching `v*` (e.g., `test-123`, `release-candidate`) is pushed
- **THEN** the release workflow does not trigger

#### Scenario: Regular commit pushed
- **WHEN** a commit is pushed to any branch (including `main`)
- **THEN** the release workflow does not trigger

### Requirement: Multi-platform matrix builds
The pipeline SHALL build Tauri desktop bundles for Linux, macOS, and Windows in parallel using a GitHub Actions matrix strategy.

#### Scenario: Linux build
- **WHEN** the release workflow runs
- **THEN** a Linux build job produces an AppImage artifact targeting `x86_64-unknown-linux-gnu`

#### Scenario: macOS build
- **WHEN** the release workflow runs
- **THEN** a macOS build job produces a .dmg artifact targeting `aarch64-apple-darwin`

#### Scenario: Windows build
- **WHEN** the release workflow runs
- **THEN** a Windows build job produces a .exe artifact targeting `x86_64-pc-windows-msvc`

#### Scenario: Parallel execution
- **WHEN** the matrix builds start
- **THEN** all three platform builds run concurrently, not sequentially

#### Scenario: Single platform failure
- **WHEN** one platform build fails and the others succeed
- **THEN** the successful artifacts are still available but the release is not created

### Requirement: Consistent artifact naming
All release artifacts SHALL follow the naming convention `tillandsias-{version}-{os}-{arch}.{ext}` regardless of Tauri's default output naming.

#### Scenario: Linux artifact name
- **WHEN** the Linux build completes
- **THEN** the artifact is named `tillandsias-v0.1.0-linux-x86_64.AppImage` (with the actual version from the tag)

#### Scenario: macOS artifact name
- **WHEN** the macOS build completes
- **THEN** the artifact is named `tillandsias-v0.1.0-macos-aarch64.dmg`

#### Scenario: Windows artifact name
- **WHEN** the Windows build completes
- **THEN** the artifact is named `tillandsias-v0.1.0-windows-x86_64.exe`

#### Scenario: Version extracted from tag
- **WHEN** the workflow processes a tag push
- **THEN** the version string is extracted from the git tag (e.g., `v0.2.3` from `refs/tags/v0.2.3`) and used in all artifact names

### Requirement: SHA256 checksum generation
The pipeline SHALL generate a `SHA256SUMS` file containing SHA256 checksums for every release artifact.

#### Scenario: Checksum file contents
- **WHEN** all platform builds complete successfully
- **THEN** a `SHA256SUMS` file is generated containing one line per artifact in the format `{hash}  {filename}`

#### Scenario: Checksum covers all artifacts
- **WHEN** the `SHA256SUMS` file is generated
- **THEN** every release artifact (AppImage, .dmg, .exe) has exactly one corresponding checksum entry

#### Scenario: User verifies checksum
- **WHEN** a user downloads `SHA256SUMS` and an artifact, then runs `sha256sum -c SHA256SUMS`
- **THEN** the verification passes if the artifact was not tampered with

### Requirement: GitHub Release automation
The pipeline SHALL create a GitHub Release as a draft, upload all artifacts and checksums, then publish the release.

#### Scenario: Release creation
- **WHEN** all builds and checksum generation complete successfully
- **THEN** a GitHub Release is created for the tag with auto-generated release notes

#### Scenario: Artifact upload
- **WHEN** the GitHub Release is created
- **THEN** all platform artifacts and the `SHA256SUMS` file are uploaded as release assets

#### Scenario: All builds must succeed
- **WHEN** any build in the matrix fails
- **THEN** the release is not created and no artifacts are published to GitHub Releases

### Requirement: Version consistency validation
The pipeline SHALL verify that the git tag version matches the version declared in the workspace `Cargo.toml`.

#### Scenario: Version match
- **WHEN** the tag is `v0.1.0` and `Cargo.toml` declares `version = "0.1.0"`
- **THEN** the build proceeds normally

#### Scenario: Version mismatch
- **WHEN** the tag is `v0.2.0` but `Cargo.toml` declares `version = "0.1.0"`
- **THEN** the workflow fails early with a clear error message indicating the version mismatch

### Requirement: Supply chain hardening
All third-party GitHub Actions used in the workflow SHALL be pinned by full commit SHA to prevent supply chain attacks via mutable version tags.

#### Scenario: Action pinning
- **WHEN** the workflow references a third-party action (e.g., `actions/checkout`)
- **THEN** the action is specified by full commit SHA with a version comment (e.g., `actions/checkout@<sha> # v4.1.0`)

#### Scenario: Permission scoping
- **WHEN** the workflow runs
- **THEN** the GITHUB_TOKEN has only the minimum required permissions (`contents: write` for release creation, no other elevated permissions)

