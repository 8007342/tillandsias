# opencode-web-session delta — host-browser-mcp

## ADDED Requirements

### Requirement: Forge agents can drive sibling project windows via host MCP

Agents running inside a project's forge container SHALL be able to
open, inspect, and drive browser windows for any of that project's
sibling services exposed under `*.<project>.localhost:8080` (per the
host-side router) by invoking the host-resident
`tillandsias-browser-mcp` server's tools. The MCP server SHALL be the
ONLY mechanism by which forge agents launch host-side browser windows.

The existing OTP cookie + router validation flow defined by
`opencode-web-session-otp` SHALL continue to apply to MCP-launched
windows: when the MCP spawns a chromium process for an
allowlisted URL whose host matches a router-fronted service, the tray
SHALL inject the per-window session cookie via CDP `Network.setCookies`
BEFORE the navigation, exactly as for user-initiated "Attach Here"
launches.

@trace spec:opencode-web-session, spec:host-browser-mcp, spec:opencode-web-session-otp

#### Scenario: MCP-launched window gets the OTP cookie

- **WHEN** an agent calls
  `browser.open({ url: "http://web.acme.localhost:8080/" })`
  and the URL passes the allowlist
- **THEN** the tray issues a fresh OTP via the router control-socket
  pipeline before the chromium process navigates
- **AND** CDP `Network.setCookies` runs BEFORE `Page.navigate` against
  the project URL
- **AND** the window's first request to the router carries the cookie
  and receives 200 (not 401)

### Requirement: opencode.<project>.localhost is denied to MCP

The `opencode.<project>.localhost:8080` host SHALL never be opened by
the MCP server, regardless of which forge container makes the call.
The denial SHALL be enforced at the allowlist layer of
`host-browser-mcp` (which this delta cross-references) and SHALL apply
even when the requesting forge belongs to the same project as the
opencode UI.

This requirement formalises the proposal's critical rule: agents may
not drive their own UI; they may drive sibling project services.

@trace spec:opencode-web-session, spec:host-browser-mcp

#### Scenario: Agent in project acme cannot open its own opencode UI

- **WHEN** an agent in project `acme` calls
  `browser.open({ url: "http://opencode.acme.localhost:8080/" })`
- **THEN** the call is rejected with `URL_NOT_ALLOWED`
- **AND** no chromium process is spawned
- **AND** the agent's own opencode UI session is unaffected (its
  existing windows continue to function for the user)

## Sources of Truth

- `cheatsheets/web/cookie-auth-best-practices.md` — OTP cookie shape
  this requirement reuses for MCP-launched windows. (Introduced by
  `opencode-web-session-otp`.)
- `cheatsheets/web/cdp.md` — `Network.setCookies` + `Page.navigate`
  ordering. (NEW, this change.)
- `cheatsheets/web/mcp.md` — MCP tool surface this delta references.
  (NEW, this change.)
