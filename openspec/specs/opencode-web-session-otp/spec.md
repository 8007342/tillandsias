<!-- @trace spec:opencode-web-session-otp -->
# opencode-web-session-otp Specification

## Status

active
promoted-from: openspec/changes/archive/2026-04-27-opencode-web-session-otp/
annotation-count: 29

## Purpose

Provide application-layer authentication for OpenCode Web sessions launched from the tray. Generates a one-time-password (OTP) per browser window, communicates it to the router via a control channel, and enforces session-cookie validation on all requests. This defence-in-depth mechanism complements the loopback-only network bind to close per-host-user attack surface against compromised browser extensions, sibling processes, and malicious local applications.

## Requirements

### Requirement: Per-Attach OTP Generation and Delivery

On each "Attach Here" or "Attach Another" action, the tray MUST:

1. Generate a 256-bit random OTP using the OS CSPRNG (`getrandom` syscall via the `rand` crate's `thread_rng`)
2. Base64-encode the OTP for transport
3. Build an auto-submitting HTML form containing the encoded OTP
4. Launch Chromium with `--app=data:text/html;base64,<encoded-form>` (the form is embedded as a data URI)
5. Pass the OTP to the router via the control-socket channel (`tray-host-control-socket` spec)

The OTP MUST **never** touch disk: not in logs, not in tray state files, not in the data: URL after consumption. The tray drops the in-memory copy after handing it to Chromium.

#### Scenario: User clicks "Attach Here"
- **WHEN** user selects "Attach Here" for a project
- **THEN** tray MUST generate a new OTP in memory
- **AND** router MUST be notified of the OTP (mapped to the project's host label)
- **AND** Chromium MUST launch with a form that will auto-POST the OTP
- **AND** the OTP MUST NOT be exposed in any log or menu state

### Requirement: Router-Side OTP Validation and Cookie Issuance

The router (Caddy) MUST:

1. Expose an `_auth/login` POST endpoint that accepts the OTP form submission
2. Validate the OTP against the stored value for the project
3. Issue an HttpOnly + SameSite=Strict + Path=/ session cookie with a separate random value (independent of the OTP)
4. 302-redirect to `/` to load the app
5. Immediately evict the OTP from memory (single-use — not replayable)

All subsequent requests to `opencode.<project>.localhost/` MUST require a valid session cookie (unless the OTP POST is in flight).

#### Scenario: Browser form submission
- **WHEN** the embedded form auto-submits to the router's `_auth/login` endpoint
- **THEN** router MUST validate the OTP
- **AND** MUST issue a new session cookie
- **AND** MUST erase the OTP from memory
- **AND** MUST 302-redirect to the app root
- **AND** subsequent requests MUST carry the cookie automatically (opencode-web never sees the OTP)

### Requirement: Cookie Shape and Lifetime

The session cookie MUST have the following attributes:

- **Name**: `tillandsias_session`
- **Value**: 32 random bytes (independent random value, not derived from OTP)
- **Path**: `/`
- **HttpOnly**: true (prevents JavaScript access)
- **SameSite**: Strict (prevents cross-site cookie transmission)
- **Lifetime**: same as the container stack (evicted on stack shutdown)

A compromised OTP after consumption MUST NOT leak the session token because they are separate random values.

#### Scenario: Cookie is stolen after OTP consumption
- **WHEN** an attacker gains the OTP value after the cookie is issued
- **THEN** the OTP MUST be already invalid (evicted from router memory)
- **AND** the attacker MUST NOT be able to forge the session cookie (it is a separate random value)
- **AND** the attacker MUST NOT be able to replay the OTP (single-use)

### Requirement: Multi-Window Reattachment

When the user clicks "Attach Another" (opening a second window to the same project):

1. A new OTP MUST be generated
2. A new browser window MUST launch with the new OTP form
3. The new window MUST go through the same `_auth/login` POST flow and get a cookie
4. Existing windows' cookies MUST remain valid (they do NOT expire; each window manages its own cookie)

Multiple browser windows CAN have independent cookies for the same project session simultaneously.

#### Scenario: User opens a second window via "Attach Another"
- **WHEN** user clicks "Attach Another" for a running project
- **THEN** a new OTP MUST be generated (independent of the first)
- **AND** a new browser window MUST open with a new form submission
- **AND** the new window MUST get its own session cookie
- **AND** the first window's cookie MUST remain valid and operational

### Requirement: Secrets Management Integration

OTP generation and validation MUST be governed by the `secrets-management` spec:

- OTP is classified as a managed secret (same class as GitHub tokens)
- MUST never be written to persistent storage
- MUST use loopback-only transport (over Unix socket to router, not exposed to network)
- Accountability log MUST track OTP generation and validation without recording the value itself
- MUST be evicted from memory immediately after use (single-use TTL)

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:credential-isolation` — Verify OTP is never persisted and only valid for single use

Gating points:
- OTP generated with cryptographically strong randomness (OS CSPRNG)
- OTP embedded in data: URI form (not logged, not on disk)
- OTP passed to router via control socket (loopback only)
- Router accepts OTP at `_auth/login` POST endpoint
- Router issues HttpOnly + SameSite=Strict session cookie (independent random value)
- OTP evicted from memory after first use; second use returns 403 Forbidden
- Session cookie valid for remainder of container stack lifetime
- Multiple windows can attach with independent OTPs and cookies
- Stolen OTP after consumption does not yield session cookie (separate random values)

## Supersedes

This spec replaces `opencode-web-session` as of v0.1.260513. The legacy spec (Tauri webview-based approach) is kept as a tombstone for historical traceability. The OTP-based session with control socket validation is now the authoritative session mechanism for OpenCode Web.

## Sources of Truth

- `cheatsheets/runtime/forge-container.md` — the forge runtime contract this OTP layer protects
- `cheatsheets/runtime/networking.md` — confirms the loopback-only bind that makes OTP-over-HTTP acceptable
- `cheatsheets/web/http.md` — cookie attributes and Set-Cookie semantics for `HttpOnly` + `SameSite=Strict`
