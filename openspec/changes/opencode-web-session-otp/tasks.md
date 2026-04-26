# Tasks — opencode-web-session-otp

## 1. Tray: OTP generation module

- [ ] 1.1 Create `src-tauri/src/otp.rs` with public functions:
  - `generate_session_token() -> [u8; 32]` using `OsRng` from the `rand` crate.
  - `format_cookie_value(token: &[u8; 32]) -> String` (base64url, no padding).
  - `format_set_cookie_header(token: &[u8; 32], host: &str) -> String` returning
    the `Set-Cookie` header string for documentation/test parity (the actual
    cookie set goes via CDP).
- [ ] 1.2 Add `@trace spec:opencode-web-session-otp, spec:secrets-management`
  doc-comment headers on every public item.
- [ ] 1.3 Unit tests in `src-tauri/src/otp.rs::tests`:
  - 1.3.1 `generate_session_token_has_full_entropy` — generate 1000 tokens,
    assert all unique and assert each has > 250 bits of distinct-byte entropy.
  - 1.3.2 `format_cookie_value_is_url_safe` — no `+`, `/`, `=` characters.
  - 1.3.3 `format_set_cookie_header_attributes` — string contains `HttpOnly`,
    `SameSite=Strict`, `Path=/`, `Max-Age=86400`, no `Secure`, no `Domain`.

## 2. Tray↔router control-socket message variant

- [ ] 2.1 Depends on `tray-host-control-socket` capability landing first.
- [ ] 2.2 Add `IssueWebSession { project_label: String, cookie_value: [u8; 32] }`
  variant to the shared `ControlMessage` enum in
  `crates/tillandsias-control-socket/src/lib.rs` (or wherever the variant
  enumeration lives once that change ships).
- [ ] 2.3 Tray-side sender: `src-tauri/src/otp.rs::issue_to_router(project_label,
  cookie_value)` opens the control socket, serialises the postcard envelope,
  writes it length-prefixed, and waits for the router's ack.
- [ ] 2.4 Router-side handler: in the router sidecar (introduced as part of
  this change OR delegated to the future router-control-sidecar) dispatch the
  variant to `session_table::push(project_label, cookie_value)`.
- [ ] 2.5 Add `@trace spec:opencode-web-session-otp, spec:tray-host-control-socket`
  on every code path involved.

## 3. Router: dynamic.Caddyfile rewrite for `/_auth/login` + cookie matcher

- [ ] 3.1 Modify `src-tauri/src/handlers.rs::regenerate_router_caddyfile` so the
  per-project snippet emits a Caddyfile block of the shape:

      opencode.{project}.localhost:80 {
          @hassession header_regexp Cookie "tillandsias_session=([A-Za-z0-9_-]+)"
          handle @hassession {
              reverse_proxy tillandsias-{project}-forge:4096
          }
          handle {
              respond "unauthorised — open this project from the Tillandsias tray" 401
          }
      }

  Use Caddy's built-in `@hassession` matcher (no plugin required).
- [ ] 3.2 Add a per-project Caddyfile var holding the project's session-list
  validator endpoint (loopback HTTP call into the router sidecar) so the
  matcher can also confirm the cookie value is in the in-memory list — NOT
  just present. The validator endpoint runs on `127.0.0.1:<sidecar-port>`
  inside the router container.
- [ ] 3.3 Update `images/router/base.Caddyfile` to wire the sidecar admin
  endpoint and to declare the `@hassession` matcher behaviour at the
  global block level.
- [ ] 3.4 Update `images/router/entrypoint.sh` to launch the router sidecar
  alongside `caddy run`; both processes share lifetime.

## 4. Router: per-project session_tokens HashMap

- [ ] 4.1 Implement the router-side state structure:
  `Mutex<HashMap<String, Vec<SessionEntry>>>` where
  `SessionEntry { value: [u8; 32], state: Pending(deadline) | Active }`.
- [ ] 4.2 Implement `push(project_label, cookie_value)` — append a new
  `Pending` entry with `deadline = now + 60s`.
- [ ] 4.3 Implement `validate(project_label, cookie_value) -> bool` — match
  against any entry, transition `Pending` → `Active` on first match, return
  `true`.
- [ ] 4.4 Implement `evict_expired()` — periodic task (1s tick) removes
  `Pending` entries past their deadline.
- [ ] 4.5 Implement `evict_project(project_label)` called when the project's
  container stack stops.
- [ ] 4.6 Audit log every push, validate (success + failure), and evict event
  with `category = "router"`, `spec = "opencode-web-session-otp"`, value
  redacted.

## 5. Tray: CDP client integration to set cookie before navigation

- [ ] 5.1 Depends on `host-chromium-on-demand` capability landing first
  (provides the bundled Chromium binary launched with `--remote-debugging-port=<random>`).
- [ ] 5.2 Add a minimal CDP client (either `headless_chrome` crate or a small
  hand-rolled JSON-RPC client over the WebSocket exposed by Chromium) under
  `src-tauri/src/cdp.rs`.
- [ ] 5.3 Implement `attach_and_set_cookie(cdp_port: u16, target_url: &str,
  cookie_value: &str) -> Result<()>`:
  1. Connect to `ws://127.0.0.1:<cdp_port>/devtools/browser`.
  2. Discover the browser's first target via `Target.getTargets`.
  3. Attach to it via `Target.attachToTarget`.
  4. Send `Network.enable`.
  5. Send `Network.setCookies` with the canonical attribute set (Path=/,
     HttpOnly, SameSite=Strict, expires=now+86400, secure=false).
  6. Send `Page.navigate` with the project URL.
  7. Wipe the `cookie_value` String from memory after the response.
- [ ] 5.4 Unit tests with a mocked CDP server (httpmock or similar) covering:
  the cookie attribute payload structure, the navigate-after-set-cookie
  ordering, the wipe-after-success behaviour.

## 6. browser.rs: launch flow change

- [ ] 6.1 Modify `src-tauri/src/browser.rs::launch_for_project` to:
  1. Generate cookie via `otp::generate_session_token`.
  2. Send `IssueWebSession` to the router via control socket
     (`otp::issue_to_router`).
  3. Spawn bundled Chromium with `--remote-debugging-port=<random-loopback-port>`,
     `--user-data-dir=<ephemeral>`, `--app=<project-url>`.
  4. Poll the CDP endpoint with a 2-second timeout for readiness.
  5. Call `cdp::attach_and_set_cookie` BEFORE the Chromium navigates to the
     project URL (use `--app=about:blank` initially, then `Page.navigate` to
     the project URL after the cookie is set).
- [ ] 6.2 Update both call sites in `src-tauri/src/handlers.rs` (fresh attach
  and reattach branches) — both must trigger a fresh OTP issue + cookie
  injection.
- [ ] 6.3 Update browser detection: bundled Chromium becomes the only path
  (drops Safari / Firefox / OsDefault, per `host-chromium-on-demand`).
  Tombstone the old branches with a 3-release window per project convention.

## 7. Tests (unit + integration)

- [ ] 7.1 Tray unit tests (covered in 1.3 + 5.4 above).
- [ ] 7.2 Router unit tests in the sidecar:
  - 7.2.1 `validate_rejects_unknown_cookie`.
  - 7.2.2 `validate_promotes_pending_to_active`.
  - 7.2.3 `evict_expired_removes_unconsumed_after_60s`.
  - 7.2.4 `evict_project_removes_all_entries_for_label`.
  - 7.2.5 `push_supports_three_concurrent_sessions_for_one_project`.
- [ ] 7.3 Integration test (host-side, requires podman):
  - 7.3.1 Spin up a forge + router stack, issue an OTP, attempt
    `curl http://<project>.opencode.localhost:8080/` WITHOUT cookie → expect
    401.
  - 7.3.2 Same with cookie value matching the issued one → expect 200.
  - 7.3.3 Issue cookie, wait 65 s without using it, attempt request → expect
    401 (eviction worked).
  - 7.3.4 Restart router container, attempt request with previously-issued
    cookie → expect 401.
- [ ] 7.4 Audit-log tests:
  - 7.4.1 Capture the structured log output during a full attach cycle and
    assert no field contains the OTP or cookie value (regex search for the
    base64 prefix).

## 8. Documentation: cheatsheet additions

- [ ] 8.1 Create `cheatsheets/web/cookie-auth-best-practices.md` with:
  - Provenance section citing MDN
    (`https://developer.mozilla.org/en-US/docs/Web/HTTP/Cookies`) and RFC
    6265bis (`https://datatracker.ietf.org/doc/draft-ietf-httpbis-rfc6265bis/`).
  - Quick reference table of cookie attributes (HttpOnly, SameSite,
    Max-Age, Path, Domain, Secure) with effects.
  - Pattern: opaque-token cookie via CDP injection (this change's pattern).
  - Anti-patterns: storing tokens in `localStorage`; readable cookies for
    auth; missing SameSite.
  - `@trace spec:opencode-web-session-otp` annotation.
- [ ] 8.2 Update `docs/cheatsheets/secrets-management.md` to add the OTP +
  session cookie row to the "Secret types" table with a note pointing at
  this change's spec deltas.

## 9. Versioning

- [ ] 9.1 After `/opsx:archive`, run `./scripts/bump-version.sh --bump-changes`.
- [ ] 9.2 Commit with the trace URL footer per the project convention.
