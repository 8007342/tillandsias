## Why

The CLI has no `--version` flag, making it impossible to check the installed version from the command line. Additionally, `init` is the only subcommand-style argument — all others use `--flag` style (`--update`, `--stats`, `--clean`). This inconsistency is confusing.

## What Changes

- Add `--version` flag to `cli.rs` that prints `CARGO_PKG_VERSION` and exits
- Change `init` subcommand to `--init` flag for consistency with `--update`, `--stats`, `--clean`
- Update USAGE string and all references to `tillandsias init`

## Capabilities

### New Capabilities

- `--version`: Print current version and exit

### Modified Capabilities

- `init` → `--init`: Same behavior, consistent flag syntax

## Impact

- `src-tauri/src/cli.rs` — add Version variant, change Init parsing, update USAGE
- `src-tauri/src/main.rs` — handle Version mode
- `CLAUDE.md` — update CLI reference from `init` to `--init`
- `scripts/install.sh` — update any `tillandsias init` invocations
