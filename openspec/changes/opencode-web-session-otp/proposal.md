## Why

OpenCode Web today is reachable by **any** local process or browser tab on the user's machine — anything that knows the URL `http://<project>.opencode.localhost:8080/` can connect. While the listener is loopback-only (rejected from LAN/Internet), there's no defence against:

- A compromised browser extension reading the URL from another tab and opening a sibling session.
- Any other CLI process on the host (`curl http://java.opencode.localhost:8080/`) interacting with the agent's session.
- A malicious app on the same user account discovering the URL via `/proc/<pid>/cmdline` of the chromium process.

The user wants to **tighten this to "only browser windows opened by the Tillandsias tray have access"**. The chosen mechanism: a one-time-password (OTP) generated per container-stack launch, treated as a SECRET (per `secrets-management` spec — never at rest, ephemeral, one-time, minimal exposure), forwarded to the chrome window via POST as the window opens. Only that window's cookie jar then carries the session cookie that subsequent requests need.

This is defence-in-depth: the loopback bind is the network-layer guarantee; the OTP is the application-layer guarantee that the *legitimate consumer* — the tray-launched browser window — is the one talking to opencode-web.

## What Changes

- **NEW** Per-attach OTP: the tray generates a 256-bit random OTP at the moment of "Attach Here" / "Attach Another", in memory only. The OTP is passed to the router (Caddy) via its admin-API on `localhost:2019` (already loopback-only, container-internal) and stored against the project's host label. The router rejects requests to `<project>.opencode.localhost:8080/` that don't carry a valid session cookie OR a valid OTP form-POST.
- **NEW** Browser launch flow changes from `chromium --app=http://...:8080/` to `chromium --app=data:text/html;base64,<encoded HTML>`. The decoded HTML contains an auto-submitting form that POSTs the OTP to `http://<project>.opencode.localhost:8080/_auth/login`. The router validates the OTP, sets an HttpOnly + SameSite=Strict + Path=/ session cookie, and 302-redirects to `/`. Subsequent requests carry the cookie automatically — opencode-web never sees the OTP.
- **NEW** OTP lifetime: single-use. After the cookie is issued, the OTP is wiped from router memory and cannot be replayed. New "Attach Another" generates a NEW OTP and a NEW form-POST, but the existing window's cookie continues to work for the lifetime of the container stack.
- **NEW** OTP secrecy: OTP is generated with the OS CSPRNG (`getrandom` syscall via the `rand` crate's `thread_rng`). It NEVER touches disk: not in logs, not in tray state files, not in the data: URL after consumption (the tray drops the in-memory copy after handing it to chromium). The router stores it in a `Mutex<HashMap<String, [u8; 32]>>` keyed by project host label, evicted on first successful POST or container shutdown.
- **NEW** Cookie shape: `tillandsias_session=<32-byte-random>; Path=/; HttpOnly; SameSite=Strict`. Cookie value is independent of the OTP (separate random) so OTP compromise after consumption doesn't leak the session token.
- **MODIFIED** `subdomain-routing-via-reverse-proxy` (delta on `opencode-web-session`): router config gains an `_auth/login` POST endpoint and a session-cookie validator on every other path. Caddy supports both natively via `request_header` matchers and the built-in `cookie` directive — no plugins needed.
- **MODIFIED** `secrets-management` spec extension: OTP is registered as a managed-secret class with the same handling rules as GitHub tokens (loopback-only transport, never at rest, accountability log without value).

## Capabilities

### New Capabilities
- `opencode-web-session-otp`: per-attach one-time-password mechanism — generation, transport, validation, lifetime.

### Modified Capabilities
- `opencode-web-session`: browser launch URL becomes a `data:` URL containing an auto-submit form; the underlying app URL only loads after cookie issuance.
- `subdomain-routing-via-reverse-proxy`: router enforces session-cookie validation on every request to `<project>.opencode.localhost:8080`; bare requests without a cookie OR a valid `_auth/login` POST are rejected with 401.
- `secrets-management`: OTP joins the managed-secret class (same accountability rules as GitHub tokens).

## Impact

- **Tray** (`src-tauri/src/`):
  - New module `src-tauri/src/otp.rs` — generates OTP, base64-encodes, builds the data: URL HTML, hands the OTP to the router via its admin API.
  - `browser.rs::launch_for_project` — opens chromium with the new `--app=data:text/html;base64,...` URL instead of the bare subdomain URL.
  - `handlers.rs::handle_attach_web` — calls into `otp.rs` after the forge is running, before launching the browser. Same for the reattach branch.
- **Router** (`images/router/`):
  - `base.Caddyfile` — adds the `_auth/login` route, the cookie matcher, and the 401 fallback for unauthenticated requests.
  - New endpoint on the Caddy admin API (default `127.0.0.1:2019` inside the container, NOT exposed to the host) for the tray to POST the OTP. Or simpler: tray writes the OTP into a per-project file mounted into the router's `/run/router/otps/<project>` and a custom Caddy directive consults the file. **Decision needed**: admin API vs file-on-disk. Trade-off captured in `design.md`.
- **Forge entrypoints**: NO changes. opencode-web sees only the cookie-validated traffic; it doesn't know the OTP exists.
- **Browser detection** (`browser.rs::detect_browser`): unchanged. Chromium / Firefox / Safari / OS-default all support `--app=data:` (Chromium) or equivalent file:// hand-off (Firefox needs a tmpfile route; Safari needs a tmpfile too). Cross-browser table in `design.md`.
- **Tests**:
  - `src-tauri/src/otp.rs::tests` — pure-function tests for OTP generation (entropy, encoding) and HTML-form construction (correct action URL, correct project label, escaping).
  - `images/router/` integration: not unit-testable in this repo; smoke-tested manually on first build.
- **Performance**: one extra POST + redirect per "Attach Here" / "Attach Another" — adds ~5–20 ms before the app loads.
- **Security**: improves significantly. Loopback-bind already restricted external attackers; OTP closes the per-host-user attack surface.

## Sources of Truth

- `cheatsheets/runtime/forge-container.md` — the forge runtime contract this OTP layer protects.
- `cheatsheets/runtime/networking.md` — confirms the loopback-only bind that makes OTP-over-HTTP acceptable.
- `cheatsheets/web/http.md` — cookie attributes and Set-Cookie semantics for `HttpOnly` + `SameSite=Strict`.
- (Future) `cheatsheets/web/cookie-auth.md` — TBD; should be added in a follow-up cheatsheet wave with proper provenance per the new methodology.

## Open Questions (resolve in design.md before /opsx:apply)

- **Admin API vs file-on-disk for OTP transport tray→router**: admin API is cleaner but requires Caddy plugin or `caddy-jwt`-style extension; file-on-disk is dumber but POSIX-portable. Probably file-on-disk for v1.
- **Reattach behaviour**: when the user clicks "Attach Another", do we (a) reuse the existing browser's cookie (no new OTP, just open a sibling browser pointed at the existing session) or (b) generate a new OTP per window (each window has its own session). Spec drafts (a) for v1 because it matches the "multiple windows of the same session" semantics opencode-web already supports, but (b) is more secret-tight.
- **Firefox + Safari `--app=data:`**: needs verification. Firefox `--app` mode (kiosk-via-extension) may strip data: URLs; tested only in Chromium. If Firefox/Safari are blocked, fall back to a per-attach tmpfile served at `file:///run/user/<uid>/tillandsias/launcher-<random>.html` that auto-deletes after open.
