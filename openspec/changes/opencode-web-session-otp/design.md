# Design — opencode-web-session-otp

## Context

OpenCode Web today is reachable on `http://<project>.opencode.localhost:8080/` via the
host-side router container (`tillandsias-router`, Caddy). The listener is bound to
`127.0.0.1:8080` so the LAN cannot see it, but **anything on the user's host with
a process and a URL can connect** — sibling browser windows, `curl`, a malicious
extension reading the URL of another tab, an unrelated CLI process discovering the
hostname via `/proc/<pid>/cmdline` of the Chromium that the tray spawned. The
loopback bind is a network-layer guarantee; the application layer accepts every
request. That is the gap this change closes.

The locked decision is to require an **opaque session cookie on every request**.
The cookie is issued out-of-band: the tray generates a one-time-password (OTP)
per browser window and hands it to the bundled Chromium via the Chrome DevTools
Protocol BEFORE the navigation that opens the project URL. The browser presents
the cookie on its first request; the router validates against an in-memory
session table and lets the request through. Without a valid cookie the router
returns 401 — `curl` from another shell, a sibling browser window, an extension
poking the URL: all rejected. The forge container behind the router never knows
the cookie exists.

This change depends on two adjacent capabilities:

- `tray-host-control-socket` — the postcard-framed Unix socket at
  `/run/user/<uid>/tillandsias/control.sock` carries the tray→router OTP message.
- `host-chromium-on-demand` — the bundled Chromium binary the tray launches with
  CDP enabled, used for `Network.setCookies` before the navigate.

Without those capabilities the design degrades to a less safe form (file-on-disk
OTP transport; data-URL-with-form for cookie injection); both are explicitly
rejected below.

## Goals / Non-Goals

**Goals:**

- Every request to `http://<project>.opencode.localhost:8080/<path>` MUST carry
  a valid session cookie or be rejected with HTTP 401.
- The session cookie is set by the tray-launched browser window and ONLY by it.
  Other processes on the host cannot acquire the cookie value.
- Multiple "Attach Here" / "Attach Another" clicks for the same project produce
  **multiple concurrent sessions**, each with its own cookie value, all valid
  simultaneously for the lifetime of the container stack.
- OTP and session-cookie values never touch persistent storage and never appear
  in cleartext in any log.
- Browser closure does NOT invalidate the cookie. The cookie's `Max-Age=86400`
  (24 h) means a deliberately re-opened window can resume the session (subject to
  the user accepting that this is "a 24 h pass" not "an until-quit pass").

**Non-Goals:**

- Encrypting the cookie value or the OTP (they are opaque random tokens — there
  is no plaintext to protect).
- Surviving router-container restart. If the user explicitly stops + restarts
  the router, in-flight cookies become invalid; the user re-attaches.
- Surviving tray restart. The tray owns the OTP issuance pipeline; restarting
  the tray loses unconsumed OTPs (they expire in 60 s anyway).
- Cross-project session sharing. Each project's cookie is scoped to its own
  hostname; nothing in the design encourages a single cookie across projects.
- Replacing the existing source-IP allowlist in `base.Caddyfile` (loopback +
  RFC 1918 only). The OTP is defence-in-depth on top of that, not a replacement.

## Decisions

### Decision 1 (Q1) — OTP transport: tray↔router via Unix control socket

**Choice**: The tray sends a `ControlMessage::IssueWebSession { project, cookie_value }`
postcard envelope over `/run/user/<uid>/tillandsias/control.sock`. The router has
a sidecar (or the entrypoint shell wrapping `caddy run`) that connects as a
client, reads each envelope, and writes the cookie value into a per-project
in-memory list inside the router process.

**Why**: This satisfies the "no JSON in hot paths" rule (postcard is the project
default per `feedback_design_philosophy`). The socket already has mode `0600` —
only the user that owns the tray can connect. Postcard envelopes are
length-prefixed and typed; an unknown variant fails to deserialise, so the
router cannot be tricked into accepting a freeform string as a session token.

**Rejected alternative — file-on-disk**: The tray writes
`/run/router/otps/<project>` and a custom Caddy directive consults the file.
Rejected for two reasons. (1) **Secrets at rest**: `secrets-management` forbids
writing credential material to disk except as the ephemeral GitHub-token file
that exists only as long as a single git-service container needs it. An OTP file
keyed by project lives for as long as the project's container stack — minutes
to hours — and would need a defensive cleanup pass, custom file mode, etc.
(2) **No type safety**: a file-mode mistake or a wildcard glob on the directory
silently exposes everything; postcard over a 0600 socket has neither failure
mode.

**Rejected alternative — Caddy admin API on `localhost:2019`**: requires a Caddy
plugin or a `caddy-jwt`-style extension to add a custom validator. Adds
upstream-image complexity for no security benefit over the postcard path.

### Decision 2 (Q2) — Per-window OTP, all sessions valid concurrently

**Choice**: Every "Attach Here" or "Attach Another" click generates a fresh OTP
and a fresh cookie value. The router maintains a `Mutex<HashMap<String,
Vec<[u8; 32]>>>` keyed by host label (`opencode.<project>.localhost`) holding
the list of currently-valid cookie values for that project. New cookies are
appended; existing cookies are NOT invalidated.

**Why**: Mirrors the existing semantics — the project's container stack
supports multiple concurrent browser windows against the same `opencode serve`,
and the user is already wired to think of each window as an independent session.
Mutually invalidating sessions would surprise users (closing one tab kills
another), and the threat model doesn't justify it: a compromised cookie is
already a session takeover regardless of how many sessions are live.

**Rejected alternative — single session, last-write-wins**: forcing the previous
cookie out invalidates legitimate browser windows the user opened intentionally.
Bad UX, no security gain.

### Decision 3 (Q3) — CDP cookie injection before navigation

**Choice**: After the bundled Chromium is launched (via `host-chromium-on-demand`)
with `--remote-debugging-port=<random-high-port>`, the tray opens a CDP client,
sends `Network.setCookies` with the cookie value bound to
`http://<project>.opencode.localhost:8080`, and only THEN sends `Page.navigate`
to the same URL. The browser's first request carries the cookie.

**Why**: Eliminates the awkward `data:text/html;base64,...` form-POST step from
the proposal's draft. There is no intermediate document; no chance the form gets
intercepted by an extension; no `Origin: data:` weirdness on the POST. CDP runs
on a loopback port that only the tray can connect to (the random port + the
ephemeral profile dir mean the URL of the CDP endpoint is unguessable to other
processes within the ~10 ms window before navigation).

**Rejected alternative — data-URL form-POST**: documented in the proposal but
rejected here because (a) requires a `/_auth/login` endpoint that issues
Set-Cookie + 302, doubling the round trips; (b) the data: document is briefly
visible in browser history; (c) Firefox/Safari `--app=data:` support is
inconsistent. CDP is supported by every Chromium version we ship.

### Decision 4 (Q4) — Cookie attributes: Path=/, HttpOnly, SameSite=Strict, Max-Age=86400

**Choice**: `Set-Cookie: tillandsias_session=<base64url-32B>; Path=/; HttpOnly;
SameSite=Strict; Max-Age=86400`. No `Secure` flag (loopback origins are secure
contexts but the connection is plain HTTP — `Secure` would prevent the browser
from sending the cookie at all).

**Why each attribute**:

| Attribute | Reason |
|---|---|
| `tillandsias_session=` (32B base64url) | 256 bits of CSPRNG entropy; standard opaque-token shape; project-namespaced cookie name avoids collision with anything the OpenCode UI might set. |
| `Path=/` | Cookie applies to every path on the project's hostname. The router's path matchers are unaware of this; it just needs the cookie present somewhere. |
| `HttpOnly` | JavaScript inside the OpenCode UI cannot read `document.cookie` — even an XSS in the upstream UI cannot exfiltrate the session token. |
| `SameSite=Strict` | Browser will not attach the cookie to requests originated from any other origin (a malicious site cannot CSRF the project). |
| `Max-Age=86400` | 24 hours. Long enough that the user opening their laptop the next morning can find their window still attached; short enough that an unattended laptop's stolen cookie is a one-day exposure, not forever. |
| (no `Secure`) | The connection is HTTP (loopback); browsers refuse `Secure` cookies over HTTP. |
| (no `Domain`) | Defaults to the exact hostname — the cookie does not leak to sibling subdomains. |

**Rejected alternative — session-only cookie (no Max-Age)**: closing the
browser drops the cookie. User-hostile in the routine "I closed my laptop, came
back tomorrow" case; the user explicitly accepted the trade-off.

### Decision 5 (Q5) — Unconsumed OTP TTL: 60 s

**Choice**: When the tray issues an OTP, the router's in-memory state stores it
as "pending" with a 60-second expiry. If the browser doesn't present the cookie
within 60 s, the OTP is evicted and any later attempt to use it returns 401.

**Why**: The CDP cookie injection completes in ≪1 s under normal conditions
(launch Chromium, attach CDP, set cookie, navigate). 60 s gives slack for first-
launch chromium download + tray-side scheduling jitter without leaving an
indefinite window for a leaked OTP to be replayed. The 60 s figure tracks the
common HTTP cookie expiry sentinel (e.g. CSRF token TTLs in OWASP guidance).

**Rejected alternative — 5 s aggressive expiry**: pre-empts pathological launch
delays (slow toolbox, Chromium first-run unpack) where the user would see
"session expired before it began".

**Rejected alternative — no expiry**: every issued OTP becomes a permanent open
door against the project until consumed. Not acceptable.

### Decision 6 (Q6) — Router restart loses sessions

**Choice**: The session table is in-memory only. If the router container is
stopped and restarted (manual maintenance, image upgrade, host crash recovery),
all currently-issued cookies become invalid. The user re-attaches via the tray
to get a fresh cookie.

**Why**: Persisting session state to disk would (a) violate the secrets-at-rest
rule for the same reason file-on-disk OTP transport does, (b) require an
encryption-at-rest design we don't have. The router restart is a rare event;
the recovery cost is one re-attach click; the alternative cost is meaningful
new attack surface.

**Documented as known limitation** in the spec under "Router-restart behavior".

## Risks / Trade-offs

- **Per-OTP CDP attach overhead (~10–20 ms)**: every Attach now does an extra
  CDP handshake before navigation. Acceptable — the visible attach latency is
  already dominated by the forge image build / container start.
- **Router crash drops all sessions**: every open browser window suddenly returns
  401 after a router crash. The user must re-attach to get a fresh cookie. The
  router process is otherwise stable (Caddy + a thin sidecar); this is the
  trade-off the user explicitly accepted.
- **24 h cookie outlives "I quit Tillandsias"**: if the user quits the tray and
  re-launches within 24 h, the previous browser window's cookie is still valid
  against a freshly-launched session table — only if the SAME cookie value happens
  to exist in the new session table, which it won't (new random per restart).
  Effective behavior: tray restart invalidates cookies even though the cookie
  attribute says 24 h. Documented; the cookie's Max-Age is "client-side
  expiry"; the server is the authority.
- **CDP port is loopback but transient**: a process scanning loopback ports in the
  ~10 ms before tray-issued navigation could find the CDP endpoint. Mitigated
  by the random high port and the ephemeral `--user-data-dir`; an attacker
  reaching this would need both to win the race AND know what to send. Out of
  scope for this change; addressed by `host-chromium-on-demand`'s isolation.
- **OTP sent via control socket means a tray bug could leak it to the wrong
  consumer**. The postcard message variants are typed; the router's matcher
  rejects unknown variants. A tray that miscalls the API would fail to compile.
- **HttpOnly defeats per-tab debugging**: developers cannot read the cookie via
  `document.cookie` in DevTools. Acceptable — the cookie is opaque and there's
  no debug value in seeing it. DevTools' Application → Cookies pane still
  displays it for inspection.

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — OTP and cookie
  values live in `/run/user/<uid>/` (control socket) or in process memory (router
  session table); never in any of the four persistent path categories.
- `cheatsheets/runtime/forge-shared-cache-via-nix.md` — OTPs are NOT a cacheable
  artifact; the single-entry-point principle says nothing crosses
  `/nix/store/`.
- `cheatsheets/web/http.md` — cookie attribute semantics; `HttpOnly`,
  `SameSite=Strict`, `Max-Age` framing per RFC 6265bis (sourced via the http
  cheatsheet's planned provenance update).
- `cheatsheets/web/sse.md`, `cheatsheets/web/websocket.md` — confirm cookies are
  the standard browser-side credential vehicle for SSE and WebSocket sessions
  (OpenCode Web uses both).
- (NEW, this change) `cheatsheets/web/cookie-auth-best-practices.md` — added in
  the cheatsheet wave for this change with provenance to MDN
  (developer.mozilla.org/en-US/docs/Web/HTTP/Cookies) and RFC 6265bis.
- `openspec/specs/secrets-management/spec.md` — the OTP and the session cookie
  join the managed-secret class via this change's `secrets-management` delta.
- `openspec/changes/tray-host-control-socket/proposal.md` — defines the postcard
  envelope and socket contract this change consumes.
- `openspec/changes/host-chromium-on-demand/proposal.md` — defines the bundled
  Chromium and CDP-enabled launch this change consumes.
