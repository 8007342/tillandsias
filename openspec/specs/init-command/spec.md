# init-command Specification

## Purpose
Define behavior of `tillandsias --init` command including incremental builds and debug mode.

## Requirements

### Requirement: Init CLI command
The application SHALL provide a `tillandsias --init` command that pre-builds all container images. The command SHALL support `--force` to rebuild all images and `--debug` to enable verbose output with failed build log capture. The command SHALL track successful builds across runs and skip already-built images on re-run.

#### Scenario: First run
- **WHEN** `tillandsias --init` is run and no images exist
- **THEN** all images are built in sequence (proxy, forge, git, inference, chromium-core, chromium-framework), progress is shown on stdout, and the command exits with code 0

#### Scenario: Images already exist (staleness)
- **WHEN** `tillandsias --init` is run and all images already exist and sources unchanged
- **THEN** the command prints "Images up to date" and exits immediately

#### Scenario: Partial failure with state tracking
- **WHEN** `tillandsias --init` is run, previous run built proxy successfully but forge failed
- **THEN** proxy is skipped (verified via podman image exists), forge is rebuilt, and remaining images proceed

#### Scenario: Build in progress
- **WHEN** `tillandsias --init` is run and another init process is already building
- **THEN** the command waits for the existing build to complete instead of starting a duplicate

#### Scenario: Debug mode with failed builds
- **WHEN** `tillandsias --init --debug` completes and some images failed to build
- **THEN** the last 10 lines of each failed build's log file are displayed after all images are processed

#### Scenario: Help text
- **WHEN** `tillandsias --help` is run
- **THEN** the `--init` flag is listed with description "Pre-build container images" and `--debug` flag is shown as available option
