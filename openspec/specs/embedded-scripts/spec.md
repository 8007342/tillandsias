<!-- @trace spec:embedded-scripts -->
## Status

active

## Requirements

### Requirement: Scripts embedded in binary

All executable scripts MUST be embedded in the compiled binary via `include_str!` and extracted to a temporary directory at runtime.

#### Scenario: gh-auth-login.sh execution

- **WHEN** the user triggers GitHub Login from the tray
- **THEN** the binary MUST write the embedded `gh-auth-login.sh` to `$XDG_RUNTIME_DIR/tillandsias/gh-auth-login.sh`, set it executable, and pass the temp path to `open_terminal()`

#### Scenario: build-image.sh execution

- **WHEN** the binary needs to build a container image
- **THEN** the binary MUST write embedded `build-image.sh` to a temp directory and execute from there

#### Scenario: Image source extraction for nix build

- **WHEN** `build-image.sh` needs image sources (flake.nix, entrypoint, configs, locales)
- **THEN** the binary MUST write the full embedded image source tree to a temp directory — including `images/default/locales/` with all locale shell scripts — pass the path to the build script, and clean up after

#### Scenario: Locale files included in image source extraction

- **WHEN** `write_image_sources()` extracts the image source tree
- **THEN** the directory `images/default/locales/` MUST exist in the extracted tree
- **AND** it MUST contain `en.sh` and `es.sh` with content matching the compile-time `include_str!` values

#### Scenario: Temp file permissions

- **WHEN** an embedded script is written to temp
- **THEN** the file MUST be created with mode 0700 (owner read/write/execute only)

#### Scenario: Temp file cleanup

- **WHEN** an embedded script finishes executing
- **THEN** the temp files MUST be deleted (or left for session cleanup if immediate deletion is not possible)

## Litmus Tests

### test_script_embedded_in_binary (binding: litmus:ephemeral-guarantee)
**Setup**: Run `strings tillandsias | grep -A2 'gh-auth-login.sh'` on the compiled binary
**Signal**: Script content appears in string table
**Pass**: Bash code for gh-auth-login.sh is present in binary (not external dependency)
**Fail**: Script content missing from binary; file must be external

### test_temp_extraction_and_execution (binding: litmus:ephemeral-guarantee)
**Setup**: Instrument a test script with logging; trigger gh-auth-login execution
**Signal**: Script extracted to `$XDG_RUNTIME_DIR/tillandsias/` with mode 0700
**Pass**: Temp file created, is executable by owner only, and is passed correctly to `open_terminal()`
**Fail**: Script not extracted, wrong permissions, or file not found at expected path

### test_image_source_tree_extraction (binding: litmus:ephemeral-guarantee)
**Setup**: Call `write_image_sources()` with embedded image tree; inspect temp directory
**Signal**: Directory structure `images/default/locales/` exists with files
**Pass**: Both `en.sh` and `es.sh` present with matching content from `include_str!` declarations
**Fail**: Locales directory missing or locale files incomplete

### test_locale_files_included (binding: litmus:ephemeral-guarantee)
**Setup**: Extract image sources to temp directory; check file count and content
**Signal**: `images/default/locales/en.sh` and `images/default/locales/es.sh` are readable files
**Pass**: Files have content matching compile-time embedded strings
**Fail**: Files missing or content differs from source

### test_temp_permissions_0700 (binding: litmus:ephemeral-guarantee)
**Setup**: Create temp script via `write_image_sources()` or embedded script extraction
**Signal**: File system metadata for extracted file
**Pass**: Mode is `-rwx------` (0700); owner can read/write/execute; group/other have no permissions
**Fail**: Mode is world-readable or executable by group/other

### test_temp_cleanup_on_exit (binding: litmus:ephemeral-guarantee)
**Setup**: Extract scripts, run a command, wait for process exit
**Signal**: Temp directory contents after command completes
**Pass**: Temp files deleted or left only for session cleanup (no persistent artifacts)
**Fail**: Temp scripts still exist in `$XDG_RUNTIME_DIR` after process exits

### test_build_image_sh_execution (binding: litmus:ephemeral-guarantee)
**Setup**: Trigger image build via tray; monitor temp directory
**Signal**: `build-image.sh` is extracted, invoked, and completes
**Pass**: Build succeeds; script runs from temp directory as specified in spec
**Fail**: Build script not found, wrong permissions, or execution fails

### test_multiple_scripts_no_conflict (binding: litmus:ephemeral-guarantee)
**Setup**: Trigger both gh-auth-login and build-image concurrently (simulate simultaneous operations)
**Signal**: Both scripts in temp directory with unique names
**Pass**: No file name collisions; both execute correctly
**Fail**: Scripts overwrite each other or fail due to path conflicts

## Sources of Truth

- `cheatsheets/languages/bash.md` — Bash reference and patterns
- `cheatsheets/build/cargo.md` — Cargo reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:embedded-scripts" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
