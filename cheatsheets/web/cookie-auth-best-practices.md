---
tags: [http, cookies, auth, sessions, security, samesite, httponly]
languages: []
since: 2026-04-25
last_verified: 2026-04-25
sources:
  - https://developer.mozilla.org/en-US/docs/Web/HTTP/Cookies
  - https://datatracker.ietf.org/doc/draft-ietf-httpbis-rfc6265bis/
  - https://www.rfc-editor.org/rfc/rfc6265
authority: high
status: current
---

# Cookie auth best practices

@trace spec:agent-cheatsheets, spec:opencode-web-session-otp

## Provenance

- MDN "HTTP cookies" — definitive cross-browser reference for `Set-Cookie`, attributes, and ecosystem behaviour: <https://developer.mozilla.org/en-US/docs/Web/HTTP/Cookies>
- RFC 6265bis "Cookies: HTTP State Management Mechanism" (in-progress IETF revision; modern attribute semantics including `SameSite`): <https://datatracker.ietf.org/doc/draft-ietf-httpbis-rfc6265bis/>
- RFC 6265 "HTTP State Management Mechanism" (the original published RFC; superseded by 6265bis but still the canonical text for many implementations): <https://www.rfc-editor.org/rfc/rfc6265>
  local: `cheatsheet-sources/www.rfc-editor.org/rfc/rfc6265.txt`
- **Last updated:** 2026-04-25

**Version baseline**: RFC 6265bis-draft (current as of 2026); supported by all modern browsers (Chrome 80+, Firefox 96+, Safari 13+).
**Use when**: implementing or reviewing session-cookie-based auth — picking attributes, choosing transport, redacting in logs.

## Quick reference — `Set-Cookie` attributes

| Attribute | Meaning | When to use |
|---|---|---|
| `HttpOnly` | JS cannot read via `document.cookie` | ALWAYS for session tokens (defeats XSS exfiltration) |
| `Secure` | Only sent over HTTPS | Always over HTTPS; **breaks loopback HTTP** — omit for `*.localhost` |
| `SameSite=Strict` | Never sent on cross-origin requests | Auth cookies for first-party apps (defeats CSRF) |
| `SameSite=Lax` | Sent on top-level cross-origin GET | Cookies that must work with external links |
| `SameSite=None` | Sent everywhere (REQUIRES `Secure`) | Third-party embedded contexts only |
| `Path=/` | Cookie scoped to entire host | Standard for session auth |
| `Domain=example.com` | Send to subdomains too | RARELY — leaks cookie to siblings |
| (no `Domain`) | Exact-host scope | DEFAULT and SAFER — does not leak to siblings |
| `Max-Age=N` | Lives N seconds from set time | Session cookies (preferred over `Expires`) |
| `Expires=<date>` | Lives until absolute time | Legacy; prefer `Max-Age` |
| (neither) | Browser-session lifetime | "Until window closes" UX |
| `Partitioned` | One-jar-per-top-level-site | Third-party iframes (Chrome Privacy Sandbox) |

## Common patterns

### Pattern 1 — opaque session token (the default)

```http
Set-Cookie: tillandsias_session=A6Q...43chars; Path=/; HttpOnly; SameSite=Strict; Max-Age=86400
```

256-bit random value, base64url-encoded (43 chars). Server keeps the
authoritative session table; cookie is just an opaque pointer. No need to
sign or encrypt — the value is already unguessable.

### Pattern 2 — CDP cookie injection before navigate

```rust
// Pseudocode — inject a session cookie before the browser ever issues a
// request, so the first request already carries it. Avoids a
// `Set-Cookie + 302` round trip and the brief 401 it would cause.
let cdp = connect_cdp(port).await?;
cdp.send("Network.setCookies", json!({"cookies":[{
    "name": "tillandsias_session", "value": token,
    "url": "http://opencode.demo.localhost:8080/",
    "path": "/", "httpOnly": true, "secure": false,
    "sameSite": "Strict", "expires": now + 86400,
}]})).await?;
cdp.send("Page.navigate", json!({"url": project_url})).await?;
```

Used by Tillandsias to avoid the brief 401 flash when launching a new
window. The cookie is in place before the first byte hits the wire.

### Pattern 3 — server-side validation with redaction

```rust
fn validate(project: &str, cookie: &[u8; 32]) -> bool {
    // Compare in constant time against the in-memory session table.
    // Never log the cookie value — even on validation failure.
    let ok = SESSIONS.read().get(project).is_some_and(|set| set.contains(cookie));
    info!(operation = if ok { "validate-success" } else { "validate-fail" },
          project = %project, value = "[redacted]");
    ok
}
```

Audit log records the operation + project, NEVER the cookie bytes (logging
them would let an attacker confirm a guess by reading logs).

## Common pitfalls

- **`Secure` + plain HTTP loopback** — browsers refuse `Secure` cookies on `http://`. Setting `Secure` for `http://*.localhost` means the browser silently drops the cookie. Loopback origins ARE secure contexts, but only over HTTPS or `Secure`-capable protocols. For plain HTTP loopback, OMIT `Secure`.
- **Logging cookie values** — even at debug level. A bug in a verbosity-setting check or a future log shipper sends the cookie wherever logs go. Redact at the source.
- **Comparing in non-constant time** — string equality leaks position-of-first-difference timing. Use a constant-time comparator (`subtle::ConstantTimeEq` in Rust, `crypto.timingSafeEqual` in Node) for any value derived from user input.
- **`Domain=` overscope** — setting `Domain=example.com` on a cookie issued by `app.example.com` makes the cookie travel to `cdn.example.com`, `legacy.example.com`, etc. Default (no `Domain`) is exact-host and safer.
- **Missing `SameSite`** — pre-2020 browsers default to `SameSite=None` (sent everywhere); modern browsers default to `Lax`. Always be explicit; never rely on the default.
- **`SameSite=None` without `Secure`** — modern browsers reject this combination. If you genuinely need cross-origin cookies, you must serve over HTTPS.
- **Forgetting to evict server-side on logout** — clearing the cookie client-side via `Max-Age=0` is necessary but not sufficient. The server's session table MUST also drop the entry; otherwise a stolen cookie remains valid.
- **Long `Max-Age` for stolen-cookie scenario** — 24 h is a reasonable trade-off; a multi-week session means a stolen cookie has multi-week impact. Pair long `Max-Age` with a server-side session-table TTL that you can reset on suspicious activity.
- **Trusting `Cookie` header presence as proof** — anyone can `curl --cookie tillandsias_session=guess`. The presence-regex matcher (Caddy `header_regexp`) is defence-in-depth; the server-side value-membership check is what actually authorises.
- **`HttpOnly` versus DevTools** — developers cannot see the cookie via `document.cookie`, but Application → Cookies pane in DevTools still shows it. This is by design; the JS-API restriction protects against XSS, not legitimate inspection.
- **Chrome's CDP HTTP server keeps the connection open after responding** — `GET /json` against `--remote-debugging-port=N` returns the body immediately but does NOT close the socket even when the request carried `Connection: close`. The socket stays open until Chrome's internal ~10 s timeout. Naive `read_to_end` therefore hangs and times out. Fix: parse `Content-Length` from the response headers and read exactly that many body bytes, OR fall back to a tight (~200 ms) inactivity gap after headers parse. Verified against `google-chrome --headless=new` 2026-04-26. **Tillandsias hit this** — every `attach_and_set_cookie` returned `NotReady` because of this, leaving every browser launch unauthenticated. Regression covered by `cdp::tests::http_get_loopback_returns_body_when_server_holds_connection_open`.
- **Constant-time comparison for cookie validation** — a naive `entry.value == cookie` is O(n) but its early-exit leaks position-of-first-difference timing. OWASP Session Management Cheat Sheet mandates constant-time comparison; in Rust use `subtle::ConstantTimeEq::ct_eq`. Tillandsias uses this in `OtpStore::validate`. Failing to use constant-time also leaks **which session-list entry matches** (loop iteration count) — sweep ALL entries unconditionally, OR-ing matches into a single result.

## See also

- `web/http.md` — surrounding HTTP semantics: status codes, header parsing, caching.
- `web/sse.md`, `web/websocket.md` — cookies travel automatically on SSE / WebSocket upgrades; same auth applies.
- `cheatsheets/security/csrf.md` (planned) — CSRF model that `SameSite=Strict` defeats.
