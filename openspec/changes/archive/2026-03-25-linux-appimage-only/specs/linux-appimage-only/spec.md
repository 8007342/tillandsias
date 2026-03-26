# linux-appimage-only Specification

## Purpose
Tillandsias SHALL distribute on Linux exclusively via AppImage. All .deb, .rpm, APT repository, and COPR infrastructure SHALL be removed to eliminate packaging complexity while preserving the universal, rootless, auto-updating install experience.

## Requirements

### Requirement: install.sh downloads AppImage directly on Linux
The install script SHALL download the AppImage as the sole Linux installation method, with no package manager detection or sudo requirements.

#### Scenario: Standard Linux install
- **WHEN** a user runs the install script on any Linux distribution
- **THEN** the script downloads the AppImage to `~/.local/bin/tillandsias`
- **AND** sets the executable bit
- **AND** installs the `.desktop` file and icons

#### Scenario: Immutable OS (Silverblue/Kinoite)
- **WHEN** a user runs the install script on an immutable OS
- **THEN** the script prints "Immutable OS detected — installing to userspace"
- **AND** proceeds with the same AppImage download path (no rpm-ostree layering)

#### Scenario: No sudo available
- **WHEN** the script is piped from curl (no terminal) or sudo is unavailable
- **THEN** the install succeeds because no elevated privileges are needed

### Requirement: Release workflow produces only AppImage for Linux
The CI release workflow SHALL build and collect only AppImage (and its .sig) for the Linux platform. No .deb or .rpm artifacts SHALL be produced or uploaded.

#### Scenario: Linux build job completes
- **WHEN** the Linux build job runs `cargo tauri build`
- **THEN** the artifact collection step copies only `*.AppImage` and `*.AppImage.sig` files
- **AND** no `.deb` or `.rpm` files appear in the release

#### Scenario: APT repository job
- **WHEN** a release is triggered
- **THEN** no "Publish APT repository" job runs
- **AND** no gh-pages branch is updated

### Requirement: Local release build skips deb/rpm bundles
The `build.sh --release` command SHALL NOT produce .deb or .rpm bundles on Linux.

#### Scenario: Developer runs --release on Linux
- **WHEN** a developer runs `./build.sh --release`
- **THEN** `cargo tauri build --bundles none` is executed
- **AND** only the raw binary is produced (no .deb, no .rpm)
- **AND** the `--appimage` flag remains the way to build an AppImage locally

### Requirement: Tauri config has no deb/rpm bundle configuration
The `tauri.conf.json` SHALL NOT contain `linux.deb` or `linux.rpm` configuration sections.

#### Scenario: Tauri reads bundle config
- **WHEN** Tauri reads `tauri.conf.json` for bundling
- **THEN** no `deb` or `rpm` keys exist under `bundle.linux`
- **AND** the `bundle.targets` field remains `"all"` (macOS and Windows still get their platform bundles; Linux targets are controlled by the `--bundles` CLI flag)

### Requirement: Update documentation reflects AppImage-only
The UPDATING.md document SHALL NOT reference Fedora COPR, dnf, rpm-ostree, or manual .deb/.rpm downloads.

#### Scenario: User reads update documentation
- **WHEN** a user opens docs/UPDATING.md
- **THEN** the document describes the Tauri auto-updater and AppImage behavior
- **AND** no package manager update instructions appear for Linux

### Requirement: Packaging directory removed
The `packaging/` directory and all its contents SHALL be deleted from the repository.

#### Scenario: Repository structure
- **WHEN** a developer inspects the repository
- **THEN** no `packaging/` directory exists
- **AND** no `.spec` files, COPR scripts, or COPR documentation remain

### Requirement: macOS and Windows unchanged
All macOS (.dmg, .app.tar.gz) and Windows (.exe, .msi, .nsis.zip) build paths, artifact collection, and install paths SHALL remain exactly as they are.

#### Scenario: macOS build
- **WHEN** the macOS build job runs
- **THEN** .dmg and .app.tar.gz artifacts are produced and signed identically to before

#### Scenario: Windows build
- **WHEN** the Windows build job runs
- **THEN** .exe, .msi, and .nsis.zip artifacts are produced and signed identically to before
