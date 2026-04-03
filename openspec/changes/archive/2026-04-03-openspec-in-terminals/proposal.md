## Why
OpenSpec is a valid tool for maintenance terminals — users should be able to run `openspec status`, `openspec list`, etc. from any terminal, not just forge containers. Currently only Claude/OpenCode entrypoints install OpenSpec.

## What Changes
- Extract OpenSpec installation into a shared function in lib-common.sh
- Call it from all three entrypoints (claude, opencode, terminal)
- Run `openspec init` non-interactively in terminal entrypoint when project has no openspec dir
- Ensure OpenSpec bin is on PATH in terminal containers (already is via lib-common.sh PATH setup)

## Capabilities
### New Capabilities
_None_
### Modified Capabilities
- `forge-shell-tools`: OpenSpec now available in terminal containers, not just forge containers

## Impact
- images/default/lib-common.sh — new install_openspec() function
- images/default/entrypoint-terminal.sh — calls install_openspec + openspec init
- images/default/entrypoint-forge-claude.sh — uses shared function instead of inline
- images/default/entrypoint-forge-opencode.sh — uses shared function instead of inline
