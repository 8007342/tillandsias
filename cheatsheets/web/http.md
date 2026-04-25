# HTTP

@trace spec:agent-cheatsheets

> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)

**Version baseline**: HTTP/1.1 + HTTP/2 mainstream; HTTP/3 (QUIC) emerging.
**Use when**: any web work — request semantics, status codes, headers, idempotency.

## Quick reference

### Methods

| Method | Safe | Idempotent | Cacheable | Notes |
|---|---|---|---|---|
| `GET` | yes | yes | yes | Read. Body discouraged; some servers/proxies reject it. |
| `HEAD` | yes | yes | yes | Like GET but no body. Cheap existence/freshness check. |
| `OPTIONS` | yes | yes | no | Discover allowed methods; CORS preflight. |
| `POST` | no | **no** | rarely | Create / non-idempotent action. |
| `PUT` | no | yes | no | Replace at URL. Resending = same end state. |
| `PATCH` | no | no | no | Partial update. Idempotent only if patch payload is. |
| `DELETE` | no | yes | no | Removing twice = still gone. |

### Status code groups

| Range | Meaning | Notable |
|---|---|---|
| `1xx` | Informational | `100 Continue`, `101 Switching Protocols` |
| `2xx` | Success | `200 OK`, `201 Created`, `204 No Content`, `206 Partial Content` |
| `3xx` | Redirection | `301`/`308` permanent, `302`/`307` temporary, `304 Not Modified` |
| `4xx` | Client error | `400`, `401` (auth), `403` (forbidden), `404`, `409` (conflict), `422`, `429` (rate limit) |
| `5xx` | Server error | `500`, `502` (bad gateway), `503` (unavailable), `504` (timeout) |

### High-leverage headers

| Header | Direction | Effect |
|---|---|---|
| `Content-Type` | both | Media type of body (`application/json`, `text/html; charset=utf-8`). |
| `Accept` | req | Acceptable response types — drives content negotiation. |
| `Authorization` | req | `Bearer <token>` / `Basic <b64>`. **Not** sent cross-origin by browsers without CORS opt-in. |
| `Cache-Control` | both | `max-age=N`, `no-store`, `private` vs `public`, `must-revalidate`. |
| `ETag` / `If-None-Match` | resp / req | Strong validator for conditional GET (304). |
| `Last-Modified` / `If-Modified-Since` | resp / req | Weaker validator; second-resolution. |
| `If-Match` | req | Optimistic concurrency for PUT/PATCH/DELETE — fail with 412 on stale. |
| `Content-Length` / `Transfer-Encoding: chunked` | both | Body framing. Mutually exclusive. |
| `Vary` | resp | Tells caches which request headers affect the response (`Vary: Accept-Encoding`). |

## Common patterns

### Pattern 1 — idempotent PUT for create-or-replace

```http
PUT /users/42 HTTP/1.1
Content-Type: application/json
If-Match: "v3"

{"name":"Ada","email":"ada@example.com"}
```

Client picks the URL/ID. Re-sending the same request yields the same end state. `If-Match` adds optimistic concurrency: server returns `412 Precondition Failed` if the resource changed since the client read it.

### Pattern 2 — conditional GET with ETag

```http
GET /feed HTTP/1.1
If-None-Match: "9b2cf"

# server response if unchanged:
HTTP/1.1 304 Not Modified
ETag: "9b2cf"
```

Saves bandwidth on hot endpoints. Client stores the `ETag` from the first 200 response and sends it back as `If-None-Match`. A 304 has no body — reuse the cached one.

### Pattern 3 — content negotiation

```http
GET /report/2026 HTTP/1.1
Accept: application/json;q=1.0, text/csv;q=0.5, */*;q=0.1
Accept-Language: en-US, en;q=0.8
Accept-Encoding: gzip, br
```

Server picks the best representation it can produce and echoes it via `Content-Type` + `Vary`. `q` values express preference (1.0 = preferred, 0.0 = unacceptable).

### Pattern 4 — CORS preflight

```http
# browser fires this automatically before non-simple requests
OPTIONS /api/items HTTP/1.1
Origin: https://app.example.com
Access-Control-Request-Method: PATCH
Access-Control-Request-Headers: authorization, content-type

# server must respond:
HTTP/1.1 204 No Content
Access-Control-Allow-Origin: https://app.example.com
Access-Control-Allow-Methods: GET, PATCH, DELETE
Access-Control-Allow-Headers: authorization, content-type
Access-Control-Allow-Credentials: true
Access-Control-Max-Age: 600
```

Triggered by: non-GET/POST/HEAD, custom headers, or `Authorization`. `Allow-Credentials: true` forbids `*` for `Allow-Origin` — must echo the exact origin.

### Pattern 5 — redirects (pick the right code)

```
301 Moved Permanently   — permanent, may rewrite POST→GET (legacy clients)
302 Found               — temporary, may rewrite POST→GET (legacy clients)
303 See Other           — explicit "GET the new URL" (post-redirect-get)
307 Temporary Redirect  — preserves method + body
308 Permanent Redirect  — preserves method + body
```

Use 308 (not 301) and 307 (not 302) when redirecting non-GET requests — modern clients keep the method and body intact. Use 303 after a successful POST to force a GET on the result page.

## Common pitfalls

- **POST is not idempotent by default** — retrying a flaky POST can create duplicate orders / charges. Make it idempotent with an `Idempotency-Key` header (server dedupes), or model the operation as PUT with a client-chosen ID.
- **301/302 vs 307/308** — historically clients silently rewrote POST to GET on 301/302. Use **307** (temp) and **308** (perm) when the method and body must be preserved. Test with `curl -L -X POST` to confirm.
- **`Cache-Control: private` is not "secret"** — it just means "shared caches must not store this; per-user browser cache is fine." For never-cache use `no-store`. For revalidate-every-time use `no-cache` (yes, the names are backwards).
- **`Authorization` is not sent cross-origin from browsers** unless the server opts in via `Access-Control-Allow-Credentials: true` *and* the client sets `credentials: 'include'`. Same for `Cookie`. Forgetting either side yields silent 401s.
- **GET with a body** — legal in HTTP/1.1 (RFC 9110), but many proxies, CDNs, and frameworks strip it or reject the request. If you need a body, use POST (or POST + method-override header).
- **`Expect: 100-continue` dance** — clients send headers, wait for `100 Continue`, then send the body. Some servers/proxies never reply 100, hanging the client for the timeout. Disable it for small bodies (`curl -H 'Expect:'`).
- **`Content-Length` vs `Transfer-Encoding: chunked`** — sending both is a request-smuggling vector. Pick one. HTTP/2 and HTTP/3 don't have `Transfer-Encoding` at all (framing is built in).
- **Hop-by-hop vs end-to-end headers** — `Connection`, `Keep-Alive`, `TE`, `Trailer`, `Transfer-Encoding`, `Upgrade`, `Proxy-Authorization` are stripped by proxies. Don't rely on them surviving past one hop.
- **Status codes lie when caches are involved** — a `200` may be a stale cached body; a `304` means "use your cache." Always inspect `Age`, `X-Cache`, and `Via` when debugging.

## See also

- `web/openapi.md` — declarative API specs built on these primitives
- `utils/curl.md` — CLI for HTTP work (status, headers, methods, proxies)
- `web/sse.md`, `web/websocket.md` — beyond request/response (server push, full-duplex)
