<!-- @trace spec:init-command -->
# init-command Specification

## Status

status: active

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

### Requirement: Exit code contract for init command
The `--init` command SHALL exit deterministically with codes 0 (all images built successfully) or 1 (any image build failed), enabling safe use in shell pipelines and conditionals.

#### Scenario: Successful init
- **WHEN** `tillandsias --init` completes and all images built successfully
- **THEN** the command exits with code 0
- **AND** safe to chain: `./build.sh --install && tillandsias --init --debug && tillandsias /path --diagnostics`

#### Scenario: Partial failure exits with code 1
- **WHEN** `tillandsias --init` completes and one or more images failed to build
- **THEN** the command exits with code 1
- **AND** each failure is visible in terminal output
- **AND** can chain with error handling: `tillandsias --init || echo "init failed"`

### Requirement: Debug mode log capture
When `--debug` flag is passed, init SHALL capture each image build's output to `/tmp/tillandsias-init-{image}.log` and display failed logs on stderr.

#### Scenario: Debug mode tees output
- **WHEN** `tillandsias --init --debug` is run
- **THEN** each image build is piped to `tee /tmp/tillandsias-init-{image_name}.log`
- **AND** user sees progress in real-time on stdout
- **AND** logs are preserved for post-mortem analysis

#### Scenario: Failed logs displayed inline
- **WHEN** `tillandsias --init --debug` completes with failures
- **THEN** the last 10 lines of each failed build's log are displayed to stderr
- **AND** log lines are prefixed with image name for clarity

### Requirement: All images built
The init command SHALL build exactly six container images in sequence.

#### Scenario: Image build sequence
- **WHEN** `tillandsias --init` is run
- **THEN** the following images are built in this order:
  1. `proxy` — caching HTTP/S proxy with domain allowlist
  2. `forge` — main dev environment
  3. `git` — mirror service with push support
  4. `inference` — ollama for local models
  5. `chromium-core` — browser isolation core (Linux)
  6. `chromium-framework` — browser isolation framework (Linux)

## Sources of Truth

- `docs/cheatsheets/build-lock-semantics.md` — process coordination via PID files to prevent concurrent builds
- `docs/cheatsheets/container-image-tagging.md` — versioned image tag scheme and staleness detection

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:init-command" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
