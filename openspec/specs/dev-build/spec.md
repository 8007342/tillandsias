# dev-build Specification

## Purpose
TBD - created by archiving change dev-build-script. Update Purpose after archive.
## Requirements
### Requirement: Toolbox auto-creation
The build script SHALL auto-create the `tillandsias` toolbox with all build dependencies if it does not exist.

#### Scenario: First run on fresh checkout
- **WHEN** `./build.sh` is run and no `tillandsias` toolbox exists
- **THEN** the toolbox is created, system dependencies are installed, and the build proceeds

#### Scenario: Subsequent runs
- **WHEN** `./build.sh` is run and the `tillandsias` toolbox already exists
- **THEN** the build proceeds immediately with no setup overhead

### Requirement: Debug build by default
Running `./build.sh` with no flags SHALL perform a debug workspace build inside the toolbox.

#### Scenario: Default invocation
- **WHEN** `./build.sh` is run with no arguments
- **THEN** `cargo build --workspace` runs inside the `tillandsias` toolbox

### Requirement: Release build
The `--release` flag SHALL produce a Tauri release bundle.

#### Scenario: Release build
- **WHEN** `./build.sh --release` is run
- **THEN** `cargo tauri build` runs inside the toolbox, producing platform-native bundles in `src-tauri/target/release/bundle/`

### Requirement: Test execution
The `--test` flag SHALL run the full test suite.

#### Scenario: Run tests
- **WHEN** `./build.sh --test` is run
- **THEN** `cargo test --workspace` runs inside the toolbox and reports results

### Requirement: Clean build
The `--clean` flag SHALL remove all build artifacts before building.

#### Scenario: Clean then build
- **WHEN** `./build.sh --clean` is run
- **THEN** `cargo clean` runs first, then the default build proceeds

#### Scenario: Clean with release
- **WHEN** `./build.sh --clean --release` is run
- **THEN** `cargo clean` runs first, then a release build proceeds

### Requirement: Install to local path
The `--install` flag SHALL build a release binary and copy it to `~/.local/bin/`.

#### Scenario: Install binary
- **WHEN** `./build.sh --install` is run
- **THEN** a release build is produced and the binary is copied to `~/.local/bin/tillandsias`

### Requirement: Remove installed binary
The `--remove` flag SHALL remove the installed binary from `~/.local/bin/`.

#### Scenario: Remove binary
- **WHEN** `./build.sh --remove` is run
- **THEN** `~/.local/bin/tillandsias` is deleted if it exists

### Requirement: Wipe caches and artifacts
The `--wipe` flag SHALL remove all caches and build artifacts.

#### Scenario: Wipe everything
- **WHEN** `./build.sh --wipe` is run
- **THEN** `target/`, `~/.cache/tillandsias/`, and any temporary build files are removed

### Requirement: Toolbox reset
The `--toolbox-reset` flag SHALL destroy and recreate the toolbox from scratch.

#### Scenario: Reset toolbox
- **WHEN** `./build.sh --toolbox-reset` is run
- **THEN** the `tillandsias` toolbox is removed and recreated with fresh dependencies

