## Why

The current forge entrypoint (`images/default/entrypoint.sh`) fails to launch Claude Code correctly inside containers. The monolithic entrypoint handles all agent types (OpenCode, Claude, unknown) in a single script, and the Claude Code install path (`npm install -g --prefix`) does not reliably produce a working `claude` binary. When `install_claude()` fails silently, the entrypoint falls back to `exec bash` — the user sees a bare shell instead of their AI coding agent. This is the most urgent issue because the latest version ships broken for the default agent (Claude).

Root causes identified:

1. **Silent npm failure**: `install_claude()` swallows errors with `2>/dev/null || true`. When npm fails (network, permission, cache corruption), the user gets no diagnostic output.
2. **No update path**: Once installed, the entrypoint never checks for newer versions. Stale cached binaries persist across container restarts.
3. **API key scrubbing race**: The entrypoint captures `ANTHROPIC_API_KEY` then immediately `unset`s it, but Claude Code needs the key in its environment at exec time. The key is never re-injected.
4. **Missing PATH for Claude**: `install_claude()` sets `export PATH="$CC_PREFIX/bin:$PATH"` inside the function, but this only takes effect when the function is called — if the agent is "opencode", Claude's bin dir is never on PATH (minor but indicates fragility).

## What Changes

- **Fix Claude Code installation**: Replace silent npm install with proper error handling, retry logic, and user-visible diagnostics
- **Fix API key injection**: Pass the captured `_CLAUDE_KEY` to Claude Code via `exec env ANTHROPIC_API_KEY="$_CLAUDE_KEY"` instead of relying on the scrubbed environment
- **Add update check**: On each launch, check if a newer version is available and update non-interactively
- **Add install verification**: After install, verify the binary actually runs (`claude --version`) before proceeding
- **Improve fallback messaging**: When an agent fails to install/launch, show a clear message explaining what happened and how to retry

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `forge-entrypoint`: Claude Code installation is reliable, API key is properly injected, updates are checked on each launch

## Impact

- **Modified files**: `images/default/entrypoint.sh`
- **Risk**: Low. Changes are additive (better error handling, key injection fix). The entrypoint is rebuilt into the image via `flake.nix` on next build.
- **Testing**: Manual — launch a Claude forge container, verify Claude Code starts and has API key access. Launch with stale cache, verify update runs.
