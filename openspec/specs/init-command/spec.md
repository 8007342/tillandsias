<!-- @trace spec:init-command -->
# init-command Specification

## Status

status: active

## Purpose
Define behavior of `tillandsias --init` command including incremental builds, debug mode, and the runtime contract that the shipped binary performs image orchestration directly from Rust without shell-script wrappers.

## Requirements

### Requirement: Init CLI command
The application MUST provide a `tillandsias --init` command that pre-builds all container images. The command MUST support `--force` to rebuild all images and `--debug` to enable verbose output with failed build log capture. The command MUST track successful builds across runs and skip already-built images on re-run. The implementation MUST be compiled Rust that invokes Podman directly; it MUST NOT depend on executing repository shell scripts as part of the shipped runtime path.

#### Scenario: First run
- **WHEN** `tillandsias --init` is run and no images exist
- **THEN** all images MUST be built in sequence (proxy, forge, git, inference, chromium-core, chromium-framework), progress MUST be shown on stdout, and the command MUST exit with code 0
- **AND** the build plan MUST be derived from Containerfiles plus Rust-side Podman command construction, not via a shell-script launcher

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

### Requirement: Init path does not invoke shell wrappers
`tillandsias --init` SHALL be implemented as a compiled Rust runtime path that talks to Podman directly. It SHALL NOT shell out to `scripts/build-image.sh` or extract temp scripts in order to perform image builds.

#### Scenario: No script middleware
- **WHEN** `tillandsias --init` starts image orchestration
- **THEN** the binary SHALL build the podman command line itself
- **AND** the image recipes SHALL come from Containerfiles and runtime assets only
- **AND** the runtime SHALL not depend on repository shell scripts

### Requirement: Init build uses host user namespace
The init build path SHALL select a Podman user namespace mode that does not depend on `newuidmap` on immutable hosts. The default build contract SHALL prefer host namespace reuse for the build container itself while preserving the normal image security contract for runtime containers.

#### Scenario: Rootless build on immutable host
- **WHEN** `tillandsias --init` runs on a host where `/run/user/<uid>` is constrained
- **THEN** image builds SHALL proceed without requiring `newuidmap` for the build container setup
- **AND** the user-facing runtime contract for launched containers SHALL remain unchanged

### Requirement: Init failure diagnostics are host-specific
When `--init` fails because rootless Podman cannot set up a namespace, the build output SHALL print a concise diagnostic that includes the current user, uid/gid, and any matching `/etc/subuid` and `/etc/subgid` entries before the final build failure message. The diagnostic SHALL distinguish overlap-safe subordinate mappings from host refusal to write the rootless uid_map.

#### Scenario: newuidmap failure
- **WHEN** `tillandsias --init` hits a `newuidmap` or uid_map failure
- **THEN** the output SHALL state that the failure is a host rootless-Podman namespace problem
- **AND** the output SHALL state that the subordinate mapping is present and overlap-safe
- **AND** the output SHALL include the current user and uid/gid
- **AND** the output SHALL include matching subuid/subgid entries if present

### Requirement: Exit code contract for init command
The `--init` command MUST exit deterministically with codes 0 (all images built successfully) or 1 (any image build failed), enabling safe use in shell pipelines and conditionals.

#### Scenario: Successful init
- **WHEN** `tillandsias --init` completes and all images built successfully
- **THEN** the command MUST exit with code 0
- **AND** MUST be safe to chain: `./build.sh --install && tillandsias --init --debug && tillandsias /path`

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
- `litmus:init-log-cleanup` — Verify init logs do not persist after a successful init run

Gating points:
- All six images build or validate (cached) before first forge launch
- Build lock prevents concurrent builds; subsequent builds wait for lock release
- Canonical image tags are content-hash based; version and latest are human-facing aliases
- Staleness detection checks the source hash; if stale, rebuilds and refreshes aliases
- Init logs written to `~/.cache/tillandsias/init-<date>-<time>.log` and cleaned up after init completes
- On init failure, error is logged but tray continues (degraded state, not fatal)
- Incremental builds cache layers; unchanged sources skip rebuild

## Sources of Truth

- `cheatsheets/build/build-lock-semantics.md` — process coordination via PID files to prevent concurrent builds
- `cheatsheets/build/container-image-tagging.md` — versioned image tag scheme and staleness detection

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:init-command" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
