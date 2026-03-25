## Why

When a user launches a Tillandsias environment for the first time, OpenSpec is installed inside the container but `openspec init` is never called for the project. This means OpenCode's OpenSpec commands (e.g., `/opsx:new`, `/opsx:onboard`) fail with "Run `openspec init` first". The init step is missing from the container entrypoint.

## What Changes

- Add `openspec init` call to `images/default/entrypoint.sh` after OpenSpec is installed and the project directory is set
- Only run init if the project doesn't already have an `openspec/` directory (idempotent)
- After init, the OpenSpec schema and config are ready when OpenCode launches

## Capabilities

### New Capabilities
- `openspec-auto-init`: Container entrypoint automatically initializes OpenSpec for the project directory on first launch

### Modified Capabilities

## Impact

- **Modified file**: `images/default/entrypoint.sh` — add conditional `openspec init` after install
- **No new dependencies**: `openspec` binary is already installed by the entrypoint
- **Idempotent**: Skips init if `openspec/` directory already exists in the project
- **Rebuild required**: Container image must be rebuilt (`./scripts/build-image.sh forge --force`) since entrypoint is embedded
