## Why

Tillandsias currently has a minimal CLI interface: a static `USAGE` string in `cli.rs` with a flat list of flags. As the application gains accountability windows (`--log-secret-management`, `--log-image-management`, `--log-update-cycle`), per-module log control (`--log=...`), and maintenance commands (`init`, `--stats`, `--clean`, `--update`), the help text needs structure. A flat list of 15+ flags is unreadable.

Additionally, when a user runs `tillandsias` from a terminal (CLI attach mode), there is no welcome output -- the app silently launches a container or starts the tray. A brief welcome banner showing the version, detected OS, podman status, and forge image readiness would help users confirm their setup is healthy before diving in.

## What Changes

- **Welcome banner**: When run from a terminal in CLI attach mode, print a brief system status banner before launching the container. Suppressed in tray mode (no terminal) and when stdout is not a TTY (piped output).
- **Sectioned `--help` output**: Reorganize the help text into semantic sections: USAGE, ACCOUNTABILITY, OPTIONS, MAINTENANCE, HELP. Each section groups related flags with descriptions.
- **Version in banner**: The 4-part version from `VERSION` is shown in the welcome banner (not just the 3-part semver).

## Capabilities

### New Capabilities
- `cli-ux`: Welcome banner and sectioned help output

### Modified Capabilities
- `cli-mode`: Help text restructured, version display enhanced

## Impact

- **Modified files**: `src-tauri/src/cli.rs` (help text, welcome banner), `src-tauri/src/runner.rs` (print banner before container launch), `src-tauri/src/main.rs` (version detection for banner)
- **New files**: None
- **User-visible change**: New welcome banner on CLI launch, reorganized `--help` output
- **Dependency on**: `logging-accountability-framework` (for the `--log=` and `--log-*` flags to appear in help). Can be implemented independently with placeholder flag descriptions.
