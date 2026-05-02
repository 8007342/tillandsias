<!-- @trace spec:init-command -->

# init-command Specification (Delta)

## Purpose

Enhanced init-command behavior: explicitly include browser isolation images (browser-core, browser-framework) in the build set, ensuring all enclave containers are built during `--init --debug`. Add verbose logging and extended timeouts for inspection.

## MODIFIED Requirements

### Requirement: Init CLI command
The application SHALL provide a `tillandsias --init` command that pre-builds **all container images** (proxy, forge, git, inference, browser-core, browser-framework). The command SHALL support `--force` to rebuild all images and `--debug` to enable verbose output, extended timeouts (no timeout kill), and complete build log capture on failure. The command SHALL track successful builds across runs and skip already-built images on re-run.

#### Scenario: First run with browser images
- **WHEN** `tillandsias --init` is run and no images exist
- **THEN** all six images are built in sequence: proxy, forge, git, inference, browser-core, browser-framework
- **AND** progress is shown on stdout (image name, status, build time)
- **AND** the command exits with code 0 on complete success

#### Scenario: Browser images part of staleness detection
- **WHEN** `tillandsias --init` is run and proxy/forge/git/inference exist but browser-core was not previously built
- **THEN** proxy/forge/git/inference are skipped (verified via podman image exists and hash match)
- **AND** browser-core and browser-framework are built
- **AND** the command exits with code 0

#### Scenario: Images already exist (staleness)
- **WHEN** `tillandsias --init` is run and all six images already exist with unchanged sources
- **THEN** the command prints "All images up to date (6/6)" and exits immediately

#### Scenario: Partial failure with state tracking
- **WHEN** `tillandsias --init` is run, previous run built proxy/forge/git/inference successfully but browser-core failed
- **THEN** proxy/forge/git/inference are skipped (verified via staleness)
- **AND** browser-core is rebuilt
- **AND** browser-framework proceeds if browser-core succeeds

#### Scenario: Build in progress
- **WHEN** `tillandsias --init` is run and another init process is already building
- **THEN** the command waits for the existing build to complete instead of starting a duplicate

#### Scenario: Debug mode with extended timeouts
- **WHEN** `tillandsias --init --debug` is run
- **THEN** timeout limits are disabled (no kill after N minutes) allowing container inspection
- **AND** build logs for each image are streamed to stderr in real-time
- **AND** after completion, each image's final status is printed with build duration

#### Scenario: Debug mode with failed builds
- **WHEN** `tillandsias --init --debug` completes and some images failed to build
- **THEN** the last 20 lines of each failed build's log file are displayed after all images are processed
- **AND** the cause (e.g., "Containerfile not found", "podman build exited 1") is clearly stated

#### Scenario: Debug mode with verbose container inspection
- **WHEN** `tillandsias --init --debug` is building browser-core image
- **THEN** user can open another terminal and run `podman logs -f tillandsias-build-browser-core` to watch the build in real-time
- **AND** the build does not timeout if monitoring takes extended time

#### Scenario: Help text
- **WHEN** `tillandsias --help` is run
- **THEN** the output includes:
  ```
  --init                Pre-build container images (proxy, forge, git, inference, browser-core, browser-framework)
  --debug               Enable verbose logging, extended timeouts, and detailed error reporting (use with --init)
  ```

## Sources of Truth

- `docs/cheatsheets/container-lifecycle.md` — container build state transitions, staleness detection
- `docs/cheatsheets/podman-logging.md` — real-time log inspection during builds
