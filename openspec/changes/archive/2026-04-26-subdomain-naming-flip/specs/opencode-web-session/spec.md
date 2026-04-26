## MODIFIED Requirements

### Requirement: Native browser URL format uses `*.localhost` subdomains, no path segment

The webview-replacement URL SHALL be
`http://opencode.<project>.localhost:8080/` — the service identifier
(`opencode`) is the LEFTMOST label, followed by the project name. This
ordering groups all services for one project under a single
`*.<project>.localhost` namespace so that future additions like
`web.<project>.localhost` (Flutter dev server), `dashboard.<project>.localhost`
(agent UI), or `www.<project>.localhost` (static preview) sort visually
together when the user has multiple projects active.

The host-side router listens on TCP port `8080` because rootless podman
cannot bind to ports below `net.ipv4.ip_unprivileged_port_start` (default
`1024` on Fedora and most distros). `<project>` is the sanitized project
name (lowercase alphanumeric + hyphen). The path is bare `/` — no
base64-encoded directory segment.

The legacy form `http://<project>.localhost:<host_port>/` (with an
allocated random port published per forge) AND the deprecated
`http://<project>.opencode.localhost:8080/` (project-name-leftmost shape)
are both removed. The router container fronts every project on a single
host port. The internal Caddy listener inside the router stays on port
`:80` (which is allowed inside the container's user namespace); only the
host-side publish moves to `8080`.

Rationale: hostnames of the form `*.localhost` are hardcoded to loopback
in Chromium (since M64), Firefox (since 84), and systemd-resolved (since
v245); no `/etc/hosts` entries are required. The depth of subdomains does
not affect this — `opencode.java.localhost` resolves to loopback exactly
like `java.opencode.localhost` did. The `<service>` segment (`opencode`,
`web`, `dashboard`, `www`, etc.) distinguishes multiple kinds of server
per project — agent-spawned dev servers and tray-managed sessions can
coexist on the same project name without port collisions.

OpenCode's `InstanceMiddleware` determines the project directory via
`?directory=` → `x-opencode-directory` header → `process.cwd()`. The
forge entrypoint `cd`s into `$PROJECT_DIR` before launching
`opencode serve`, so `process.cwd()` is always the mounted project's
absolute path. The hostname identifies the project; the SPA handles
client-side routing from `/` onward.

#### Scenario: URL is service-leftmost, then project, then port :8080
- **WHEN** the tray constructs the launch URL for a project named
  `thinking-service`
- **THEN** the URL is exactly
  `http://opencode.thinking-service.localhost:8080/`
- **AND** the URL has `opencode` as the leftmost label and `thinking-service` immediately to its right
- **AND** the URL ends with `:8080/` (the rootless-port-friendly host bind)
- **AND** the URL contains no base64-encoded path segment
- **AND** the URL contains neither `127.0.0.1` nor a bare `localhost:`

#### Scenario: Subdomain is a secure context
- **WHEN** the browser loads `http://opencode.<project>.localhost:8080/`
- **THEN** `window.isSecureContext` returns `true` (per W3C Secure
  Contexts §3.1; loopback origins are secure regardless of port or subdomain depth)
- **AND** Notification, WebCrypto, clipboard, and service-worker APIs
  treat the origin as secure despite plain HTTP

#### Scenario: Project registration falls back to CWD
- **WHEN** the browser issues the first API request to the forge
  (`/config`, `/project`, etc.)
- **AND** the request has no `?directory=` query, no
  `x-opencode-directory` header, no `:dir` route param
- **THEN** OpenCode's `InstanceMiddleware` falls back to
  `process.cwd()`
- **AND** the resolved directory is `/home/forge/src/<project>`
  (the forge entrypoint's CWD)
- **AND** the mounted project registers as OpenCode's active project

#### Scenario: No sudo, no /etc/hosts
- **WHEN** installing or running Tillandsias on a fresh Fedora /
  Silverblue / Ubuntu / macOS system
- **THEN** no entry is added to `/etc/hosts`
- **AND** no `sudo` is invoked
- **AND** no host-level sysctl is changed (the `:8080` host port avoids the
  `ip_unprivileged_port_start` restriction without requiring privilege)
- **AND** `*.localhost` subdomains resolve via systemd-resolved /
  glibc-myhostname / browser hardcoding regardless of subdomain depth

#### Scenario: Router binds loopback only — never reachable from LAN
- **WHEN** the tray starts the router container
- **THEN** the router SHALL bind to `127.0.0.1:8080` on the host, NOT
  `0.0.0.0:8080` and NOT `127.0.0.1:80` (which rootless podman cannot bind)
- **AND** it SHALL NOT be reachable from any other host on the LAN
- **AND** it SHALL NOT be reachable from any external network
- **AND** an external attempt to connect to the user's LAN IP on
  port 8080 SHALL be rejected at the host kernel level (no listener)

#### Scenario: Router internal Caddy listener still binds :80
- **WHEN** the router container starts
- **THEN** Caddy inside the container SHALL listen on `:80` (allowed inside
  the container's user namespace)
- **AND** the Containerfile and `base.Caddyfile` SHALL NOT change to a
  different internal port — only the host-side `-p 127.0.0.1:8080:80` mapping moves

#### Scenario: Caddyfile route uses the new key shape
- **WHEN** `regenerate_router_caddyfile` writes routes to `dynamic.Caddyfile`
- **THEN** each route's site address is `opencode.<project>.localhost:80` (NOT `<project>.opencode.localhost:80`)
- **AND** the upstream `reverse_proxy` target is unchanged (`tillandsias-<project>-forge:4096`)

#### Scenario: Future services slot under the same project namespace
- **WHEN** Tillandsias adds a future service like `web` for a Flutter dev server
- **THEN** the URL pattern `web.<project>.localhost:8080/` SHALL be reachable via the same router
- **AND** `*.<project>.localhost:8080` SHALL serve as the project's whole subdomain namespace
- **AND** the browser-MCP allowlist (per the `host-browser-mcp` capability) SHALL accept `*.<project>.localhost:8080` minus `opencode.<project>.localhost:8080` (the latter is the agent's own UI, not under agent control)

## Sources of Truth

- `cheatsheets/runtime/networking.md` (DRAFT) — `*.localhost` loopback resolution at any subdomain depth.
- `cheatsheets/agents/opencode.md` (DRAFT) — URL examples updated to the new shape in this change.
