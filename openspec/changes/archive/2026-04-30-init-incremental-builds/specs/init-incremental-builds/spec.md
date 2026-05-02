# init-incremental-builds Specification

## Purpose
Track and resume partial `tillandsias --init` builds, with debug logging for failed images.

## ADDED Requirements

### Requirement: Incremental build state tracking
The init command SHALL maintain a state file at `$HOME/.cache/tillandsias/init-build-state.json` tracking which images were successfully built.

#### Scenario: First run with no state file
- **WHEN** `tillandsias --init` is run and no state file exists
- **THEN** all images are built in sequence (proxy, forge, git, inference)

#### Scenario: Re-run after partial failure
- **WHEN** `tillandsias --init` is run and the state file shows proxy=success, forge=failed
- **THEN** proxy is skipped (image exists check), forge is rebuilt, git and inference proceed normally

#### Scenario: Image deleted after successful build
- **WHEN** `tillandsias --init` is run, state shows forge=success, but `podman image exists tillandsias-forge:vX.Y.Z` returns false
- **THEN** forge is rebuilt despite state showing success

### Requirement: Debug flag for init command
The init command SHALL accept a `--debug` flag that enables verbose output and failed build log capture.

#### Scenario: Init with debug flag
- **WHEN** `tillandsias --init --debug` is run
- **THEN** build output is shown on terminal AND captured to `/tmp/tillandsias-init-<image>.log` for each image

#### Scenario: Init without debug flag
- **WHEN** `tillandsias --init` is run without `--debug`
- **THEN** no debug logs are captured and no log files are created

### Requirement: Failed build log display
After all images are processed, if `--debug` was used and any builds failed, the init command SHALL display the last 10 lines of each failed build's log file.

#### Scenario: Failed builds with debug mode
- **WHEN** `tillandsias --init --debug` completes and forge + inference builds failed
- **THEN** the output includes `tail -10 /tmp/tillandsias-init-forge.log` and `tail -10 /tmp/tillandsias-init-inference.log` content

#### Scenario: All builds successful
- **WHEN** `tillandsias --init --debug` completes with all images built successfully
- **THEN** no failed build logs are displayed

#### Scenario: No debug mode
- **WHEN** `tillandsias --init` (without `--debug`) completes with failures
- **THEN** no failed build logs are displayed (user should re-run with `--debug`)
