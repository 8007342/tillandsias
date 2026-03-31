## Why

When debugging issues from logs alone, there is no way to tell which version of Tillandsias or which forge image tag is running. Version information is critical for triage: knowing "this was v0.1.89" vs "v0.1.88" immediately narrows the regression window.

## What Changes

- **Entrypoint banner** — Display the forge version (from `TILLANDSIAS_FORGE_VERSION` env var) in the startup banner inside the forge container
- **Welcome message** — Include forge version in the colorful welcome display shown on interactive shell startup
- **App startup log** — Add `CARGO_PKG_VERSION` to the first log line so tray-mode logs identify the app version
- **Container launch log** — Log the forge image tag when launching an environment (tray Attach Here)
- **CLI mode** — Add version to the "Attaching to" message

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `tray-app`: Startup log includes app version
- `environment-runtime`: Forge banner and welcome message display forge version
- `cli-mode`: Attach message includes app version

## Impact

- **New env var**: `TILLANDSIAS_FORGE_VERSION` passed to all containers
- **Modified files**: `entrypoint.sh`, `forge-welcome.sh`, `main.rs`, `handlers.rs`, `runner.rs`
