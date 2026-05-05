## Why

The browser isolation feature (wave 3) introduced ephemeral Chromium containers but left critical lifecycle gaps: no debouncing (rapid-fire window spawns), no tracking in `TrayState`, no user feedback on failure, and no cleanup on shutdown. The MCP server is currently a persistent daemon inside the forge container, but agents just need an on-demand tool — not a long-running process.

## What Changes

- **Track browser containers** in `TrayState.running` with `ContainerType::Browser` so "Stop Project" cleans them up
- **Add debouncing** (10s per project) to prevent rapid-fire `open_safe_window` spawns from a single agent
- **Tray notifications** for browser launch: withered icon + chip showing `<www> Launching...` → `<www> Browser launched` or `<www> Failed`
- **Simplify MCP tool** from persistent daemon to on-demand binary (agents call it, it spawns browser, returns — no long-running process needed)
- **Always open `opencode.<project>.localhost`** in safe browser (agents shouldn't open debug browsers for OpenCode)
- **One debug browser max** per project (port 9222 sharing — multiple debug windows deferred)
- **Shutdown cleanup** — browser containers terminated when tray exits (already partially works via `--rm`, ensure completeness)

## Capabilities

### New Capabilities
- `browser-daemon-tracking`: Track browser containers in TrayState with lifecycle management
- `browser-debounce`: Prevent rapid-fire window spawns with per-project debouncing
- `browser-tray-notifications`: Withered icon + chip feedback for browser launch status
- `mcp-on-demand`: Convert MCP server from persistent daemon to on-demand tool

### Modified Capabilities
- `browser-mcp-server`: Remove persistent daemon requirement, simplify to on-demand binary
- `browser-isolation-core`: Add tracking, debouncing, notifications to existing isolation core

## Impact

- **Code**: `handlers.rs`, `event_loop.rs`, `chromium_launcher.rs`, `mcp_browser.rs`, `tray_state.rs`
- **Specs**: `browser-daemon-tracking`, `browser-debounce`, `browser-tray-notifications`, `mcp-on-demand`
- **Behavior**: Browser containers now visible in tray menu, debounced, with user feedback
- **Cleanup**: Browser containers properly terminated on "Stop Project" or tray shutdown
