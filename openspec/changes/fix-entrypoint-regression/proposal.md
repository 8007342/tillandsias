## Why

Container entrypoints crash silently on launch due to `set -e` (errexit) interactions with bash function return codes. Two bugs:

1. `find_project_dir()` in `lib-common.sh` — when `$HOME/src/` is empty, the glob `*/` doesn't match. Bash substitutes the literal string, `[ -d "$dir" ]` returns exit code 1, the for-loop propagates that as the function's return code, and `set -e` terminates the entrypoint.

2. `install_opencode()` in `entrypoint-forge-opencode.sh` — `return 1` on curl failure is propagated to the top-level caller. Since `install_opencode` is called directly (not inside `if`), `set -e` kills the entire entrypoint instead of falling back to bash.

## What Changes

- `lib-common.sh`: Add `return 0` at end of `find_project_dir()` so the function never propagates a nonzero exit from the for-loop.
- `entrypoint-forge-opencode.sh`: Change `return 1` to `return 0` in `install_opencode()` so failures are non-fatal. Wrap `tar` extraction in `if` guard. Protect `chmod` with `|| true`. Clean up temp file on extraction failure. Apply same `tar`+`chmod` protection to `update_opencode()`.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `environment-runtime`: Entrypoint scripts must survive gracefully when network is offline, when `$HOME/src/` is empty, or when tool installation fails — falling back to bash instead of crashing.

## Impact

- `images/default/lib-common.sh` — fix `find_project_dir()` return code
- `images/default/entrypoint-forge-opencode.sh` — fix `install_opencode()` and `update_opencode()` error handling
