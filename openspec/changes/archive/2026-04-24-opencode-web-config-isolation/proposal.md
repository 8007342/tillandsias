## Why

Live-session diagnosis of OpenCode Web running inside a forge container showed
multiple violations of the spec's per-container isolation contract. The first
draft of this change over-corrected by restricting providers to ollama only;
the user revised the direction to **additive**: preserve every default OpenCode
capability, add ollama + enclave-specific configuration on top.

Observed issues this change addresses:

1. **Overlay config was never applied.** The Containerfile copied a minimal
   `opencode.json` stub (just `autoupdate: false`) to
   `~/.config/opencode/config.json`. The opinionated overlay at
   `/home/forge/.config-overlay/opencode/config.json` was mounted but not
   linked — so MCPs, instructions, ollama baseURL never took effect.

2. **Schema keys were wrong.** The overlay used
   `provider.ollama.api_url` (OpenCode silently ignores) instead of
   `provider.ollama.options.baseURL`. Also, `instructions` was an object
   mapping globs to strings (OpenCode expects an array of file paths) and
   `permission` used a custom `{allow, deny}` shape (OpenCode expects either
   a string action `"allow"|"deny"|"ask"` or an object keyed by
   `read`/`edit`/`glob`/etc.). These errors caused OpenCode to reject the
   config at startup, exit code 1, and the tray to toast "server did not
   start."

3. **"Global" pseudo-project appeared in the project picker.** OpenCode's
   project-discovery code (`packages/opencode/src/project/project.ts:182`)
   creates a row with `id="global"` `worktree="/"` when a request arrives
   without a directory hint. That row clutters the UI and breaks
   per-container isolation.

4. **Stale project rows persisted** in `~/.local/share/opencode/opencode.db`
   mid-session — users saw old project entries in the picker.

5. **Webview had no devtools** — needed for diagnosing OpenCode's own SSE
   / network / UI state when something misbehaved.

## What Changes

- **`entrypoint-forge-opencode-web.sh` applies the overlay at container
  start.** Copies `/home/forge/.config-overlay/opencode/config.json` and
  `tui.json` into `/home/forge/.config/opencode/` so the opinionated config
  wins over the Containerfile stub.

- **Overlay config uses the correct schema** (verified against the live
  schema at `https://opencode.ai/config.json`):
  - `provider.ollama.options.baseURL = "http://inference:11434/v1"`
  - `permission: "allow"` (string, not object)
  - `instructions: ["/path/one.md", "/path/two.md"]` (array of paths)

- **Overlay is ADDITIVE — no `enabled_providers` restriction.** Every
  OpenCode default provider (OpenCode Zen, OpenRouter, Helicone, Anthropic,
  OpenAI, etc.) remains available. We only ADD an `ollama` provider with
  its enclave-local baseURL and a curated list of ollama model entries so
  they appear in the picker alongside OpenCode's defaults. The user keeps
  every option they would have with stock OpenCode and additionally gets
  local ollama inference.

- **Entrypoint seeds a fresh OpenCode state per container.** Before
  `opencode serve` starts, the entrypoint deletes
  `~/.local/share/opencode/` so the SQLite db is recreated empty. With the
  container's CWD pinned to the mounted project directory, the first
  request's project-discovery registers exactly one project — the mounted
  one — and nothing else.

- **Tauri `WebviewWindowBuilder` enables devtools unconditionally.** Removes
  the `#[cfg(debug_assertions)]` gate. Always-on devtools lets users diagnose
  OpenCode UI state without a special build.

## Capabilities

### Modified Capabilities

- `opencode-web-session`: adds the config-overlay-applied-at-runtime contract,
  the additive ollama registration, the per-container DB seeding contract,
  and the webview devtools guarantee.

## Impact

- **Shell**: `images/default/entrypoint-forge-opencode-web.sh` — overlay
  copy step plus DB seeding step.
- **Config**: `images/default/config-overlay/opencode/config.json` — schema
  corrections, additive ollama provider, removed `enabled_providers`.
- **Rust**: `src-tauri/src/webview.rs` — unconditional `.devtools(true)`.
- **Images**: forge image rebuild required (entrypoint changed). Proxy,
  inference, git unchanged.
- **Host binary**: tray rebuild required (embedded config.json changed).
- **No schema migration, no new env vars.**

Deferred (follow-up work):

- Per-project mutable overlay dir (users save custom configs per project,
  persisted across container restarts). Needs host-side directory management
  and bind-mount wiring.
- "Reopen last session" menu item (OpenCode session URL format is
  `/<base64(dir)>/session/<id>`; tray would track the most recent session
  id per project and open directly to it).
