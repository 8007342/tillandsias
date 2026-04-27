---
tags: [sse, server-sent-events, eventsource, streaming, http, browser, push]
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://html.spec.whatwg.org/multipage/server-sent-events.html
  - https://www.rfc-editor.org/rfc/rfc9110
authority: high
status: current
---

# Server-Sent Events (SSE)

@trace spec:agent-cheatsheets

## Provenance

- WHATWG HTML Living Standard §9.2 "Server-sent events" (EventSource interface, `text/event-stream` format, `data:` / `event:` / `id:` / `retry:` fields, reconnection algorithm — the authoritative SSE spec): <https://html.spec.whatwg.org/multipage/server-sent-events.html>
  local: `cheatsheet-sources/html.spec.whatwg.org/multipage/server-sent-events.html`
- RFC 9110 "HTTP Semantics" (underlying HTTP semantics for long-lived responses, `Cache-Control`, `Content-Type`): <https://www.rfc-editor.org/rfc/rfc9110>
  local: `cheatsheet-sources/www.rfc-editor.org/rfc/rfc9110`
- **Last updated:** 2026-04-25

**Version baseline**: SSE — HTML Living Standard `EventSource` interface; uses HTTP/1.1 long-lived response with `text/event-stream` content-type.
**Use when**: server pushes to browser/client, no client→server messaging needed. Simpler than WebSocket — plain HTTP, automatic reconnection, works through most proxies.

## Quick reference

| Item | Value |
|---|---|
| Response `Content-Type` | `text/event-stream` |
| Response `Cache-Control` | `no-cache` (mandatory) |
| Response `Connection` | `keep-alive` |
| Nginx hint | `X-Accel-Buffering: no` (disables proxy buffering) |
| Event field — `data:` | Payload line. Multiple `data:` lines join with `\n`. |
| Event field — `event:` | Named event type (default: `message`). |
| Event field — `id:` | Last event ID, replayed on reconnect via `Last-Event-ID` header. |
| Event field — `retry:` | Reconnection delay hint, milliseconds. |
| Event terminator | Blank line (`\n\n`). Required after each event. |
| Comment / keepalive | Line starting with `:` (e.g. `: ping`). Ignored by client. |
| Client API | `new EventSource(url)` → `.onmessage`, `.addEventListener('name', …)`, `.onerror`, `.close()` |
| HTTP version | HTTP/1.1 (long-lived response). Works on HTTP/2 but loses per-stream connection isolation. |
| Browser limit | ~6 concurrent SSE connections per origin (HTTP/1.1 connection cap). |

## Common patterns

### Pattern 1 — minimal event stream

```
data: hello\n\n
data: {"count":1}\n\n
```

Each event is one or more `data:` lines terminated by a blank line. Default event type is `message`; client receives via `onmessage`.

### Pattern 2 — named events

```
event: progress\ndata: {"pct":42}\n\n
event: done\ndata: ok\n\n
```

Client subscribes with `es.addEventListener('progress', e => …)`. Useful for routing different payload shapes without parsing every message.

### Pattern 3 — reconnection hint

```
retry: 5000\n\n
```

Server tells the client to wait 5s before reconnecting after a drop. Send once at connection start. Default is browser-defined (~3s in most engines).

### Pattern 4 — resumable streams with `id:`

```
id: 42\nevent: tick\ndata: ...\n\n
```

On reconnect, the browser sends `Last-Event-ID: 42`. The server replays from event 43. Useful for at-least-once delivery on flaky links.

### Pattern 5 — keepalive comment

```
: ping\n\n
```

Lines starting with `:` are comments — ignored by the client but reset proxy/browser idle timers. Send every 10–30s on otherwise idle streams.

## Common pitfalls

- **Proxy buffering kills the stream** — nginx, Squid, HAProxy, and CDNs may buffer the response until it fills a buffer or closes. Set `Cache-Control: no-cache`, `X-Accel-Buffering: no` (nginx), and disable response buffering at every hop. If events arrive in batches instead of live, this is the cause.
- **Forgetting to flush** — most server frameworks buffer writes. After each event you must explicitly flush (Node: `res.flush()` if compression middleware is in play; Python WSGI: yield + ensure no `Content-Length`; Go: `flusher.Flush()`). Without flush, the client sees nothing until the buffer fills.
- **JSON inside `data:` must be single-line** — a literal newline in the payload terminates the field. Either `JSON.stringify` (no pretty-print) or split across multiple `data:` lines (the client joins them with `\n`).
- **Browser connection cap (~6 per origin)** — opening one SSE per tab to the same origin exhausts the HTTP/1.1 connection pool fast. Multiplex via a single stream with named events, or move SSE to a subdomain. HTTP/2 helps but breaks per-stream backpressure.
- **`Last-Event-ID` carries no auth** — the browser auto-resends it on reconnect, but cookies/Authorization must still be valid. Token expiry mid-stream silently breaks resumption. Re-auth on reconnect or use short-lived refreshable session cookies.
- **Idle timeouts drop streams** — Bun's default `idleTimeout: 10s`, Cloudflare's 100s, AWS ALB's 60s all close idle connections. Send `: keepalive\n\n` comments well below the lowest timeout in the path.
- **No client→server messaging** — SSE is one-way. For bidirectional, use WebSocket or pair SSE with a separate POST endpoint. Don't try to abuse SSE for RPC.
- **HTTP/2 changes the failure mode** — over h2 you lose the 6-connection cap but a single TCP loss can stall every stream on that connection (head-of-line blocking). Test under packet loss before assuming h2 is strictly better.
- **CORS preflight applies** — `EventSource` with custom headers triggers OPTIONS first. The simple form (no custom headers, same-origin or `withCredentials: false`) avoids preflight.

## Forge-specific

The Tillandsias `/usr/local/bin/sse-keepalive-proxy.js` injects keepalive comments because Bun's default `idleTimeout: 10s` drops opencode's `/event` and `/global/event` streams. The proxy sits between the browser and the opencode server, forwarding events transparently and emitting `: ping\n\n` every few seconds to keep the connection above Bun's threshold. Without it, the OpenCode Web UI silently loses live updates after ~10s of inactivity.

## See also

- `web/websocket.md` — bidirectional alternative when the client also needs to send
- `web/http.md` — underlying protocol; SSE is a long-lived HTTP/1.1 response
