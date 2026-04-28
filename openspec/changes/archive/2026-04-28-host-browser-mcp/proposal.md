## Why

Per the user's directive: agents inside forge containers need to drive browser windows for web-app testing / inspection / agentic control. The mechanism: an MCP server on the host exposing `browser.open` / `browser.click` / `browser.type` / `browser.screenshot` etc., backed by CDP against the bundled Chromium.

Critical security rule (the user's words): "block opencode.project.localhost itself, just the web.project.localhost." The agent should not be able to drive its own UI — only sibling project services.

## What Changes

- **NEW** Host MCP server `tillandsias-browser-mcp` (Rust binary) — speaks MCP stdio JSON-RPC. Tools: `browser.open(url)`, `browser.close(window_id)`, `browser.list_windows()`, `browser.click(window_id, selector)`, `browser.type(window_id, selector, text)`, `browser.screenshot(window_id)`, `browser.eval(window_id, js)`.
- **NEW** Allowlist enforced in `browser.open`:
  - Allow: `<service>.<project>.localhost:8080/*` for any service EXCEPT `opencode`.
  - Reject: `opencode.<project>.localhost` (the agent's own UI), any non-loopback URL, any URL not matching `*.<project>.localhost:8080`.
- **NEW** Debounce by base domain: if `web.<project>.localhost:8080` already has a window opened in last 1000ms, reject duplicate `browser.open` to prevent accidental window spam.
- **NEW** Backend: bundled-Chromium CDP client. Each `browser.open` spawns a new browser window via the existing `host-chromium-on-demand` flow with `--remote-debugging-port=<random>`; MCP server attaches CDP and tracks `(window_id, target_id)`.
- **NEW** Forge-side `mcp` config registers this server so agents see the tools in their tool list.
- **NEW** Accountability log: every `browser.open` / `browser.click` / `browser.type` emits `info!(accountability=true, category="browser", ...)`.
- Zero new tray UX (agent drives via MCP; user sees the browser windows that pop up — those are the existing forge-attach windows).

## Capabilities

### New Capabilities
- `host-browser-mcp`: tool surface + allowlist + debounce + CDP backend.

### Modified Capabilities
- `opencode-web-session`: agents in forge can drive sibling browser windows via MCP; opencode's own window is excluded by the allowlist.

## Impact

- New crate `crates/tillandsias-browser-mcp` — ~600 LOC (CDP client + MCP layer + allowlist).
- Depends on `host-chromium-on-demand` (CDP requires bundled Chromium).
- Depends on `tray-host-control-socket` (for tray-side window registry).
- Forge image bake `~/.config/opencode/config.json` adds the MCP server registration.
- Per-window CDP target id passed back to forge agents so subsequent calls bind to the right window.

## Sources of Truth

- Chrome DevTools Protocol: `chromedevtools.github.io/devtools-protocol/`
- MCP spec: `modelcontextprotocol.io`
- `cheatsheets/runtime/forge-shared-cache-via-nix.md` — mental model for "host owns shared state, forge consumes via narrow API"
