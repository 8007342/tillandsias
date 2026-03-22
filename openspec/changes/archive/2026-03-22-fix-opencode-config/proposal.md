## Why

The default container image ships an `opencode.json` that defines a custom provider and model (`opencode/big-pickle`) which does not exist in any released version of OpenCode. When the container starts, OpenCode attempts to resolve this model, fails with "agent coder not found", and exits immediately. This makes the container completely unusable on first launch.

## What Changes

- Strip the `opencode.json` config down to tool and permission declarations only, removing the non-existent provider/model reference
- Harden the entrypoint script so that if OpenCode still fails for any reason, the container falls back to an interactive bash shell with a clear diagnostic message instead of crashing

## Capabilities

### New Capabilities
<!-- None -->

### Modified Capabilities
- `default-image`: Entrypoint gracefully falls back to bash when OpenCode fails, instead of exiting

## Impact

- No new dependencies
- No Rust code changes
- Container will launch successfully with OpenCode's built-in defaults for provider/model selection
- If OpenCode fails for any reason (config error, missing binary, etc.), the user gets an interactive shell instead of a crashed container
