# Coordinator HTTP contract (v1)

@trace order:1825-v37w, spec:fleet-coordinator

This is the wire contract that the client (1826-gi8e) and the mirror hook
(1827-3rj4) code against. The binding design is
`openspec/changes/fleet-coordinator-warm-cache/design.md`. If the two disagree,
the design wins and this file is the bug.

## Transport

- Every request is a `POST` with a JSON body. Every response is JSON.
- **Auth runs before anything else.** A request without a valid
  `Cf-Access-Jwt-Assertion` gets **401** before routing, so it never reaches a
  Durable Object.
- The JWT must be RS256, signed by a key from
  `https://<ACCESS_TEAM_DOMAIN>/cdn-cgi/access/certs`, with:
  - `aud` containing `ACCESS_AUD`;
  - `iss` equal to `https://<ACCESS_TEAM_DOMAIN>`;
  - `exp` in the future, and `nbf` (if present) in the past.
- **The caller's identity** is the first of these that is present: the JWT's
  `email`, its `common_name` (the service token's client id), or its `sub`.
  The server stamps it on messages and claims. A client cannot set it.
- **Rate limit.** Each identity has a token bucket of `RATE_LIMIT_PER_MIN`
  requests per minute. A request costs one token per Durable Object it touches.
  An empty bucket gets **429**, with a `retry_after_s` field and a
  `Retry-After` header.

## Routes

| Route | Body |
|---|---|
| `POST /v1/batch` | `{"ops": [op, ...]}`, at most 20 ops |
| `POST /v1/op` | one `op` |

Every other path and method gets **404**. In particular, no route lists,
enumerates or publishes namespace names.

`/v1/batch` always answers 200 with `{"results": [...]}`. The results are in
op order, and each one has its own `ok`. `/v1/op` answers with the op's own
status.

## Ops

Every op has `"op"` and `"ns"`. A namespace is a normalised `owner/repo` or a
bare directory name: lower case, `[a-z0-9][a-z0-9._-]*`, one optional `/`, at
most 128 characters. It can also be `global`. An invalid name gets **400**.

| op | extra fields | result |
|---|---|---|
| `join` | none | `{created, freshness}`. Creates the namespace when it does not exist. |
| `send` | `body` (string, ≤ 8 KiB), `provider` (≤ 64 chars), `ttl_s`? | `{seq, expires_at}`. `ttl_s` defaults to 21600 (6 h) and is clamped to 1…86400. |
| `recv` | `since`? (seq, default 0), `limit`? (≤ 100) | `{msgs: [{seq, sender, provider, body, sent_at, expires_at}], next, freshness}`. Unexpired messages only. |
| `overview.put` | `overview` (any JSON, ≤ 256 KiB serialised), `sha` | `{freshness}`. Stores the client-folded overview as of `sha`, and resets `staleness` to 0. |
| `overview.get` | `client_head`? | `{overview, overview_sha, freshness}` |
| `bump` | `head_sha`, `overview`? | `{freshness}`. Sets `synced_sha` to `head_sha` and increments `staleness`. If `overview` is also sent, it acts as `overview.put` at `head_sha`. |
| `claim` | `order`, `ttl_s`? | `{token, until}` on success. If another identity holds a live overlay, **409** with `{holder, until}`. `ttl_s` defaults to 600 and is clamped to 1…900. The same identity re-claiming refreshes its overlay. |
| `release` | `order`, `token` | `{released: bool}` |
| `claims` | none | `{claims: [{order, holder, until}], freshness}`. Live overlays only. |

Every op except `join` refuses a namespace that has never been joined, with
**404** `not-joined`. Joining is the only way to create one.

`freshness` is
`{synced_sha, synced_at, age_s, staleness, might_be_outdated}`.
`might_be_outdated` is true in any of these cases:

- nothing has synced yet;
- `age_s` is over `STALE_AFTER_S` (default 900);
- the stored overview is older than `synced_sha`;
- the caller sent a `client_head` that differs from `synced_sha`.

## Not provided, on purpose

- Delivery or read receipts.
- Server-side folding.
- Long-polling. A connection never holds the Durable Object awake.
- Any listing of namespaces.
- An overlay is never authoritative. The git claim event still flips status.
