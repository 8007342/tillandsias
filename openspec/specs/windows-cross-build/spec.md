<!-- @trace spec:windows-cross-build -->
# windows-cross-build Specification

## Status

status: suspended

## Purpose
TBD - created by archiving change local-cross-platform-builds. Update Purpose after archive.
## Requirements
### Requirement: Windows cross-compilation script
The project SHALL provide a `build-windows.sh` script that cross-compiles the Rust workspace for `x86_64-pc-windows-msvc` from a Linux host using `cargo-xwin`.

#### Scenario: Default invocation
- **WHEN** `./build-windows.sh` is run with no arguments
- **THEN** a debug cross-compilation targeting `x86_64-pc-windows-msvc` runs inside the `tillandsias-windows` toolbox

#### Scenario: Release build
- **WHEN** `./build-windows.sh --release` is run
- **THEN** `cargo tauri build` runs via cargo-xwin, producing unsigned NSIS and/or MSI artifacts in `target/x86_64-pc-windows-msvc/release/bundle/`

#### Scenario: Test execution
- **WHEN** `./build-windows.sh --test` is run
- **THEN** `cargo test --workspace` runs cross-compiled for the Windows target (compile-only verification, not execution)

#### Scenario: Check only
- **WHEN** `./build-windows.sh --check` is run
- **THEN** `cargo check --workspace --target x86_64-pc-windows-msvc` runs without producing artifacts

#### Scenario: Clean build
- **WHEN** `./build-windows.sh --clean` is run
- **THEN** Windows cross-compilation artifacts are removed before building

#### Scenario: Help flag
- **WHEN** `./build-windows.sh --help` is run
- **THEN** usage information is displayed including all available flags

### Requirement: Dedicated Windows toolbox
The script SHALL use a separate `tillandsias-windows` toolbox for cross-compilation dependencies, isolated from the main `tillandsias` toolbox.

#### Scenario: First run creates toolbox
- **WHEN** `./build-windows.sh` is run and no `tillandsias-windows` toolbox exists
- **THEN** the toolbox is created with clang, lld, and cargo-xwin installed

#### Scenario: Subsequent runs reuse toolbox
- **WHEN** `./build-windows.sh` is run and the `tillandsias-windows` toolbox already exists
- **THEN** the build proceeds immediately with no setup overhead

#### Scenario: Toolbox reset
- **WHEN** `./build-windows.sh --toolbox-reset` is run
- **THEN** the `tillandsias-windows` toolbox is destroyed and recreated from scratch

### Requirement: Microsoft SDK license notice
The script SHALL display a notice about the Microsoft CRT/SDK license terms on first use of cargo-xwin.

#### Scenario: First SDK download
- **WHEN** cargo-xwin downloads the Windows SDK for the first time
- **THEN** the script prints a visible notice that the download accepts Microsoft's SDK license terms

#### Scenario: Subsequent builds
- **WHEN** the SDK is already cached from a prior build
- **THEN** no license notice is shown and the build starts immediately

### Requirement: Unsigned artifact warning
The script SHALL clearly indicate that cross-compiled artifacts are unsigned and for testing only.

#### Scenario: Release build output
- **WHEN** a release build completes successfully
- **THEN** the script prints a warning that artifacts are unsigned and unsuitable for distribution
- **AND** lists the produced artifacts with file sizes

#### Scenario: Signing key absent
- **WHEN** `TAURI_SIGNING_PRIVATE_KEY` is not set
- **THEN** the script does not fail but warns that Tauri update signatures are not generated


## Sources of Truth

- `cheatsheets/build/cargo.md` — Cargo reference and patterns
- `cheatsheets/build/nix-flake-basics.md` — Nix Flake Basics reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:windows-cross-build" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
