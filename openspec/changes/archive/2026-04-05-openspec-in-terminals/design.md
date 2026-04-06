## Context
OpenSpec is installed via npm to ~/.cache/tillandsias/openspec/ (persisted across container restarts via cache mount). The install is idempotent — if the binary exists, it's a no-op.

## Goals / Non-Goals
**Goals:** OpenSpec available in all container types (forge + terminal)
**Non-Goals:** Auto-updating OpenSpec in terminal containers

## Decisions
- Move OpenSpec install logic to a shared function `install_openspec()` in lib-common.sh
- All entrypoints call it (DRY)
- Terminal entrypoint also runs `openspec init --tools terminal` if no openspec dir exists
- Use `--tools terminal` for terminal containers (no agent-specific tools)
- @trace spec:forge-shell-tools on all changes
