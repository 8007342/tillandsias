# WebSockets

@trace spec:agent-cheatsheets

**Version baseline**: WebSocket protocol RFC 6455 (1.0).
**Use when**: bidirectional persistent connection — chat, real-time games, collaborative editing, live cursors. For server→client only, prefer SSE (simpler, auto-reconnect, fits HTTP/2).

## Quick reference

| Aspect | Detail |
|---|---|
| Handshake | HTTP/1.1 GET + `Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-Key`, `Sec-WebSocket-Version: 13` |
| Server reply | `101 Switching Protocols` + `Sec-WebSocket-Accept` (SHA-1 of key + magic GUID, base64) |
| URL schemes | `ws://` (plain), `wss://` (TLS) — default ports 80 / 443 |
| Frame opcodes | `0x1` text (UTF-8), `0x2` binary, `0x8` close, `0x9` ping, `0xA` pong, `0x0` continuation |
| Max frame payload | 125 (small), 65 535 (16-bit), 2^63 (64-bit) bytes |
| Close codes | `1000` normal, `1001` going away, `1002` protocol error, `1006` abnormal (no close frame), `1008` policy, `1011` server error |
| JS API | `new WebSocket(url)`, `.onopen`, `.onmessage`, `.onclose`, `.onerror`, `.send()`, `.close(code, reason)` |
| Python | `websockets` (asyncio), `websocket-client` (sync) |
| Rust | `tokio-tungstenite` (async), `tungstenite` (sync) |
| Go | `gorilla/websocket`, `nhooyr.io/websocket` |
| Node | `ws`, `socket.io` (higher-level w/ fallback) |

## Common patterns

### Pattern 1 — server upgrade handshake (Rust, axum)

```rust
use axum::extract::ws::{WebSocket, WebSocketUpgrade};

async fn handler(ws: WebSocketUpgrade) -> impl IntoResponse {
    ws.on_upgrade(handle_socket)
}

async fn handle_socket(mut socket: WebSocket) {
    while let Some(Ok(msg)) = socket.recv().await { /* echo, route, etc. */ }
}
```

Framework hides the SHA-1 dance; you write the post-upgrade loop.

### Pattern 2 — ping/pong keepalive

```javascript
setInterval(() => {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({type: "ping"}));
}, 30_000);
```

Browsers cannot send protocol-level ping frames — use an app-level ping in JSON. Server-side libs CAN send `0x9` frames; clients auto-reply `0xA`.

### Pattern 3 — reconnection with backoff

```javascript
function connect(attempt = 0) {
  const ws = new WebSocket(url);
  ws.onclose = () => {
    const delay = Math.min(1000 * 2 ** attempt, 30_000);
    setTimeout(() => connect(attempt + 1), delay + Math.random() * 1000);
  };
  ws.onopen = () => { attempt = 0; };
}
```

Cap at 30s, add jitter to avoid thundering herd. Reset attempts on successful open.

### Pattern 4 — JSON envelope over text frames

```javascript
ws.send(JSON.stringify({ type: "chat.msg", id: nanoid(), data: { text } }));
ws.onmessage = (e) => {
  const { type, data } = JSON.parse(e.data);
  handlers[type]?.(data);
};
```

WebSocket gives you message boundaries but no semantics. A `{type, id, data}` envelope makes routing and request/response correlation possible.

### Pattern 5 — binary frames for protobuf / postcard

```rust
let bytes = postcard::to_allocvec(&msg)?;
socket.send(Message::Binary(bytes)).await?;
```

Use binary frames (opcode `0x2`) for compact wire formats. Avoid base64-in-text — wastes 33%.

## Common pitfalls

- **No built-in reconnection** — the `WebSocket` object is dead after `onclose`. The client MUST recreate it. Wrap in a class that buffers outgoing messages while disconnected.
- **No built-in framing on top of frames** — one `.send()` ≠ one application message in fragmented or coalesced scenarios with binary protocols. If you need request/response, add an `id` field; if you stream, add length prefixes inside the frame.
- **CORS does not apply, but `Origin` does** — browsers send `Origin` on the upgrade request, but the server is free to ignore it. You MUST validate `Origin` server-side or attackers can connect from any page (cross-site WebSocket hijacking).
- **Idle connections die in proxies/firewalls** — load balancers, NATs, and corporate proxies drop idle TCP after 30–120s. Send app-level pings every 20–30s, or set TCP keepalive.
- **Reverse proxy needs WebSocket-aware config** — nginx needs `proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade";` plus a long `proxy_read_timeout`. Caddy handles it automatically.
- **Close code `1006` is not a real protocol code** — it means "the connection died without a close frame" (network blip, kill -9, proxy timeout). Never send it; only observe it.
- **Browser `WebSocket.send()` is fire-and-forget** — it returns `undefined`, not a promise. To know the message left the buffer, poll `bufferedAmount` or use a higher-level lib.
- **Authentication is awkward** — browsers cannot set headers on the upgrade request. Workarounds: token in query string (logged everywhere), cookie (CSRF-vulnerable, needs `SameSite`), or post-connect auth message before serving data.

## When to choose WebSocket vs SSE vs polling

| Choice | Direction | Best for |
|---|---|---|
| WebSocket | bidirectional, text + binary | chat, games, collaborative editing, custom protocols |
| SSE | server → client only, text | notifications, live feeds, log tailing — simpler, auto-reconnect, plays nice with HTTP/2 |
| Long-polling | bidirectional, request-shaped | last-resort fallback for hostile networks; trivially compatible everywhere |

## See also

- `web/sse.md` — simpler alternative for server→client streaming
- `web/http.md` — the foundation
