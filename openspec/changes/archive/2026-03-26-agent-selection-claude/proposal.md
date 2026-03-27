## Why

Tillandsias currently hardcodes OpenCode as the sole AI coding agent launched in forge containers. Some users prefer Claude Code. Rather than forcing a single tool, the tray should let the user choose which agent starts when they click "Attach Here". The selection must persist across restarts and be passed into containers so the entrypoint launches the correct agent.

## What Changes

- **Seedlings submenu** in Settings lets the user toggle between OpenCode and Claude Code
- **Agent config** stored in `~/.config/tillandsias/config.toml` under `[agent]`
- **New MenuCommand** `SelectAgent` triggers config write + menu rebuild
- **Entrypoint branching** in `images/default/entrypoint.sh` reads `TILLANDSIAS_AGENT` env var to decide which agent to install and exec
- **Container env var** `TILLANDSIAS_AGENT` passed in all podman run invocations (handle_attach_here, handle_terminal, handle_root_terminal)
- **Claude credentials mount** `~/.cache/tillandsias/secrets/claude/` mounted as `/home/forge/.claude:rw` for auth persistence
- **Cross-agent isolation** OpenCode's deny list updated to block Claude paths; both agents are restricted from reading each other's credentials

## Capabilities

### New Capabilities
- `agent-selection-claude`: Users can select between OpenCode and Claude Code from the tray menu; selection persists and is applied to all new containers

### Modified Capabilities
- `settings-submenu`: Gains a "Seedlings" child submenu between GitHub and version/credit sections
- `entrypoint`: Branches on `TILLANDSIAS_AGENT` to install and launch either OpenCode or Claude Code
- `container-launch`: Passes `TILLANDSIAS_AGENT` env var and mounts Claude secrets directory

## Impact

- **New files**: None (all changes are to existing files)
- **Modified files**:
  - `crates/tillandsias-core/src/config.rs` — `AgentConfig`, `SelectedAgent` enum, serde support
  - `crates/tillandsias-core/src/event.rs` — `MenuCommand::SelectAgent` variant
  - `src-tauri/src/menu.rs` — Seedlings submenu builder, `select_agent()` ID helper
  - `src-tauri/src/main.rs` — dispatch `select-agent:*` menu clicks
  - `src-tauri/src/event_loop.rs` — handle `SelectAgent` command
  - `src-tauri/src/handlers.rs` — pass `TILLANDSIAS_AGENT` env var, mount Claude secrets
  - `images/default/entrypoint.sh` — Claude Code install + launch branch
  - `images/default/opencode.json` — deny Claude credential paths
