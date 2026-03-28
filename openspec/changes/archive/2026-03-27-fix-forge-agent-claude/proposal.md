## Why

Three bugs make the forge environment broken or unusable for Claude Code users:

1. **Bug 1: opencode binary not found** -- The entrypoint fails with `cannot execute: required file not found` at `/home/forge/.cache/tillandsias/opencode/opencode`. The `install_opencode()` function runs unconditionally (line 91) even when the agent is claude, and the download from `github.com/anomalyco/opencode` may be failing or the binary may be incompatible with the container's libc.

2. **Bug 2: Default agent is opencode, should be claude** -- `SelectedAgent::default()` returns `Self::OpenCode` (config.rs:27). When no config file exists or the `[agent]` section is missing, all containers get `-e TILLANDSIAS_AGENT=opencode`. The user wants claude as the default (and only) agent.

3. **Bug 3: Claude login asks for API key instead of OAuth** -- The current "Claude Login" flow (`handle_claude_login()` in handlers.rs:1266) opens `claude-api-key-prompt.sh` which prompts for an `sk-ant-*` API key and stores it in the OS keyring. This key is then injected as `ANTHROPIC_API_KEY` env var. However, the user has a Max/Pro subscription (flat billing) and wants to use `claude login` which does browser-based OAuth. The API key flow is wrong for this use case.

## What Changes

### Phase 1: Make claude the default and only agent

- **Default agent** -- Change `SelectedAgent::default()` from `OpenCode` to `Claude` in `config.rs`
- **Entrypoint** -- Stop unconditionally calling `install_opencode()`. Only install the selected agent. When agent is claude, skip opencode entirely.
- **OpenSpec init** -- The `openspec init --tools opencode` call on entrypoint line 105 needs to be updated to `--tools claude` or made agent-aware.

### Phase 2: Remove opencode as a selectable agent

- **Remove `SelectedAgent::OpenCode`** variant from the enum (or keep for backward compat but remove from menu)
- **Remove opencode install** from entrypoint -- delete `install_opencode()` function and all references
- **Remove opencode from PATH** in shell configs (`bashrc`, `zshrc`, `config.fish`)
- **Remove `opencode.json`** -- this is only needed for OpenCode's filesystem permissions; Claude Code has its own permission system
- **Remove opencode references** from `flake.nix` (forgeOpencode source, config copy, cache dir creation)
- **Remove opencode references** from embedded.rs (`FORGE_OPENCODE_JSON`, the write to `opencode.json`)

### Phase 3: Fix Claude auth for OAuth (Max/Pro)

- **Replace API key flow with OAuth** -- Instead of `claude-api-key-prompt.sh` prompting for `sk-ant-*`, the login flow should run `claude login` which opens a browser for OAuth. This requires:
  - Mount `~/.claude` from the HOST (not from `~/.cache/tillandsias/secrets/claude/`) so OAuth tokens persist
  - Or: run `claude login` on the host directly (not in a container) and mount the resulting `~/.claude/` into containers
- **The `~/.claude` directory** -- Currently containers mount `~/.cache/tillandsias/secrets/claude/` (an empty dir the app creates) at `/home/forge/.claude:rw`. For OAuth to work, the host's actual `~/.claude/` directory (which contains OAuth tokens from `claude login`) should be mounted instead.
- **Remove API key infrastructure** -- `claude-api-key-prompt.sh`, `store_claude_api_key()`, `retrieve_claude_api_key()`, `ANTHROPIC_API_KEY` env var injection, and the key scrubbing in entrypoint can all be removed if OAuth is the only auth method.
- **Menu item** -- "Claude Login" should either run `claude login` on the host or be removed if auth is handled externally.

## Findings from Investigation

### Where `TILLANDSIAS_AGENT` is set

The agent env var is passed to containers in 4 places:
1. `handlers.rs:460` -- `build_run_args()` (used by `handle_attach_here`)
2. `runner.rs:212` -- CLI mode `build_run_args()`
3. `handlers.rs:957` -- `handle_terminal()` format string
4. `handlers.rs:1119` -- `handle_root_terminal()` format string

All read from `load_global_config().agent.selected` which defaults to `OpenCode`.

### Where opencode is referenced

Key locations (excluding archive):
- `images/default/entrypoint.sh` -- install, PATH, exec
- `images/default/opencode.json` -- OpenCode permission config (deny list)
- `images/default/shell/bashrc:13`, `zshrc:9`, `config.fish:10` -- PATH includes opencode cache dir
- `flake.nix:16,64,82-83,93-94` -- source reference, cache dir, config copy
- `src-tauri/src/embedded.rs:38,101,144-145` -- embeds and writes opencode.json
- `crates/tillandsias-core/src/config.rs:35,43` -- SelectedAgent::OpenCode enum
- `src-tauri/src/handlers.rs:673` -- comment
- `src-tauri/src/github.rs:192,222` -- comment about entrypoint

### Claude auth mount path

The claude credentials directory is created and mounted in:
- `handlers.rs:469-473` -- `build_run_args()`: creates `~/.cache/tillandsias/secrets/claude/`, mounts as `/home/forge/.claude:rw`
- `runner.rs:221-225` -- same pattern for CLI mode
- `handlers.rs:934-935,965` -- `handle_terminal()`
- `handlers.rs:1096-1097,1127` -- `handle_root_terminal()`

This is an EMPTY directory (`secrets/claude/`). It does NOT contain OAuth tokens. The host's `~/.claude/` (which contains real OAuth credentials from `claude login`) is never mounted.

### Claude API key flow

- `secrets.rs:81-109` -- `store_claude_api_key()` / `retrieve_claude_api_key()` use OS keyring
- `handlers.rs:1266-1316` -- `handle_claude_login()` extracts embedded `claude-api-key-prompt.sh`, opens terminal, polls for temp file, stores key
- `claude-api-key-prompt.sh` -- prompts for `sk-ant-*` API key (NOT OAuth)
- `handlers.rs:463-465` -- injects `ANTHROPIC_API_KEY` env var if key exists in keyring
- `entrypoint.sh:41-42` -- captures key, unsets from env, re-injects only for claude process

### Entrypoint location

The entrypoint is at `images/default/entrypoint.sh` in this repo. It is compiled into the Nix-built image via `flake.nix:90` and placed at `/usr/local/bin/tillandsias-entrypoint.sh` inside the container. It is NOT in the forge repo.

## Capabilities

### Modified Capabilities
- `agent-selection-claude` -- Default changes from opencode to claude; opencode removed as option
- `claude-api-key-login` -- Replaced with OAuth-based auth (mount host `~/.claude/`)
- `default-image` -- Entrypoint simplified: no opencode install, no API key scrubbing
- `native-secrets-store` -- Claude API key keyring entry removed (OAuth tokens live in `~/.claude/`)

## Impact

- **Removed files**: `claude-api-key-prompt.sh`, `images/default/opencode.json`
- **Modified files**:
  - `crates/tillandsias-core/src/config.rs` -- default agent to Claude, optionally remove OpenCode variant
  - `images/default/entrypoint.sh` -- remove opencode install, remove API key scrubbing, simplify to claude-only
  - `images/default/shell/bashrc` -- remove opencode from PATH
  - `images/default/shell/zshrc` -- remove opencode from PATH
  - `images/default/shell/config.fish` -- remove opencode from PATH
  - `flake.nix` -- remove forgeOpencode source, opencode cache dir, opencode.json copy
  - `src-tauri/src/embedded.rs` -- remove FORGE_OPENCODE_JSON embed and write
  - `src-tauri/src/handlers.rs` -- mount host `~/.claude/` instead of empty secrets dir; remove ANTHROPIC_API_KEY injection
  - `src-tauri/src/runner.rs` -- same mount fix
  - `src-tauri/src/secrets.rs` -- remove claude API key functions
  - `src-tauri/src/menu.rs` -- update Claude Login item (run `claude login` or remove)
  - `src-tauri/src/handlers.rs` -- update/remove `handle_claude_login()`
