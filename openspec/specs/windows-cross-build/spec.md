<!-- @trace spec:windows-cross-build -->
<!-- @tombstone deferred:linux-native-portable-executable — Windows/macOS wrappers deferred. Linux is source of truth. -->
# windows-cross-build Specification

## Status

deferred

## Purpose
TBD - created by archiving change local-cross-platform-builds. Update Purpose after archive.
## Requirements
### Requirement: Windows cross-compilation script
The project MUST provide a `build-windows.sh` script that cross-compiles the Rust workspace for `x86_64-pc-windows-msvc` from a Linux host using `cargo-xwin`. @trace spec:windows-cross-build

#### Scenario: Default invocation
- **WHEN** `./build-windows.sh` is run with no arguments
- **THEN** a debug cross-compilation targeting `x86_64-pc-windows-msvc` MUST run inside the `tillandsias-windows` toolbox

#### Scenario: Release build
- **WHEN** `./build-windows.sh --release` is run
- **THEN** `cargo tauri build` MUST run via cargo-xwin, producing unsigned NSIS and/or MSI artifacts in `target/x86_64-pc-windows-msvc/release/bundle/`

#### Scenario: Test execution
- **WHEN** `./build-windows.sh --test` is run
- **THEN** `cargo test --workspace` MUST run cross-compiled for the Windows target (compile-only verification, not execution)

#### Scenario: Check only
- **WHEN** `./build-windows.sh --check` is run
- **THEN** `cargo check --workspace --target x86_64-pc-windows-msvc` MUST run without producing artifacts

#### Scenario: Clean build
- **WHEN** `./build-windows.sh --clean` is run
- **THEN** Windows cross-compilation artifacts MUST be removed before building

#### Scenario: Help flag
- **WHEN** `./build-windows.sh --help` is run
- **THEN** usage information MUST be displayed including all available flags

### Requirement: Dedicated Windows toolbox
The script MUST use a separate `tillandsias-windows` toolbox for cross-compilation dependencies, isolated from the main `tillandsias` toolbox.

#### Scenario: First run creates toolbox
- **WHEN** `./build-windows.sh` is run and no `tillandsias-windows` toolbox exists
- **THEN** the toolbox MUST be created with clang, lld, and cargo-xwin installed

#### Scenario: Subsequent runs reuse toolbox
- **WHEN** `./build-windows.sh` is run and the `tillandsias-windows` toolbox already exists
- **THEN** the build MUST proceed immediately with no setup overhead

#### Scenario: Toolbox reset
- **WHEN** `./build-windows.sh --toolbox-reset` is run
- **THEN** the `tillandsias-windows` toolbox MUST be destroyed and recreated from scratch

### Requirement: Microsoft SDK license notice
The script MUST display a notice about the Microsoft CRT/SDK license terms on first use of cargo-xwin.

#### Scenario: First SDK download
- **WHEN** cargo-xwin downloads the Windows SDK for the first time
- **THEN** the script MUST print a visible notice that the download accepts Microsoft's SDK license terms

#### Scenario: Subsequent builds
- **WHEN** the SDK is already cached from a prior build
- **THEN** no license notice SHOULD be shown and the build MUST start immediately

### Requirement: Unsigned artifact warning
The script MUST clearly indicate that cross-compiled artifacts are unsigned and for testing only.

#### Scenario: Release build output
- **WHEN** a release build completes successfully
- **THEN** the script MUST print a warning that artifacts are unsigned and unsuitable for distribution
- **AND** MUST list the produced artifacts with file sizes

#### Scenario: Signing key absent
- **WHEN** `TAURI_SIGNING_PRIVATE_KEY` is not set
- **THEN** the script MUST NOT fail but SHOULD warn that Tauri update signatures are not generated


## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee` — cross-compilation target isolation, toolbox lifecycle, artifact signing

Gating points:
- Cross-compilation script targets `x86_64-pc-windows-msvc` from Linux host via cargo-xwin
- Debug/release/test/check/clean build modes all work correctly
- Dedicated `tillandsias-windows` toolbox created on first run; reused on subsequent runs
- Microsoft SDK license notice shown on first SDK download; cached SDK skips notice
- Cross-compiled artifacts marked as unsigned and unsuitable for distribution
- TAURI_SIGNING_PRIVATE_KEY absence handled gracefully; no update signatures generated
- Help flag displays all available options

## Sources of Truth

- `cheatsheets/build/cargo.md` — Cargo reference and patterns
- `cheatsheets/build/nix-flake-basics.md` — Nix Flake Basics reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:windows-cross-build" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
