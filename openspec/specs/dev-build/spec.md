<!-- @trace spec:dev-build -->
# dev-build Specification

## Status

active

## Purpose
TBD - created by archiving change dev-build-script. Update Purpose after archive.
## Requirements
### Requirement: Toolbox auto-creation
The build script SHALL auto-create the `tillandsias` toolbox with all build dependencies if it does not exist.

#### Scenario: First run on fresh checkout
- **WHEN** `./build.sh` is run and no `tillandsias` toolbox exists
- **THEN** the toolbox SHALL be created, system dependencies SHALL be installed, and the build SHALL proceed

#### Scenario: Subsequent runs
- **WHEN** `./build.sh` is run and the `tillandsias` toolbox already exists
- **THEN** the build SHALL proceed immediately with no setup overhead

### Requirement: Debug build by default
Running `./build.sh` with no flags SHALL perform a debug workspace build inside the toolbox.

#### Scenario: Default invocation
- **WHEN** `./build.sh` is run with no arguments
- **THEN** `cargo build --workspace` SHALL run inside the `tillandsias` toolbox

### Requirement: Release build
The `--release` flag SHALL produce a Tauri release bundle.

#### Scenario: Release build
- **WHEN** `./build.sh --release` is run
- **THEN** `cargo tauri build` SHALL run inside the toolbox, producing platform-native bundles in `src-tauri/target/release/bundle/`

### Requirement: Test execution
The `--test` flag SHALL run the full test suite.

#### Scenario: Run tests
- **WHEN** `./build.sh --test` is run
- **THEN** `cargo test --workspace` SHALL run inside the toolbox and SHALL report results

### Requirement: Clean build
The `--clean` flag SHALL remove all build artifacts before building.

#### Scenario: Clean then build
- **WHEN** `./build.sh --clean` is run
- **THEN** `cargo clean` SHALL run first, then the default build SHALL proceed

#### Scenario: Clean with release
- **WHEN** `./build.sh --clean --release` is run
- **THEN** `cargo clean` SHALL run first, then a release build SHALL proceed

### Requirement: Install to local path
The `--install` flag SHALL build a release binary and copy it to `~/.local/bin/` with only non-executable supporting files.

#### Scenario: Install binary
- **WHEN** `./build.sh --install` is run
- **THEN** the binary and runtime libraries SHALL be installed to `~/.local/bin/` and `~/.local/lib/tillandsias/`
- **AND** icons SHALL be installed for the desktop launcher
- **AND** no shell scripts, flake files, or image sources MUST be copied to `~/.local/share/tillandsias/`

### Requirement: Remove installed binary
The `--remove` flag SHALL remove the installed binary from `~/.local/bin/`.

#### Scenario: Remove binary
- **WHEN** `./build.sh --remove` is run
- **THEN** `~/.local/bin/tillandsias` SHALL be deleted if it exists

### Requirement: Wipe caches and artifacts
The `--wipe` flag SHALL remove all caches and build artifacts.

#### Scenario: Wipe everything
- **WHEN** `./build.sh --wipe` is run
- **THEN** `target/`, `~/.cache/tillandsias/`, and any temporary build files SHALL be removed

### Requirement: Toolbox reset
The `--toolbox-reset` flag SHALL destroy and recreate the toolbox from scratch.

#### Scenario: Reset toolbox
- **WHEN** `./build.sh --toolbox-reset` is run
- **THEN** the `tillandsias` toolbox SHALL be removed and recreated with fresh dependencies

### Requirement: Installer triggers init
The installer script SHALL run `tillandsias --init` as a background task after installation.

#### Scenario: Fresh install
- **WHEN** `install.sh` completes the binary installation
- **THEN** `tillandsias --init` SHALL be spawned as a background process
- **AND** the installer SHALL print a message indicating images are building in the background

### Requirement: Cross-platform build documentation
The project SHALL include documentation at `docs/cross-platform-builds.md` explaining the cross-platform build strategy and legal constraints.

#### Scenario: macOS infeasibility documented
- **WHEN** a developer reads `docs/cross-platform-builds.md`
- **THEN** they SHALL find a clear explanation that macOS cross-compilation from Linux is not feasible due to Apple EULA restrictions and Tauri's native framework requirements

#### Scenario: Windows cross-compilation documented
- **WHEN** a developer reads `docs/cross-platform-builds.md`
- **THEN** they SHALL find instructions for using `build-windows.sh` with its limitations (unsigned, experimental)

#### Scenario: CI-first strategy documented
- **WHEN** a developer reads `docs/cross-platform-builds.md`
- **THEN** they SHALL understand that CI (GitHub Actions) remains the authoritative build pipeline for all platforms, and local cross-compilation is supplementary for troubleshooting

### Requirement: Install exits with deterministic exit codes
The `--install` flag SHALL exit with code 0 (success) or 1 (failure), enabling chaining with subsequent commands.

#### Scenario: Install succeeds
- **WHEN** `./build.sh --install` completes successfully
- **THEN** the command SHALL exit with code 0
- **AND** critical images SHALL be built and binary SHALL be installed
- **AND** a `[build] SUCCESS` message SHALL be printed to stdout
- **AND** MUST be safe to chain: `./build.sh --install && tillandsias --init --debug && tillandsias /path --diagnostics`

#### Scenario: Install fails
- **WHEN** `./build.sh --install` fails (image build failed or binary copy failed)
- **THEN** the command SHALL exit with code 1
- **AND** a `[build] ERROR` message SHALL be printed to stderr
- **AND** MUST be safe for error handling: `./build.sh --install || echo "build failed; fix errors above"`


## Sources of Truth

- `cheatsheets/build/cargo.md` — Cargo reference and patterns
- `cheatsheets/build/nix-flake-basics.md` — Nix Flake Basics reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:environment-isolation`

Gating points:
- Dev builds are isolated from host system; no build artifacts leak to host
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:dev-build" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
