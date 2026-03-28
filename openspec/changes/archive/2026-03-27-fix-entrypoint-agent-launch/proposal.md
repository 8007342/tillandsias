# Proposal: fix-entrypoint-agent-launch

## Context

The default agent was recently switched from opencode to claude in both the
Rust config (`SelectedAgent::default() -> Claude`) and the entrypoint script
(`AGENT="${TILLANDSIAS_AGENT:-claude}"`). However, the entrypoint still
unconditionally defines opencode paths and the tar extraction creates a
doubled `opencode/opencode` path that fails to execute.

## Root Cause

1. `OC_BIN="$CACHE/opencode/opencode"` is defined at the top of the script
   regardless of agent selection
2. The opencode tarball extracts to `$CACHE/opencode/` but the binary inside
   may already be in a subdirectory, creating a doubled path
3. The `case` statement's wildcard `*)` branch tries to exec `$OC_BIN` for
   any non-claude agent, but this path may not be valid

## Changes

### `images/default/entrypoint.sh`

- Move `OC_BIN` definition into `install_opencode()` function scope
- Fix the opencode binary path: extract to `$CACHE` and reference as
  `$CACHE/opencode` (single level) or extract with `--strip-components=1`
- Make the `case` statement explicit: `claude)` and `opencode)` branches,
  with `*)` falling back to bash with an error message
- Remove unconditional `mkdir` for opencode directories

## Scope

Single file change: `images/default/entrypoint.sh`. No Rust code changes
needed -- the `config.rs` SelectedAgent enum and default are already correct.
