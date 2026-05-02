## 1. CLI Modifications

- [x] 1.1 Add `debug: bool` field to `CliMode::Init` variant in `src-tauri/src/cli.rs:147`
- [x] 1.2 Update `parse()` function in `cli.rs:260-263` to capture `--debug` flag and pass to `CliMode::Init`
- [x] 1.3 Add `@trace spec:init-incremental-builds` annotation near the Init mode parsing code

## 2. State File Management

- [x] 2.1 Define `InitBuildState` and `ImageBuildStatus` structs with serde derives in `init.rs`
- [x] 2.2 Implement `load_build_state()` function to read `$HOME/.cache/tillandsias/init-build-state.json`
- [x] 2.3 Implement `save_build_state()` function with atomic write (temp file + rename)
- [x] 2.4 Implement `update_image_status()` helper to update single image status in state
- [x] 2.5 Add `@trace spec:init-incremental-builds` annotations to state management functions

## 3. Incremental Build Logic

- [x] 3.1 Modify `run_with_force()` in `init.rs:26` to accept `debug: bool` parameter
- [x] 3.2 Load build state at start of `run_with_force()`, pass to build loop
- [x] 3.3 Before building each image, check state file: if success AND `podman image exists`, skip
- [x] 3.4 After each image build, update state file with success/failure (even on failure)
- [x] 3.5 In `run_with_force()`, collect failed builds with log paths when debug=true
- [x] 3.6 At end of `run_with_force()`, display `tail -10` of failed build logs if debug=true
- [x] 3.7 Add `@trace spec:init-incremental-builds` annotations to build loop logic

## 4. Debug Mode Log Capture

- [x] 4.1 In debug mode, construct command with `tee` to capture output: `script 2>&1 | tee /tmp/tillandsias-init-<image>.log`
- [x] 4.2 Store log file path in `ImageBuildStatus` when debug=true
- [x] 4.3 Handle both Unix and Windows paths for log files
- [x] 4.4 Add `@trace spec:init-incremental-builds` annotations to debug log capture code

## 5. Cheatsheet Documentation

- [x] 5.1 Create `docs/cheatsheets/init-incremental-builds.md` with provenance header
- [x] 5.2 Document state file location and format (JSON structure)
- [x] 5.3 Document `--debug` flag behavior and log file locations
- [x] 5.4 Add troubleshooting section: how to reset state, where logs are stored
- [x] 5.5 Add `@trace spec:init-incremental-builds` annotation in cheatsheet

## 6. Update Existing Spec

- [x] 6.1 Sync delta spec from `openspec/changes/init-incremental-builds/specs/init-command/spec.md` to `openspec/specs/init-command/spec.md`
