## Architecture

### Data Flow

```
Tray Menu Click (select-agent:claude)
  -> handle_menu_click() dispatches MenuCommand::SelectAgent { agent: "claude" }
  -> event_loop matches SelectAgent
    -> save_selected_agent() writes to ~/.config/tillandsias/config.toml
    -> on_state_change() triggers menu rebuild
    -> build_seedlings_submenu() reads config, shows pin on new selection
```

```
Attach Here Click
  -> handle_attach_here() reads global_config.agent.selected
  -> build_run_args() includes -e TILLANDSIAS_AGENT=<agent>
  -> Container starts with entrypoint.sh
  -> entrypoint.sh reads TILLANDSIAS_AGENT env var
  -> case branch installs + execs selected agent
```

### Config Schema

```toml
# ~/.config/tillandsias/config.toml
[agent]
selected = "opencode"  # or "claude"
```

The `[agent]` section is optional. When absent, `SelectedAgent::default()` returns `OpenCode`.

### Menu Structure

```
Settings >
  ├── GitHub >
  │   ├── GitHub Login
  │   └── Remote Projects >
  ├── ─────────
  ├── Seedlings >
  │   ├── OpenCode (Default)    <- pin emoji when selected
  │   └── Claude                <- pin emoji when selected
  ├── ─────────
  ├── Tillandsias v0.1.x
  └── by Tlatoani
```

### Volume Mounts (Claude)

```
~/.cache/tillandsias/secrets/claude/ -> /home/forge/.claude:rw
```

This directory persists Claude Code's OAuth tokens and configuration across container restarts, identical to how `~/.cache/tillandsias/secrets/gh/` persists GitHub CLI credentials.

### Credential Isolation

OpenCode's `opencode.json` deny list prevents it from reading Claude's credential directory. The isolation is one-directional for now (OpenCode denied Claude paths). Claude Code's own permission system is managed by Anthropic and configured separately by the user.

### Entrypoint Branching

The entrypoint always installs OpenCode (needed for OpenSpec tooling regardless of agent choice). When `TILLANDSIAS_AGENT=claude`, it additionally installs Claude Code via npm and execs it instead of OpenCode.

Claude Code is installed to `$CACHE/claude/` using `npm install -g --prefix` so it persists across container restarts via the cache bind mount.
