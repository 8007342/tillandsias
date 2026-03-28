## Why

Claude Code authenticates via an Anthropic API key (`ANTHROPIC_API_KEY`). Today, users who select Claude as their agent must manually export this environment variable or rely on Claude's own interactive login flow each time a container starts. There is no persistent, secure storage for the API key in Tillandsias — unlike the GitHub token which lives in the OS keyring.

Without keyring integration, the API key either lives in plaintext on disk, gets lost between container restarts, or requires repeated manual entry. This friction makes Claude Code a second-class citizen compared to the GitHub auth flow.

## What Changes

- **Keyring storage** for Claude API key in `secrets.rs` — `store_claude_api_key()` / `retrieve_claude_api_key()` mirroring the GitHub token pattern, under `tillandsias/claude-api-key`
- **"Claude Login" menu item** in the Seedlings submenu — shows key status (locked/unlocked icon) and triggers an interactive prompt when clicked
- **New `MenuCommand::ClaudeLogin`** variant in the event enum for dispatching the menu action
- **Claude Login handler** — opens a terminal running an embedded prompt script, reads the key from a temp file, stores in keyring
- **API key injection** into containers via `-e ANTHROPIC_API_KEY=<key>` in `build_run_args()`, `handle_terminal()`, and `handle_root_terminal()`
- **Entrypoint key scrubbing** — captures the env var, unsets it globally, re-injects only into the claude process to limit exposure
- **OpenCode deny list** — adds `/proc/*/environ` to `opencode.json` to prevent AI agents from reading other processes' environment variables

## Capabilities

### New Capabilities
- `claude-api-key-login`: Secure storage and injection of Anthropic API keys via OS keyring, with tray menu login flow and per-process key isolation in containers

### Modified Capabilities
- `native-secrets-store`: Gains a second keyring entry (`claude-api-key`) alongside the existing `github-oauth-token`
- `tray-app`: Seedlings submenu gains a Claude Login item with authentication state indicator
- `default-image`: Entrypoint scrubs `ANTHROPIC_API_KEY` from the global environment and re-injects only for the claude process

## Impact

- **New files**: `claude-api-key-prompt.sh` (embedded script for interactive key entry)
- **Modified files**:
  - `src-tauri/src/secrets.rs` — `store_claude_api_key()`, `retrieve_claude_api_key()`
  - `crates/tillandsias-core/src/event.rs` — `MenuCommand::ClaudeLogin`
  - `src-tauri/src/menu.rs` — Claude Login item in Seedlings submenu, `CLAUDE_LOGIN` ID constant
  - `src-tauri/src/main.rs` — dispatch `claude-login` menu clicks
  - `src-tauri/src/event_loop.rs` — handle `ClaudeLogin` command
  - `src-tauri/src/handlers.rs` — inject `ANTHROPIC_API_KEY` env var in all container launch paths
  - `src-tauri/src/runner.rs` — inject `ANTHROPIC_API_KEY` in CLI mode
  - `src-tauri/src/embedded.rs` — embed `claude-api-key-prompt.sh`
  - `images/default/entrypoint.sh` — capture, unset, re-inject API key per-process
  - `images/default/opencode.json` — deny `/proc/*/environ`
