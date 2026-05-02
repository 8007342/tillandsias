## Why

The `tillandsias --init` command rebuilds all images from scratch on failure, wasting time when only one image fails. Users need incremental progress saving so failed builds can be retried without rebuilding successful images. Debug mode should also show failed build logs for troubleshooting.

## What Changes

- Add `--debug` flag support to `CliMode::Init` to enable verbose output during init
- Save partial progress by recording successful image builds to a state file
- On re-run, skip images that succeeded (only rebuild failed/pending)
- At end of `--init --debug` run, display `tail -10` of failed build logs
- Add `@trace spec:init-incremental-builds` annotations to implementation
- Create cheatsheet documenting incremental build behavior with provenance

## Capabilities

### New Capabilities
- `init-incremental-builds`: Track and resume partial init builds, with debug logging for failed images

### Modified Capabilities
- `init-command`: Updated to support `--debug` flag and incremental rebuild behavior

## Impact

- `src-tauri/src/cli.rs`: Add `debug` field to `CliMode::Init`
- `src-tauri/src/init.rs`: Implement incremental build logic, progress saving, and failed log display
- `scripts/build-image.sh`: Potentially add debug output capture
- `openspec/specs/init-command/spec.md`: Update to reflect new debug and incremental behavior
- `docs/cheatsheets/`: New or updated cheatsheet for incremental builds
