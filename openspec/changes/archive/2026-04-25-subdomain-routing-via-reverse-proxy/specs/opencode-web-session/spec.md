## MODIFIED Requirements

### Requirement: Native browser URL format uses `*.localhost` subdomains, no path segment

The webview-replacement URL SHALL be
`http://<project>.opencode.localhost/` — hostname carries the project
identity and the service identifier, path is bare `/`. `<project>` is
the sanitized project name (lowercase alphanumeric + hyphen).

The legacy form `http://<project>.localhost:<host_port>/` (with an
allocated random port) is **deprecated** and removed once the router
container is operational. Port `80` is always implicit. The router
container at `127.0.0.1:80` does the host-side mapping.

Rationale: hostnames of the form `*.localhost` are hardcoded to
loopback in Chromium (since M64), Firefox (since 84), and
systemd-resolved (since v245); no `/etc/hosts` entries are required.
The `<service>` segment (`opencode`, `flutter`, `vite`, etc.)
distinguishes multiple kinds of server per project — agent-spawned
dev servers and tray-managed sessions can coexist on the same project
name without port collisions.

OpenCode's `InstanceMiddleware` determines the project directory via
`?directory=` → `x-opencode-directory` header → `process.cwd()`. The
forge entrypoint `cd`s into `$PROJECT_DIR` before launching
`opencode serve`, so `process.cwd()` is always the mounted project's
absolute path. The hostname identifies the project; the SPA handles
client-side routing from `/` onward.

#### Scenario: URL is hostname-only — no encoded path, no port
- **WHEN** the tray constructs the launch URL for a project named
  `thinking-service`
- **THEN** the URL is exactly
  `http://thinking-service.opencode.localhost/`
- **AND** the URL contains no port number
- **AND** the URL contains no base64-encoded path segment
- **AND** the URL contains neither `127.0.0.1` nor a bare `localhost:`

#### Scenario: Subdomain is a secure context
- **WHEN** the browser loads `http://<project>.opencode.localhost/`
- **THEN** `window.isSecureContext` returns `true` (per W3C Secure
  Contexts §3.1)
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
- **AND** `.localhost` subdomains resolve via systemd-resolved /
  glibc-myhostname / browser hardcoding

#### Scenario: Router binds loopback only — never reachable from LAN
- **WHEN** the tray starts the router container
- **THEN** the router SHALL bind to `127.0.0.1:80` on the host, NOT
  `0.0.0.0:80`
- **AND** it SHALL NOT be reachable from any other host on the LAN
- **AND** it SHALL NOT be reachable from any external network
- **AND** an external attempt to connect to the user's LAN IP on
  port 80 SHALL be rejected at the host kernel level (no listener)
