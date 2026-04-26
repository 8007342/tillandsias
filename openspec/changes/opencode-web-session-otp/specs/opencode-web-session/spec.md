## MODIFIED Requirements

### Requirement: Native browser URL format uses `*.localhost` subdomains, no path segment

The webview-replacement URL SHALL be
`http://<project>.opencode.localhost:8080/` — hostname carries the project
identity and the service identifier, path is bare `/`, and the host-side router
listens on TCP port `8080`. `<project>` is the sanitized project name
(lowercase alphanumeric + hyphen).

Before navigation, the tray SHALL set a session cookie on the bundled Chromium
window via the Chrome DevTools Protocol (`Network.setCookies`). The cookie value
is the per-window session token issued by the router and transported to the
browser through the tray; see "Session cookie attributes" and "Per-window OTP
generation" requirements below. Requests to `<project>.opencode.localhost:8080`
without a valid `tillandsias_session` cookie SHALL be rejected by the router
with HTTP `401 Unauthorized` — independent of source IP, hostname, or path.

The legacy form `http://<project>.localhost:<host_port>/` (with an
allocated random port published per forge) is **deprecated** — the router
container fronts every project on a single host port. The internal Caddy
listener inside the router stays on port `:80`; only the host-side publish
moves to `8080`.

OpenCode's `InstanceMiddleware` continues to determine the project directory
via `?directory=` → `x-opencode-directory` header → `process.cwd()`. The forge
entrypoint `cd`s into `$PROJECT_DIR` before launching `opencode serve`, so
`process.cwd()` is always the mounted project's absolute path. The hostname
identifies the project; the cookie identifies the session.

#### Scenario: URL is hostname-with-port, cookie is set before navigation

- **WHEN** the tray constructs the launch URL for a project named `thinking-service`
- **THEN** the URL is exactly `http://thinking-service.opencode.localhost:8080/`
- **AND** the tray issues `Network.setCookies` over the bundled Chromium's CDP
  endpoint with `name=tillandsias_session`, `value=<token>`, `domain=thinking-service.opencode.localhost`,
  `path=/`, `httpOnly=true`, `sameSite=Strict`, `expires=<now+86400>` BEFORE the
  `Page.navigate` call
- **AND** the URL contains no base64-encoded path segment
- **AND** the URL contains neither `127.0.0.1` nor a bare `localhost:`

#### Scenario: Request without valid cookie is rejected at the router

- **WHEN** any process other than the tray-launched Chromium issues a request
  to `http://<project>.opencode.localhost:8080/<any-path>` without the
  `tillandsias_session` cookie OR with a value not currently in the router's
  per-project session table
- **THEN** the router responds with HTTP `401 Unauthorized`
- **AND** the response body is `unauthorised — open this project from the Tillandsias tray`
- **AND** no request is forwarded upstream to the forge container
- **AND** the rejection is logged with `category = "router"`, `spec = "opencode-web-session-otp"`,
  and the value field redacted (cookie value never appears in logs)

#### Scenario: Subdomain is a secure context

- **WHEN** the browser loads `http://<project>.opencode.localhost:8080/` after
  the cookie injection succeeds
- **THEN** `window.isSecureContext` returns `true` (per W3C Secure Contexts §3.1;
  loopback origins are secure regardless of port)
- **AND** Notification, WebCrypto, clipboard, and service-worker APIs treat the
  origin as secure despite plain HTTP

#### Scenario: Project registration falls back to CWD

- **WHEN** the browser issues the first API request to the forge (`/config`,
  `/project`, etc.) carrying the valid session cookie
- **AND** the request has no `?directory=` query, no `x-opencode-directory`
  header, and no `:dir` route param
- **THEN** OpenCode's `InstanceMiddleware` falls back to `process.cwd()`
- **AND** the resolved directory is `/home/forge/src/<project>` (the forge
  entrypoint's CWD)
- **AND** the mounted project registers as OpenCode's active project

#### Scenario: No sudo, no /etc/hosts

- **WHEN** installing or running Tillandsias on a fresh Fedora / Silverblue /
  Ubuntu / macOS system
- **THEN** no entry is added to `/etc/hosts`
- **AND** no `sudo` is invoked
- **AND** `.localhost` subdomains resolve via systemd-resolved /
  glibc-myhostname / browser hardcoding

## ADDED Requirements

### Requirement: Per-window OTP generation

The tray SHALL generate a fresh 256-bit one-time password (OTP) and a fresh
256-bit session cookie value on every "Attach Here" or "Attach Another" click.
Both values SHALL be drawn from the OS CSPRNG (`getrandom(2)` on Linux,
`SecRandomCopyBytes` on macOS, `BCryptGenRandom` on Windows — the `rand` crate's
`OsRng` is the canonical access path). Both values SHALL exist only in process
memory and SHALL never be written to any file, log, or environment variable.

The OTP is a transport secret used exactly once to authorise the session-cookie
issuance. The session-cookie value is independent of the OTP (separate random
draw) so an OTP that leaks AFTER consumption does not reveal the cookie.

@trace spec:opencode-web-session-otp, spec:secrets-management

#### Scenario: Each attach produces fresh entropy

- **WHEN** the user clicks Attach Here on a project, then clicks Attach Another
  on the same project five seconds later
- **THEN** the second click generates a NEW OTP and a NEW session cookie value
- **AND** neither value matches the first click's values
- **AND** both clicks' cookies are independently valid

#### Scenario: OTP and cookie are never persisted

- **WHEN** auditing every code path under `src-tauri/src/otp.rs` and the router
  sidecar source
- **THEN** no `std::fs::write`, `tokio::fs::write`, or equivalent persists the
  OTP or the cookie value
- **AND** no log line at any level emits the value field
- **AND** no environment variable carries the value across a `Command::env_clear`
  boundary

### Requirement: OTP transport via Unix control socket

The tray SHALL transport the OTP and the corresponding cookie value to the
router via a postcard-framed message on the Unix control socket at
`/run/user/<uid>/tillandsias/control.sock` (defined by capability
`tray-host-control-socket`). The message variant is
`ControlMessage::IssueWebSession { project_label: String, cookie_value: [u8; 32] }`.
The router-side socket consumer appends the cookie value to the project's
in-memory session list.

@trace spec:opencode-web-session-otp, spec:tray-host-control-socket

#### Scenario: Tray issues the cookie value to the router

- **WHEN** the tray completes OTP generation for a project named `thinking-service`
- **THEN** the tray serialises a `ControlMessage::IssueWebSession {
  project_label: "opencode.thinking-service.localhost", cookie_value: <32 bytes> }`
  envelope via `postcard::to_allocvec`
- **AND** writes the length-prefixed envelope to `/run/user/<uid>/tillandsias/control.sock`
- **AND** the router-side consumer deserialises it and pushes the cookie value
  into its `Mutex<HashMap<String, Vec<[u8; 32]>>>` keyed by the project label
- **AND** an accountability log entry records the issuance with
  `category = "router"`, `spec = "opencode-web-session-otp"`, and `cookie_value` redacted

#### Scenario: Unknown message variant is rejected at deserialise time

- **WHEN** any process writes a postcard envelope to the control socket whose
  variant is not in the typed `ControlMessage` enum
- **THEN** the router-side consumer fails the deserialise step
- **AND** the offending bytes are dropped without affecting the session table
- **AND** an accountability warning logs the deserialise failure with
  `category = "router"`, `spec = "tray-host-control-socket"`

### Requirement: Session cookie attributes

The router SHALL emit the cookie via `Network.setCookies` arguments equivalent
to the HTTP header
`Set-Cookie: tillandsias_session=<32B-base64url>; Path=/; HttpOnly; SameSite=Strict; Max-Age=86400`.
No `Secure` flag is set (the connection is plain HTTP on a loopback origin;
browsers refuse `Secure` cookies over HTTP). No `Domain` attribute is set
(defaults to the exact hostname; the cookie does not leak to sibling subdomains).

@trace spec:opencode-web-session-otp

#### Scenario: Cookie attributes match the spec

- **WHEN** the tray injects the session cookie for project `thinking-service`
  via CDP `Network.setCookies`
- **THEN** the cookie has `name = "tillandsias_session"`
- **AND** `path = "/"`
- **AND** `httpOnly = true`
- **AND** `sameSite = "Strict"`
- **AND** the expiry is `now + 86400` seconds (24 h from issue)
- **AND** `secure = false` (HTTP loopback, browsers reject Secure-on-HTTP)
- **AND** the `Domain` attribute is unset (cookie scoped to the exact hostname only)

#### Scenario: HttpOnly defeats JavaScript exfiltration

- **WHEN** any script inside the OpenCode Web UI evaluates `document.cookie` in
  the browser's JS context
- **THEN** the `tillandsias_session` cookie does not appear in the returned string
- **AND** an XSS in the upstream UI cannot read or transmit the session token

### Requirement: Multi-session concurrency

Each "Attach Here" or "Attach Another" SHALL produce an additional valid session
without invalidating any previously-issued sessions for the same project. The
router's per-project session list grows with each issue and shrinks only on
container-stack shutdown or session-table eviction. Sessions are independent —
closing one browser window does not invalidate cookies held by other windows.

@trace spec:opencode-web-session-otp

#### Scenario: Three concurrent windows on one project

- **WHEN** the user clicks Attach Here, then Attach Another twice on the same
  project, producing three browser windows
- **THEN** the router's session list for that project contains exactly three
  cookie values
- **AND** any of the three browser windows can issue requests successfully
- **AND** closing any one window leaves the other two functional

#### Scenario: Closing one window does not invalidate siblings

- **WHEN** three concurrent windows are attached to the same project and the
  user closes the first window
- **THEN** the router's session list still contains all three cookie values
  (the cookie is not server-revoked; client closure simply means the browser
  stops sending it)
- **AND** the remaining two windows' requests continue to succeed

### Requirement: Unconsumed OTP TTL

When the tray issues a session-cookie value to the router, the router SHALL
mark it as "pending" with a 60-second expiry. If no request carrying the
cookie arrives within 60 seconds, the router SHALL evict the entry from the
session list. Eviction is final — the cookie cannot be re-validated.

@trace spec:opencode-web-session-otp

#### Scenario: Unused session expires in 60 seconds

- **WHEN** the tray issues a session cookie for a project but the bundled
  Chromium fails to navigate within 60 seconds (e.g., process crashed, user
  killed it from a task manager)
- **THEN** the router evicts the cookie value from the session list at the
  60-second mark
- **AND** any subsequent request bearing that cookie returns HTTP 401
- **AND** the eviction is logged with `category = "router"`,
  `spec = "opencode-web-session-otp"`, and the value redacted

#### Scenario: Used session is not subject to the 60-second expiry

- **WHEN** the tray issues a session cookie and the browser presents it within
  the first 5 seconds
- **THEN** the router marks the cookie as "active" and clears its 60-second timer
- **AND** the cookie remains valid for the lifetime of the container stack
  (subject to the 24-hour client-side Max-Age)

### Requirement: Router-restart behavior — sessions lost

The router SHALL initialise its in-memory session table empty on every start.
If the router container is stopped and restarted (manual maintenance, image
upgrade, host crash recovery), the system SHALL treat all previously-issued
cookies as invalid and the router MUST return HTTP 401 for any request bearing
a previously-issued cookie value. The user SHALL re-attach via the tray to
obtain a fresh cookie. This is a documented limitation, not a bug.

@trace spec:opencode-web-session-otp

#### Scenario: Router restart invalidates all open sessions

- **WHEN** the user has three browser windows open against project A and the
  router container is restarted (`podman restart tillandsias-router` or
  equivalent)
- **THEN** every subsequent request from those windows returns HTTP 401
- **AND** the user resolves the situation by clicking Attach Here / Attach
  Another in the tray, which issues fresh cookies via CDP
- **AND** the previously-open browser windows can be closed and re-launched
  by the new attach (the old windows do not auto-recover)

### Requirement: Audit logging without cleartext values

Every OTP issuance and every cookie validation SHALL emit an accountability
log entry. The log entry SHALL include the project label, the operation
(`issue` / `validate-success` / `validate-fail` / `evict`), and the
`spec = "opencode-web-session-otp"` field. The OTP value, the cookie value,
and any derivative (hash, prefix, suffix) SHALL NOT appear in any log entry.

@trace spec:opencode-web-session-otp, spec:secrets-management

#### Scenario: Issue logged without value

- **WHEN** the tray issues a session cookie for a project
- **THEN** an accountability log entry records the issue event with the project
  label and `operation = "issue"`
- **AND** the log entry contains no field whose value is the cookie token, its
  hash, its base64 prefix, or any derivative

#### Scenario: Validation success and failure both logged

- **WHEN** a request carrying a cookie reaches the router
- **THEN** the router emits an accountability log entry with the project label
  and either `operation = "validate-success"` (cookie matched a session-list
  entry) or `operation = "validate-fail"` (no match)
- **AND** neither log entry contains the cookie value
- **AND** validate-fail entries do NOT include the rejected cookie value
  (logging it would let an attacker confirm a guess by reading logs)

#### Scenario: Eviction logged

- **WHEN** the router evicts an unconsumed OTP at the 60-second mark, OR
  evicts every session for a project on container-stack shutdown
- **THEN** an accountability log entry records the eviction with the project
  label and `operation = "evict"`, `reason = "ttl-expired" | "stack-stopped"`
- **AND** the log entry contains no cookie value

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — the OTP and
  the session cookie live in the ephemeral category (process memory + control
  socket); they are never written to per-project cache, project workspace, or
  shared cache.
- `cheatsheets/runtime/forge-shared-cache-via-nix.md` — confirms session-token
  material has no shared-cache surface; the single-entry-point principle does
  not extend to credentials.
- `cheatsheets/web/http.md` — cookie attribute semantics
  (`HttpOnly`, `SameSite=Strict`, `Max-Age`, no `Secure` over HTTP loopback).
- `cheatsheets/web/sse.md`, `cheatsheets/web/websocket.md` — confirm cookies
  are the standard browser-side credential vehicle for SSE and WebSocket
  sessions (OpenCode Web uses both).
- (NEW, this change) `cheatsheets/web/cookie-auth-best-practices.md` — provenance
  to MDN cookie docs and RFC 6265bis.
- `openspec/changes/tray-host-control-socket/proposal.md` — Unix-socket and
  postcard-envelope contract this requirement consumes.
- `openspec/changes/host-chromium-on-demand/proposal.md` — bundled Chromium
  with CDP that this requirement uses for cookie injection.
