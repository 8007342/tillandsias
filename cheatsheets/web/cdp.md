# Chrome DevTools Protocol (CDP) Quick Reference

**Use when**: Building browser automation, remote debugging, or headless browser control via CDP.

## Provenance

- https://chromedevtools.github.io/devtools-protocol/ — canonical protocol reference (stable)
- https://chromedevtools.github.io/devtools-protocol/1-3/ — stable v1.3 API index
- **Last updated:** 2026-04-27

## Overview

CDP is a JSON-RPC 2.0 protocol over WebSocket. Each browser process exposes an HTTP discovery endpoint (`GET /json`) that lists available targets (pages, service workers, etc.), each with a `webSocketDebuggerUrl` for CDP connection.

@trace spec:host-browser-mcp, spec:host-chromium-on-demand

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
`Page.captureScreenshot` returns PNG as base64. Decode before saving:
```rust
let png_bytes = base64::decode(response.data)?;
std::fs::write("screenshot.png", png_bytes)?;
```

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
- **No auth tokens on WebSocket**: The tray trusts its own Chromium process (same user, same machine). Per-call auth is not required.
- **Cookies set via CDP are ephemeral**: Use `Network.setCookies` before first navigation for OTP injection; the browser forgets them on exit (esp. with `--incognito`).
