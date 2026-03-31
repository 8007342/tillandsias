## Why

The Claude API key authentication flow is a legacy artifact from before OAuth via `~/.claude/` was implemented. It adds complexity (keyring storage, embedded prompt script, polling loop, env var injection) for a path that most users don't need — Max/Pro subscribers authenticate via `claude login` on the host, and the resulting `~/.claude/` directory is already mounted into containers. The API key flow also exposes `ANTHROPIC_API_KEY` in the process environment, which is less secure than OAuth tokens managed by Claude Code itself.

Additionally, the maintenance terminal (Ground/Terminal) shows the welcome banner twice — once from `entrypoint-terminal.sh` and again from `config.fish` — because the entrypoint doesn't set the guard variable that `config.fish` checks.

## What Changes

### Remove API key authentication

- Delete `claude-api-key-prompt.sh` (embedded prompt script)
- Remove `SecretKind::ClaudeApiKey` from container profiles and launch arg building
- Remove `store_claude_api_key()` / `retrieve_claude_api_key()` from secrets.rs
- Remove `claude_api_key` field from `LaunchContext`
- Remove `handle_claude_login()` handler and `ClaudeLogin` menu command
- Remove API key capture/scrub logic from `entrypoint-forge-claude.sh`

### Replace with credential reset

- Add "Claude Reset Credentials" menu item in Seedlings submenu (lock icon, only visible when `~/.claude/` exists on host)
- Clicking removes `~/.claude/` contents so next launch triggers re-authentication
- Add `ClaudeResetCredentials` menu command and handler

### Fix double welcome

- Export `TILLANDSIAS_WELCOME_SHOWN=1` in `entrypoint-terminal.sh` before `exec fish`

## Capabilities

### New Capabilities

- `claude-reset-credentials`: Menu item to clear Claude OAuth credentials, triggering re-authentication on next launch

### Modified Capabilities

- `claude-auth`: OAuth-only authentication via `~/.claude/` mount (API key path removed)
- `terminal-welcome`: Welcome banner shown exactly once

## Impact

- `src-tauri/src/secrets.rs` — remove Claude API key keyring functions
- `src-tauri/src/handlers.rs` — remove `handle_claude_login()`, add `handle_claude_reset_credentials()`
- `src-tauri/src/menu.rs` — replace Claude Login item with Reset Credentials
- `src-tauri/src/launch.rs` — remove `ClaudeApiKey` secret handling
- `src-tauri/src/event_loop.rs` — remove `ClaudeLogin` command, add `ClaudeResetCredentials`
- `crates/tillandsias-core/src/event.rs` — replace `ClaudeLogin` with `ClaudeResetCredentials`
- `crates/tillandsias-core/src/container_profile.rs` — remove `SecretKind::ClaudeApiKey`, `claude_api_key` from `LaunchContext`
- `images/default/entrypoint-forge-claude.sh` — remove API key capture/scrub
- `images/default/entrypoint-terminal.sh` — add welcome guard export
- `claude-api-key-prompt.sh` — delete
- `locales/en.toml`, `locales/es.toml` — update menu strings
