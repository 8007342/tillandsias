## Why

Four UX gaps need fixing before v0.1: (1) "Attach Here" menu items have no visual state — you can't tell if an environment is idle or active without scanning the running list. (2) GitHub auth from the tray launches a terminal but the interactive flow doesn't work properly, blocking first-time setup. (3) CLI mode has no `--bash` flag for dropping into a troubleshooting shell. (4) A leftover `/gh-auth-login` skill file from an abandoned approach sits in the forge image.

## What Changes

- **Attach Here emoji lifecycle**: Add 🌱 (baby/idle) prefix to every "Attach Here" item. When a container is running for that project, upgrade to 🌺 (mature/bloom). Revert to 🌱 when the container stops.
- **`gh-auth-login.sh` script**: New standalone script that runs `gh auth login` and git identity setup inside a forge container with proper interactive terminal handling. Replaces the broken tray-based flow.
- **`--bash` CLI flag**: `tillandsias ../project/ --bash` drops into a plain bash shell inside the container instead of the default entrypoint, for troubleshooting.
- **Remove leftover skill**: Delete `images/default/skills/command/gh-auth-login.md`.
- **Fix tray GitHub Login handler**: Point it at the new `gh-auth-login.sh` script instead of the inline bash approach.

## Capabilities

### New Capabilities
- `gh-auth-script`: Standalone `gh-auth-login.sh` for interactive GitHub authentication via forge container
- `cli-bash-mode`: `--bash` flag for CLI attach mode that drops into a plain shell

### Modified Capabilities
- `tray-app`: Attach Here items get lifecycle emoji prefixes; GitHub Login handler delegates to `gh-auth-login.sh`

## Impact

- **New files**: `gh-auth-login.sh`
- **Modified files**: `src-tauri/src/menu.rs` (emoji prefixes), `src-tauri/src/cli.rs` (--bash flag), `src-tauri/src/runner.rs` (bash entrypoint), `src-tauri/src/handlers.rs` (delegate to script)
- **Deleted files**: `images/default/skills/command/gh-auth-login.md`
