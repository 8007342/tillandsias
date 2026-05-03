<!-- @trace spec:init-command -->
# init-command Specification

## Status

status: active

## Purpose
Define behavior of `tillandsias --init` command including incremental builds and debug mode.

## Requirements

### Requirement: Init CLI command
The application MUST provide a `tillandsias --init` command that pre-builds all container images. The command MUST support `--force` to rebuild all images and `--debug` to enable verbose output with failed build log capture. The command MUST track successful builds across runs and skip already-built images on re-run.

#### Scenario: First run
- **WHEN** `tillandsias --init` is run and no images exist
- **THEN** all images MUST be built in sequence (proxy, forge, git, inference, chromium-core, chromium-framework), progress MUST be shown on stdout, and the command MUST exit with code 0

#### Scenario: Images already exist (staleness)
- **WHEN** `tillandsias --init` is run and all images already exist and sources unchanged
- **THEN** the command MUST print "Images up to date" and exit immediately

#### Scenario: Partial failure with state tracking
- **WHEN** `tillandsias --init` is run, previous run built proxy successfully but forge failed
- **THEN** proxy MUST be skipped (verified via podman image exists), forge MUST be rebuilt, and remaining images MUST proceed

#### Scenario: Build in progress
- **WHEN** `tillandsias --init` is run and another init process is already building
- **THEN** the command MUST wait for the existing build to complete instead of starting a duplicate

#### Scenario: Debug mode with failed builds
- **WHEN** `tillandsias --init --debug` completes and some images failed to build
- **THEN** the last 10 lines of each failed build's log file MUST be displayed after all images are processed

#### Scenario: Help text
- **WHEN** `tillandsias --help` is run
- **THEN** the `--init` flag MUST be listed with description "Pre-build container images" and `--debug` flag MUST be shown as available option

### Requirement: Exit code contract for init command
The `--init` command MUST exit deterministically with codes 0 (all images built successfully) or 1 (any image build failed), enabling safe use in shell pipelines and conditionals.

#### Scenario: Successful init
- **WHEN** `tillandsias --init` completes and all images built successfully
- **THEN** the command MUST exit with code 0
- **AND** MUST be safe to chain: `./build.sh --install && tillandsias --init --debug && tillandsias /path --diagnostics`

#### Scenario: Partial failure exits with code 1
- **WHEN** `tillandsias --init` completes and one or more images failed to build
- **THEN** the command MUST exit with code 1
- **AND** each failure MUST be visible in terminal output
- **AND** MUST be chainable with error handling: `tillandsias --init || echo "init failed"`

### Requirement: Debug mode log capture
When `--debug` flag is passed, init MUST capture each image build's output to `/tmp/tillandsias-init-{image}.log` and display failed logs on stderr.

#### Scenario: Debug mode tees output
- **WHEN** `tillandsias --init --debug` is run
- **THEN** each image build MUST be piped to `tee /tmp/tillandsias-init-{image_name}.log`
- **AND** user MUST see progress in real-time on stdout
- **AND** logs MUST be preserved for post-mortem analysis

#### Scenario: Failed logs displayed inline
- **WHEN** `tillandsias --init --debug` completes with failures
- **THEN** the last 10 lines of each failed build's log MUST be displayed to stderr
- **AND** log lines MUST be prefixed with image name for clarity

### Requirement: All images built
The init command MUST build exactly six container images in sequence.

#### Scenario: Image build sequence
- **WHEN** `tillandsias --init` is run
- **THEN** the following images MUST be built in this order:
  1. `proxy` — caching HTTP/S proxy with domain allowlist
  2. `forge` — main dev environment
  3. `git` — mirror service with push support
  4. `inference` — ollama for local models
  5. `chromium-core` — browser isolation core (Linux)
  6. `chromium-framework` — browser isolation framework (Linux)

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:init-log-cleanup` — Verify init logs are cleaned up and do not persist after tray restarts

Gating points:
- All six images build or validate (cached) before first forge launch
- Build lock prevents concurrent builds; subsequent builds wait for lock release
- Image tags include version number from VERSION file (e.g., tillandsias-forge:v0.1.37.25)
- Staleness detection checks if image was built before current app version; if stale, rebuilds
- Init logs written to `~/.cache/tillandsias/init-<date>-<time>.log` and cleaned up after init completes
- On init failure, error is logged but tray continues (degraded state, not fatal)
- Incremental builds cache layers; unchanged sources skip rebuild

## Sources of Truth

- `docs/cheatsheets/build-lock-semantics.md` — process coordination via PID files to prevent concurrent builds
- `docs/cheatsheets/container-image-tagging.md` — versioned image tag scheme and staleness detection

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:init-command" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
