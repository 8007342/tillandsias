<!-- @trace spec:init-incremental-builds -->
# init-incremental-builds Specification

## Status

status: active

## Purpose
Track and resume partial `tillandsias --init` builds, with debug logging for failed images.

## Requirements

### Requirement: Incremental build state tracking
The init command MUST maintain a state file at `$HOME/.cache/tillandsias/init-build-state.json` tracking which images were successfully built.

#### Scenario: First run with no state file
- **WHEN** `tillandsias --init` is run and no state file exists
- **THEN** all images MUST be built in sequence (proxy, forge, git, inference, chromium-core, chromium-framework)

#### Scenario: Re-run after partial failure
- **WHEN** `tillandsias --init` is run and the state file shows proxy=success, forge=failed
- **THEN** proxy MUST be skipped (image exists check), forge MUST be rebuilt, git, inference, chromium-core, chromium-framework MUST proceed normally

#### Scenario: Image deleted after successful build
- **WHEN** `tillandsias --init` is run, state shows forge=success, but `podman image exists tillandsias-forge:vX.Y.Z` returns false
- **THEN** forge MUST be rebuilt despite state showing success

### Requirement: Debug flag for init command
The init command MUST accept a `--debug` flag that enables verbose output and failed build log capture.

#### Scenario: Init with debug flag
- **WHEN** `tillandsias --init --debug` is run
- **THEN** build output MUST be shown on terminal AND captured to `/tmp/tillandsias-init-<image>.log` for each image

#### Scenario: Init without debug flag
- **WHEN** `tillandsias --init` is run without `--debug`
- **THEN** no debug logs MUST be captured and no log files MUST be created

### Requirement: Failed build log display
After all images are processed, if `--debug` was used and any builds failed, the init command MUST display the last 10 lines of each failed build's log file.

#### Scenario: Failed builds with debug mode
- **WHEN** `tillandsias --init --debug` completes and forge + inference builds failed
- **THEN** the output MUST include `tail -10 /tmp/tillandsias-init-forge.log` and `tail -10 /tmp/tillandsias-init-inference.log` content

#### Scenario: All builds successful
- **WHEN** `tillandsias --init --debug` completes with all images built successfully
- **THEN** no failed build logs MUST be displayed

#### Scenario: No debug mode
- **WHEN** `tillandsias --init` (without `--debug`) completes with failures
- **THEN** no failed build logs MUST be displayed (user should re-run with `--debug`)

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:init-log-cleanup` — Verify init logs are collected, displayed on failure, and cleaned up on success

Gating points:
- On first init, all images build (cold start)
- Subsequent init with unchanged Containerfile/flake.nix uses cached layers; rebuilds skip unchanged stages
- Source file staleness tracked via hash; if source.hash == cached.hash, layer rebuild skipped
- Init success (all images built/cached) removes temp logs; user never sees log files
- Init failure logs are displayed inline (with `--debug`, full output; without `--debug`, error summary only)
- Build errors are non-fatal to tray startup; tray shows degraded status until user fixes and re-runs init

## Sources of Truth

- `cheatsheets/build/cargo.md` — Cargo reference and patterns
- `cheatsheets/build/nix-flake-basics.md` — Nix Flake Basics reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:init-incremental-builds" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
