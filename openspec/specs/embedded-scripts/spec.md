# embedded-scripts Specification

## Purpose
TBD - created by archiving change embed-scripts-in-binary. Update Purpose after archive.
## Requirements
### Requirement: Scripts embedded in binary
All executable scripts SHALL be embedded in the compiled binary via `include_str!` and extracted to a temporary directory at runtime.

#### Scenario: gh-auth-login.sh execution
- **WHEN** the user triggers GitHub Login from the tray
- **THEN** the binary writes the embedded `gh-auth-login.sh` to `$XDG_RUNTIME_DIR/tillandsias/gh-auth-login.sh`, sets it executable, and passes the temp path to `open_terminal()`

#### Scenario: build-image.sh execution
- **WHEN** the binary needs to build a container image
- **THEN** the binary writes embedded `build-image.sh` and `ensure-builder.sh` to a temp directory and executes from there

#### Scenario: Image source extraction for nix build
- **WHEN** `build-image.sh` needs image sources (flake.nix, entrypoint, configs, locales)
- **THEN** the binary writes the full embedded image source tree to a temp directory — including `images/default/locales/` with all locale shell scripts — passes the path to the build script, and cleans up after

#### Scenario: Locale files included in image source extraction
- **WHEN** `write_image_sources()` extracts the image source tree
- **THEN** the directory `images/default/locales/` SHALL exist in the extracted tree
- **AND** it SHALL contain `en.sh` and `es.sh` with content matching the compile-time `include_str!` values

#### Scenario: Temp file permissions
- **WHEN** an embedded script is written to temp
- **THEN** the file is created with mode 0700 (owner read/write/execute only)

#### Scenario: Temp file cleanup
- **WHEN** an embedded script finishes executing
- **THEN** the temp files are deleted (or left for session cleanup if immediate deletion isn't possible)

### Requirement: No executable scripts in install directory
The `build.sh --install` target SHALL NOT copy any executable scripts to `~/.local/share/tillandsias/`.

#### Scenario: Install contents
- **WHEN** `./build.sh --install` completes
- **THEN** `~/.local/share/tillandsias/` contains only non-executable data: icons
- **AND** no `.sh` files exist in the install directory or its subdirectories

#### Scenario: Uninstall unchanged
- **WHEN** `./build.sh --remove` is run
- **THEN** `~/.local/share/tillandsias/` is removed as before

