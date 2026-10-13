---
tags: [cdp, chromium, browser-automation, websocket, debugging]
languages: [bash, javascript, typescript]
since: 2026-05-06
last_verified: 2026-08-17
sources:
  - https://chromedevtools.github.io/devtools-protocol/
  - https://chromedevtools.github.io/devtools-protocol/1-3/
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
# freshness: auditor=windows-yolanda-fable5-20260817t0821z date=2026-08-17 verdict=updated scope=standing FRESHNESS audit — every documented method (Target.getTargets/attachToTarget, Page.navigate/getNavigationHistory/captureScreenshot, Runtime.evaluate, Network.setCookies), the JSON-RPC-2.0-over-WebSocket framing, the /json discovery flow, the sessionId idiom, the error shape and the loopback-only security notes all re-validated against the cited upstream refs and against this repo's own client (crates/tillandsias-browser-mcp/src/cdp_client.rs) — all sound. UPDATED for two reasons: (1) the header claimed two different verification dates (last_verified 2026-05-06 vs body "Last updated: 2026-04-27"), the one thing a freshness record must not be ambiguous about (same defect git-workflows.md was updated for on 2026-08-14); (2) the Base64 Payload Handling snippet taught base64::decode, a free function REMOVED in base64 0.22 — which is this workspace's own pin (Cargo.toml:52) — so the example could not compile against the project it ships with; replaced with the engine idiom cdp_client.rs actually uses
---
# Chrome DevTools Protocol (CDP) Quick Reference

**Use when**: Building browser automation, remote debugging, or headless browser control via CDP.

## Provenance

- https://chromedevtools.github.io/devtools-protocol/ — canonical protocol reference (stable)
- https://chromedevtools.github.io/devtools-protocol/1-3/ — stable v1.3 API index
- https://chromedevtools.github.io/devtools-protocol/tot/Target/ — `setAutoAttach` (`flatten`, `waitForDebuggerOnStart`), `attachedToTarget`
- https://chromedevtools.github.io/devtools-protocol/tot/Emulation/ — `setDeviceMetricsOverride`, `setUserAgentOverride`, `setTouchEmulationEnabled`, `setEmitTouchEventsForMouse`
- https://pptr.dev/api/puppeteer.launchoptions — `pipe`: Chromium's `--remote-debugging-pipe` (fds 3/4, NUL-terminated JSON)
- `plan/evidence/1655-urz9-browser-device-emulation-2026-10-13/` — the pipe transport and the touch re-assert, measured live in this repo
- **Last updated:** 2026-10-13 (pipe transport section, order 1655-urz9); 2026-08-17 for the rest (see the `freshness:` stamp in the frontmatter for the audit scope)

## Overview

CDP is a JSON-RPC 2.0 protocol over WebSocket. Each browser process exposes an HTTP discovery endpoint (`GET /json`) that lists available targets (pages, service workers, etc.), each with a `webSocketDebuggerUrl` for CDP connection.

@trace spec:host-browser-mcp, spec:host-chromium-on-demand

## Tillandsias browser windows: the pipe transport (order 1655-urz9)

A `browser.open` window has **no DevTools port**, in its container or on the
host. Its Chromium runs with `--remote-debugging-pipe`: commands are written to
the child's fd 3 and replies/events read from fd 4, each message one JSON object
followed by a NUL byte (no WebSocket, no HTTP, no `/json`). A small relay
(`crates/tillandsias-headless/src/browser_window_cdp_relay.js`) serves that pipe
on a Unix socket in a per-window 0700 host directory, for ONE client: the
tray's broker (`crates/tillandsias-browser-mcp/src/{cdp_client,window_cdp}.rs`).
When that client disconnects, the relay ends Chromium.

- The connection is browser-level. `Target.setAutoAttach {autoAttach: true,
  flatten: true, waitForDebuggerOnStart: true}` attaches the existing page and
  every later page (popups arrive paused); page commands then carry the
  flattened `sessionId` at the top level of the message.
- Device emulation per page: `setTouchEmulationEnabled {enabled,
  maxTouchPoints}`, `setEmitTouchEventsForMouse`, `setDeviceMetricsOverride
  {width, height, deviceScaleFactor, mobile}`, `setUserAgentOverride
  {userAgent, platform, userAgentMetadata?}` (client hints only for Chromium
  UAs; Safari sends none).
- **Measured quirk:** after the window's first cross-process commit
  (about:blank → the project's site) the page's `navigator.maxTouchPoints`
  fell back to 0 just after its first script read the emulated value, while
  viewport, dpr and UA held. Re-asserting touch on every main-frame
  `Page.frameNavigated` and on `Page.loadEventFired` fixes it.

## Essential Methods (host-browser-mcp v1)

| Domain.Method | Request Shape | Returns | Purpose |
|---|---|---|---|
| `Target.getTargets` | `{}` | `{ targetInfos: [{ id, type, url, ... }] }` | Discover available targets after browser launch |
| `Target.attachToTarget` | `{ targetId, flatten: false }` | `{ sessionId }` | Attach to a target; returns session ID for subsequent calls |
| `Page.navigate` | `{ url }` | `{ frameId, loaderId }` | Navigate page to URL |
| `Page.getNavigationHistory` | `{}` | `{ currentIndex, entries: [{ index, url, title, ... }] }` | Fetch current URL + title (lightweight page metadata) |
| `Page.captureScreenshot` | `{ format: "png", captureBeyondViewport?: bool }` | `{ data: "<base64-png>" }` | Capture viewport (or full page if flag set) |
| `Runtime.evaluate` | `{ expression, returnByValue: true }` | `{ result: { value, type } }` or `{ exceptionDetails: {...} }` | Execute JavaScript; `returnByValue: true` marshals result as JSON |
| `Network.setCookies` | `{ cookies: [{ name, value, url, path, httpOnly, secure, sameSite, expires }] }` | `{ success: bool }` | Set cookies before navigation |

## Critical Idioms

### Target Discovery After Launch
```
1. Start Chromium with --remote-debugging-port=<PORT>
2. Poll /json endpoint (TCP <PORT>, HTTP GET)
3. Filter by type === "page"
4. Extract webSocketDebuggerUrl
5. Open WebSocket, then call methods on that target
```

### Session-Based Calls
Once attached via `Target.attachToTarget`:
```json
{
  "id": 1,
  "method": "Page.navigate",
  "params": { "url": "https://example.com" },
  "sessionId": "<from Target.attachToTarget response>"
}
```

### Base64 Payload Handling
`Page.captureScreenshot` returns PNG as base64. Decode before saving. Use the
engine API — the old `base64::decode` free function was removed in base64 0.22,
which is this workspace's pin, so it will not compile here:
```rust
use base64::Engine as _;

let png_bytes = base64::engine::general_purpose::STANDARD.decode(response.data)?;
std::fs::write("screenshot.png", png_bytes)?;
```
This is the idiom the in-repo client uses (`crates/tillandsias-browser-mcp/src/cdp_client.rs`).

### Error Handling
CDP errors are JSON-RPC standard:
```json
{
  "id": 1,
  "error": { "code": -32602, "message": "Invalid params" }
}
```

Treat **any** error as a hard failure and propagate; no silent fallback (per design.md Decision 3: fail loudly).

## Timeouts

| Scenario | Timeout | Rationale |
|---|---|---|
| Wait for `/json` endpoint up | 5 s | Browser startup latency; 5 s = user-perceptible delay |
| Per-CDP call deadline | 2 s | Fast-fail for interactive tools (screenshot, click); preserve UX |
| WebSocket connection attempt | 2 s | Same as call deadline; refuse to hang |

## Pinned Versions

**Bundled Chromium major version**: TBD in `host-chromium-on-demand` (resolved at runtime from `~/.cache/tillandsias/chromium/*/chrome --version`).

CDP is stable across Chromium versions 90+; the specific endpoint (`/devtools/page/<TARGET_ID>`) is guaranteed stable per the protocol spec.

## Security Notes

- **Loopback only**: `ws://127.0.0.1:<PORT>/devtools/page/<TARGET_ID>`. Never remote CDP over network.
- **Tillandsias windows use no port at all**: a TCP DevTools port, even on loopback, hands the window (cookies included) to every local process. They use the pipe transport above.
- **No auth tokens on WebSocket**: The tray trusts its own Chromium process (same user, same machine). Per-call auth is not required.
- **Cookies set via CDP are ephemeral**: Use `Network.setCookies` before first navigation for OTP injection; the browser forgets them on exit (esp. with `--incognito`).
