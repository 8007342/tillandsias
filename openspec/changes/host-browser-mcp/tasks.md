# Tasks — host-browser-mcp

## 1. Cheatsheets (write FIRST so spec/code can cite real provenance)

- [ ] 1.1 Create `cheatsheets/web/cdp.md` with:
  - `## Provenance` listing `https://chromedevtools.github.io/devtools-protocol/`
    (canonical) and the stable-1.3 page index
    `https://chromedevtools.github.io/devtools-protocol/1-3/`. Add
    `**Last updated:** 2026-04-25`.
  - Quick reference table of every CDP method this server uses
    (`Target.getTargets`, `Target.attachToTarget`, `Page.navigate`,
    `Page.getNavigationHistory`, `Page.captureScreenshot`,
    `Network.setCookies`, `Runtime.evaluate`) with parameter shape and
    return-value highlights.
  - Pinned version: the current bundled-Chromium major from
    `host-chromium-on-demand`.
  - `@trace spec:host-browser-mcp, spec:host-chromium-on-demand`.
- [ ] 1.2 Create `cheatsheets/web/mcp.md` with:
  - `## Provenance` listing
    `https://modelcontextprotocol.io/specification/2025-06-18` (canonical)
    and `https://modelcontextprotocol.io/specification/2025-06-18/server/tools`.
    Add `**Last updated:** 2026-04-25`.
  - Quick-reference table for `initialize`, `tools/list`, `tools/call`,
    `prompts/list`, `resources/list`, `resources/templates/list`,
    `notifications/initialized` with request/response sketches.
  - JSON-RPC 2.0 framing, error-code conventions (`-32601` method not
    found, `-32602` invalid params, `-32000+` server-defined).
  - The required `prompts/list` empty-array response (the
    `git-tools.sh` lesson: silence stalls UI for 60 s).
  - `@trace spec:host-browser-mcp`.
- [ ] 1.3 Add both new cheatsheets to `cheatsheets/INDEX.md` under the
  `web/` category.

## 2. tray-host-control-socket: McpFrame variant

- [ ] 2.1 Depends on `tray-host-control-socket` capability landing
  first.
- [ ] 2.2 Add `ControlMessage::McpFrame { session_id: u64, payload: Vec<u8> }`
  variant at the END of the enum (preserve existing variant indices).
- [ ] 2.3 Add a `BrowserMcp` capability string to the
  `Hello`/`HelloAck` capability advertising path; the forge stub
  declares it on connect.
- [ ] 2.4 Verify the existing per-message size cap permits up to 4 MiB
  for the `McpFrame` variant — if the cap is 64 KiB across all variants,
  introduce a per-variant cap override so `McpFrame` may carry up to
  4 MiB and other variants stay at 64 KiB. Document under design.md
  Open Question Q-OPEN (size-cap reconciliation).
- [ ] 2.5 Unit tests: round-trip `McpFrame` with empty / small / 4 MiB
  payloads; reject 4 MiB + 1 byte; verify additive enum evolution
  doesn't reshuffle prior variant indices.
- [ ] 2.6 `@trace spec:host-browser-mcp, spec:tray-host-control-socket`
  on every code path.

## 3. PeerPid → ProjectLabel table in tray

- [ ] 3.1 Add `crates/tillandsias-podman/src/peer_table.rs`
  (or extend an existing module if a registry already exists) with:
  - `struct PeerTable(parking_lot::Mutex<HashMap<u32, ProjectLabel>>)`
  - `insert(pid: u32, label: ProjectLabel)` — synchronous, called at
    forge spawn before stdio is exposed.
  - `remove(pid: u32)` — called at forge exit.
  - `lookup(pid: u32) -> Option<ProjectLabel>`.
  - `clear()` — called at tray graceful shutdown.
- [ ] 3.2 Wire into `src-tauri/src/handlers.rs` forge spawn / exit
  paths so the table is updated synchronously with container lifecycle
  events.
- [ ] 3.3 Unit tests: spawn-then-lookup, exit-then-lookup-fails,
  clear-empties-table, concurrent insert/remove safety.
- [ ] 3.4 `@trace spec:host-browser-mcp, spec:tray-app, spec:podman-orchestration`.

## 4. Tray: in-process MCP module

- [ ] 4.1 Create `src-tauri/src/browser_mcp/mod.rs` exposing
  `start(control_socket_handle, peer_table) -> McpHandle`.
- [ ] 4.2 Implement the JSON-RPC 2.0 framing layer:
  - Newline-delimited inbound (per existing forge MCP convention).
  - `serde_json::Value` parse → dispatch by `method`.
  - Required method handlers: `initialize`, `tools/list`, `tools/call`,
    `prompts/list`, `resources/list`, `resources/templates/list`,
    `notifications/initialized`. All others → `-32601 Method not found`.
- [ ] 4.3 `tools/list` returns the eight v1 tool descriptors with
  `inputSchema` JSON Schemas.
- [ ] 4.4 `tools/call` dispatches by tool `name` to per-tool handlers
  in `src-tauri/src/browser_mcp/tools/{open,list_windows,read_url,
  screenshot,click,type,eval,close}.rs`.
- [ ] 4.5 `tools/call` enforces the per-session 16-concurrent-call
  cap via a `tokio::sync::Semaphore(16)` per session.
- [ ] 4.6 Hook into `ControlMessage::McpFrame` dispatch on the host
  control socket: each new control-socket connection that receives an
  `McpFrame` allocates a fresh `session_id` (monotonic counter) and
  binds it to the resolved project label.
- [ ] 4.7 On connection accept, look up the connecting peer's PID via
  `SO_PEERCRED`. PID not in `PeerTable` → close connection with
  `Error { code: UnauthorisedPeer }`.
- [ ] 4.8 `@trace spec:host-browser-mcp, spec:tray-app` on every
  public item; `// @cheatsheet web/mcp.md` near the framing layer.

## 5. WindowRegistry + chromium launch

- [ ] 5.1 Create `src-tauri/src/browser_mcp/window_registry.rs`:
  - `struct WindowRegistry { windows: parking_lot::Mutex<HashMap<WindowId, WindowEntry>> }`
  - `WindowEntry { pid: u32, cdp_port: u16, target_id: String, project: ProjectLabel, user_data_dir: PathBuf, opened_url: String }`
  - `insert / get / remove / list_for_project / drain_all`
- [ ] 5.2 Implement `browser_mcp/launcher.rs` reusing the bundled-Chromium
  resolution logic from `host-chromium-on-demand`:
  - `launch(url: &Url, project: &ProjectLabel) -> Result<WindowEntry>`
  - Random ephemeral high port (49152..=65535) for `--remote-debugging-port`.
  - Ephemeral `--user-data-dir` under
    `$XDG_RUNTIME_DIR/tillandsias/mcp/<window-id>/`.
  - Mandatory flags: `--app=<url>`, `--user-data-dir=<path>`,
    `--incognito`, `--no-first-run`, `--no-default-browser-check`,
    `--remote-debugging-port=<port>`.
- [ ] 5.3 CDP attach: 2 s timeout; reuse the CDP client introduced by
  `opencode-web-session-otp` (`src-tauri/src/cdp.rs`); `Target.getTargets`
  → `Target.attachToTarget` → record `target_id`.
- [ ] 5.4 Spawn a watcher task per launched chromium PID — when the PID
  exits (any cause), remove the WindowRegistry entry and recursively
  delete the `--user-data-dir`.
- [ ] 5.5 On tray Quit: `drain_all` SIGTERMs every PID; 5 s grace; then
  SIGKILL; recursively delete every `--user-data-dir`.
- [ ] 5.6 Unit tests with mocked `Command` + mock CDP socket: launch
  produces correct flag set; CDP attach captures `target_id`; PID exit
  cleans the registry; `drain_all` reaps stragglers.
- [ ] 5.7 `@trace spec:host-browser-mcp, spec:host-chromium-on-demand`;
  `// @cheatsheet web/cdp.md` near the CDP attach code.

## 6. Allowlist enforcement

- [ ] 6.1 Implement `src-tauri/src/browser_mcp/allowlist.rs` with
  `validate(url: &str, project: &ProjectLabel) -> Result<Url, AllowlistDeny>`
  enforcing all six rules from the spec (scheme, no IP literal,
  `<project>.localhost` suffix, `opencode.` left-most label denied,
  port 8080, no userinfo).
- [ ] 6.2 Unit tests covering each rule's reject path AND the accept
  path with several positive examples (`web.<project>.localhost:8080/`,
  `api.<project>.localhost:8080/foo?q=1`).
- [ ] 6.3 Wire allowlist into `browser.open` BEFORE any chromium spawn
  attempt; on deny return MCP tool error with `URL_NOT_ALLOWED: <reason>`
  and emit accountability log.
- [ ] 6.4 Property test (proptest or quickcheck): for any random URL
  and any random project label, exactly one of `accept` / `reject`
  outcomes is produced (no panics, no ambiguity).
- [ ] 6.5 `@trace spec:host-browser-mcp, spec:opencode-web-session`;
  `// @cheatsheet web/http.md` near URL parsing.

## 7. Per-(project,host) debounce

- [ ] 7.1 Add
  `struct DebounceTable(parking_lot::Mutex<HashMap<(ProjectLabel, String), (Instant, WindowId)>>)`.
- [ ] 7.2 In `browser.open` after allowlist passes: lookup
  `(project, host)`. If `now - last_open < 1000 ms` AND the
  recorded `WindowId` is still in `WindowRegistry`, return the
  existing window id and `debounced: true` without spawning.
- [ ] 7.3 Unit tests: rapid duplicate returns existing; after 1000 ms
  spawns new; closed window invalidates the debounce entry; different
  hosts in the same project do not debounce each other.
- [ ] 7.4 `@trace spec:host-browser-mcp`.

## 8. Per-tool implementation

- [ ] 8.1 `browser.open` — covered by sections 5–7.
- [ ] 8.2 `browser.list_windows` — `WindowRegistry.list_for_project`,
  fetch live URL/title for each via
  `Page.getNavigationHistory` (parallel `tokio::join!`).
- [ ] 8.3 `browser.read_url` — single `Page.getNavigationHistory`
  call against the window's CDP target.
- [ ] 8.4 `browser.screenshot` — `Page.captureScreenshot` with
  `format: "png"`, optional `captureBeyondViewport: true` when
  `full_page == true`. Base64-encoded PNG plus width/height.
- [ ] 8.5 `browser.click` — `Runtime.evaluate` against expression
  ``document.querySelector(selector).click()`` with proper escape
  of `selector`. Return `{ ok: bool }`.
- [ ] 8.6 `browser.type` — `Runtime.evaluate` to set `.value` and
  dispatch `input` event on the matched element. Return `{ ok: bool }`.
  No raw key dispatch in v1 (per design.md Decision 7).
- [ ] 8.7 `browser.eval` — gated: ALWAYS return
  `EVAL_DISABLED` in v1. Function body for the gated CDP call exists
  behind a `#[cfg(feature = "browser-eval-enabled")]` guard so the
  follow-up change can flip the flag without duplicating logic.
- [ ] 8.8 `browser.close` — terminate chromium PID (SIGTERM, 5 s,
  SIGKILL), remove from `WindowRegistry`, delete user_data_dir.
  Return `{ ok: true }`.
- [ ] 8.9 `@trace spec:host-browser-mcp` on every tool;
  `// @cheatsheet web/cdp.md` on every CDP-using tool.

## 9. Forge-side stub script

- [ ] 9.1 Verify `socat` is present in the forge image
  (`tillandsias-forge`) — write a small probe script in CI that fails
  the build if absent. (Resolves design.md `TODO: verify` for socat.)
- [ ] 9.2 Create `images/default/config-overlay/mcp/host-browser.sh`:
  - Header: `#!/usr/bin/env bash`, `set -euo pipefail`,
    `# @trace spec:host-browser-mcp, spec:default-image`,
    `# @cheatsheet web/mcp.md, runtime/networking.md`.
  - Reads `$TILLANDSIAS_CONTROL_SOCKET`; errors clearly if unset or
    file missing (writes JSON-RPC error response to stdout for the
    in-flight `initialize`).
  - Uses `socat - UNIX-CONNECT:$TILLANDSIAS_CONTROL_SOCKET` for the
    duplex bridge; framing wrapper handled by an inline awk/python
    helper that prepends 4-byte big-endian length and the `McpFrame`
    discriminator.
- [ ] 9.3 Add `host-browser.sh` to the embedded image-source list in
  `src-tauri/src/embedded.rs` (per
  `feedback_embedded_image_sources` memory note — release builds break
  if this is forgotten).
- [ ] 9.4 Update `images/default/config-overlay/opencode/config.json`:
  add the `host-browser` `mcp` entry per the spec.
- [ ] 9.5 Add the equivalent registration to the Claude Code config
  baked into the forge image (path: `.config-overlay/claude/config.json`
  if present, else `TODO: verify` and add).
- [ ] 9.6 Integration test: `podman run` the forge image with the host
  control socket bind-mounted, exec the stub, send a hand-crafted
  JSON-RPC `tools/list`, assert response lists eight tools.
- [ ] 9.7 Fallback path documentation in design.md Q-OPEN-4: if shell
  stub proves unreliable in CI, follow-up change replaces with a tiny
  Rust binary baked at `/usr/local/bin/tillandsias-mcp-bridge` (≤ 200 KB).
  Track under `Open Question Q-OPEN-4`.

## 10. Accountability logging

- [ ] 10.1 In every tool handler, emit exactly one
  `tracing::info!(accountability = true, category = "browser-mcp",
   spec = "host-browser-mcp", cheatsheet = "web/cdp.md", ...)` log
  line per `tools/call`, with the field set required by the
  spec's accountability requirement.
- [ ] 10.2 Audit-log payload redaction:
  - `browser.open` → log `host` only, never path/query.
  - `browser.eval` → log `expression_sha256`, never the expression.
  - `browser.type` → log `selector` and `text_len`, never the text.
  - `browser.screenshot` → never log the PNG bytes.
- [ ] 10.3 Test: capture structured log output during a full mocked
  tool-call sequence, assert no field contains a known-secret literal
  (e.g. `hunter2`, `secret=xyz`, base64 PNG prefix `iVBORw`).
- [ ] 10.4 `@trace spec:host-browser-mcp, spec:logging-accountability`.

## 11. Tests

- [ ] 11.1 Unit tests: covered above per module (allowlist, debounce,
  registry, framing, tool handlers).
- [ ] 11.2 Integration test (host-side, requires podman):
  - 11.2.1 Spawn forge container; via the stub, send `tools/list` →
    expect eight tools.
  - 11.2.2 `browser.open` an allowed URL → expect chromium PID +
    window registry entry.
  - 11.2.3 `browser.open` `opencode.<project>.localhost` →
    expect `URL_NOT_ALLOWED`.
  - 11.2.4 `browser.open` cross-project URL → expect
    `URL_NOT_ALLOWED`.
  - 11.2.5 Two rapid identical opens within 500 ms → expect
    `debounced: true` on second.
  - 11.2.6 `browser.screenshot` on an opened window → PNG decodes,
    width/height match expected viewport.
  - 11.2.7 Forge container exit while window open → window persists
    30 s later.
  - 11.2.8 Tray Quit while windows open → all PIDs reaped within 10 s.
- [ ] 11.3 Audit-log integration test: full session cycle,
  `grep -v` for secret patterns produces zero hits.
- [ ] 11.4 Concurrency test: 16 in-flight `tools/call` succeed; 17th
  is rejected with `ConcurrentCallLimit`.

## 12. Documentation: docs/cheatsheets/ host-side updates

- [ ] 12.1 Update `docs/cheatsheets/secrets-management.md` to note
  the MCP-launched windows reuse the OTP cookie pipeline; add a row in
  the secret-types table pointing at this change.
- [ ] 12.2 Add a new `docs/cheatsheets/host-browser-mcp.md` (operator
  doc, not agent-facing) covering: the eight tools, the allowlist
  rules, the eight-tool-surface rationale, troubleshooting
  (`BROWSER_UNAVAILABLE`, `URL_NOT_ALLOWED`, `EVAL_DISABLED`,
  `UnauthorisedPeer`), and where windows land.

## 13. Versioning

- [ ] 13.1 After `/opsx:archive`, run
  `./scripts/bump-version.sh --bump-changes`.
- [ ] 13.2 Commit each cohesive batch with the trace URL footer per the
  project convention.
