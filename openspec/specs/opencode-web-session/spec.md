# opencode-web-session Specification

## Purpose

How Tillandsias runs a persistent OpenCode Web server per project, maps it to a local-only host port, and renders it in an embedded Tauri webview — including multi-session reattach semantics and shutdown guarantees.
## Requirements
### Requirement: OpenCode Web is the default session agent

The system SHALL treat `SelectedAgent::OpenCodeWeb` as the default value of `AgentConfig::selected` when no explicit choice is present in the user's configuration.

#### Scenario: Fresh install with no config file
- **WHEN** Tillandsias launches for the first time and `~/.config/tillandsias/config.toml` does not exist
- **THEN** the effective `agent.selected` value is `opencode-web`
- **AND** the Seedlings submenu shows "OpenCode Web" as the checked entry

#### Scenario: Existing install with explicit agent choice
- **WHEN** `~/.config/tillandsias/config.toml` already contains `[agent] selected = "opencode"` or `"claude"`
- **THEN** the existing choice is preserved
- **AND** the default flip does not override it

### Requirement: Per-project persistent web container

The system SHALL run at most one web-mode container per project at a time, named exactly `tillandsias-<project>-forge`, launched detached and kept alive until explicit Stop or Tillandsias shutdown.

#### Scenario: First attach creates the container
- **WHEN** the user clicks "Attach Here" on a project and no `tillandsias-<project>-forge` container is running
- **THEN** Tillandsias starts a detached podman container with that name running `opencode serve --hostname 0.0.0.0 --port 4096`
- **AND** records it in `TrayState::running` with `container_type = OpenCodeWeb`

#### Scenario: Re-attach while container already running
- **WHEN** the user clicks "Attach Here" on a project whose `tillandsias-<project>-forge` container is already running
- **THEN** no new container is created
- **AND** a new webview window is opened against the existing host port

#### Scenario: Container survives webview close
- **WHEN** the user closes a webview window for an active web container
- **THEN** the container remains running
- **AND** the tray menu still offers "Stop" for that project

### Requirement: Host port bound to 127.0.0.1 only

The system MUST publish the forge container's port 4096 to the host by binding explicitly to the loopback interface `127.0.0.1`. Binding to `0.0.0.0`, `::`, or any non-loopback interface is forbidden for web-mode containers.

#### Scenario: Port publish arg begins with 127.0.0.1
- **WHEN** Tillandsias constructs the `podman run` command for a web-mode container
- **THEN** the `-p` (or `--publish`) argument begins with `"127.0.0.1:"` before the host port
- **AND** never uses a bare `"<port>:<port>"` or `"0.0.0.0:"` form

#### Scenario: External LAN cannot reach the server
- **WHEN** a remote host on the same LAN attempts to connect to the Tillandsias host on the allocated web port
- **THEN** the connection is refused at the socket layer

### Requirement: Unique host port per concurrent web container

The system SHALL allocate a unique, unused TCP host port for each running web container, drawn from an ephemeral high range, and record it in `ContainerInfo.port_range` as a degenerate `(p, p)` pair.

#### Scenario: Two projects running simultaneously
- **WHEN** two different projects have web containers running at the same time
- **THEN** each has a distinct host port
- **AND** neither binding collides with ports already in use on the host

### Requirement: Stop tears down the web container

The system SHALL expose a per-project "Stop" tray menu action that stops the web container, removes it from `TrayState::running`, and releases its host port. Any open webview windows attached to that container MUST also be closed.

#### Scenario: User clicks Stop
- **WHEN** the user selects "Stop" for a project with a running web container
- **THEN** the container is stopped and removed
- **AND** all webview windows labeled `web-<project>-*` are closed
- **AND** the allocated host port is returned to the pool

### Requirement: Shutdown stops all web containers and closes all webviews

The system SHALL stop every running web-mode container and close every open webview window as part of `shutdown_all()`.

#### Scenario: Tillandsias quits with active web session
- **WHEN** the user quits Tillandsias with at least one web container running
- **THEN** all web containers are stopped as part of the shutdown sequence
- **AND** no `tillandsias-*-forge` container remains in `podman ps`
- **AND** all `WebviewWindow` instances are closed before the process exits

### Requirement: OpenCode Web defaults to dark theme

The forge image SHALL ship a config-overlay file `tui.json` that sets the OpenCode UI theme to a built-in dark theme (`tokyonight`). Project-specific overrides via the user's own `~/.config/opencode/tui.json` (mounted from the project workspace) SHALL continue to win over the overlay default.

#### Scenario: Fresh attach uses dark theme
- **WHEN** a user attaches to a project with no project-level OpenCode theme override
- **THEN** OpenCode reads `theme: "tokyonight"` from `~/.config/opencode/tui.json`
- **AND** the rendered TUI/web UI uses the tokyonight dark palette

#### Scenario: Project override wins
- **WHEN** the project workspace contains a `~/.config/opencode/tui.json` (mounted in)
- **THEN** that file overrides the overlay default
- **AND** the user's chosen theme is rendered

### Requirement: Proxy egress is transparent to opencode

OpenCode Web SHALL reach its default external dependencies (model registry at
`models.dev`, OpenRouter, Helicone, and the provider APIs already covered by the
Squid allowlist) without observing any proxy-induced failure. Transparency here
means: no `TCP_DENIED` responses for intended egress, no TLS errors under the
enclave CA, and no retry storms caused by intra-enclave hostnames hairpinning
through Squid.

#### Scenario: First prompt reaches the selected provider
- **WHEN** the user attaches to a project in OpenCode Web mode and sends the
  first prompt after selecting a provider (Anthropic, OpenAI, OpenRouter,
  Helicone, or any already-allowlisted provider)
- **THEN** the provider's HTTPS endpoint resolves through the proxy (CONNECT
  succeeds)
- **AND** the TLS handshake against the provider certificate completes
- **AND** the proxy log shows `TCP_TUNNEL/200` (not `TCP_DENIED/*`) for that
  destination

#### Scenario: Model registry fetch succeeds
- **WHEN** OpenCode requests the model registry from `models.dev`
- **THEN** the request reaches `models.dev:443` via the proxy CONNECT tunnel
- **AND** the response is served to OpenCode in full
- **AND** no subsequent prompt stalls on model-list resolution

### Requirement: Intra-enclave hostnames bypass the proxy

The forge container's `NO_PROXY` env SHALL include every service name reachable
on the enclave network (`inference`, `git-service`, `proxy`) plus loopback
variants (`localhost`, `127.0.0.1`, `0.0.0.0`, `::1`). Requests to any of these
destinations MUST NOT traverse Squid.

#### Scenario: Inference probe never hits the proxy
- **WHEN** OpenCode (or its wrapper) probes `http://inference:11434/api/version`
- **THEN** the Bun HTTP client sees `inference` matching `NO_PROXY` and connects
  directly on the enclave network
- **AND** the proxy log records no entry for `inference:11434`

#### Scenario: Ollama's own loopback health check stays local
- **WHEN** ollama inside the inference container probes its own listen address
  `http://0.0.0.0:11434/` or `http://127.0.0.1:11434/`
- **THEN** `NO_PROXY` in the inference container matches and the probe stays
  inside the container
- **AND** no `TCP_DENIED/403` for `0.0.0.0:11434` appears in the proxy log

### Requirement: Config overlay is applied at container start

The forge OpenCode Web entrypoint SHALL copy the host-mounted
`/home/forge/.config-overlay/opencode/config.json` to
`/home/forge/.config/opencode/config.json` and
`/home/forge/.config-overlay/opencode/tui.json` to
`/home/forge/.config/opencode/tui.json` before invoking `opencode serve`. This
ensures OpenCode reads the Tillandsias-provided config (enclave ollama
baseURL, MCP servers, instructions, dark theme) rather than the minimal stub
baked into the image at build time.

#### Scenario: Provider baseURL points to the enclave ollama
- **WHEN** the forge container starts and the entrypoint reaches the config-
  overlay step
- **THEN** `/home/forge/.config/opencode/config.json` contains
  `provider.ollama.options.baseURL` equal to `http://inference:11434/v1`
- **AND** a `GET http://127.0.0.1:<host_port>/config` request returns the
  same baseURL in the resolved provider config
- **AND** OpenCode routes ollama completions to the enclave inference
  container, not to `localhost:11434` inside the forge

#### Scenario: Config schema validates
- **WHEN** OpenCode loads the config at startup
- **THEN** the config passes schema validation (no "Configuration is
  invalid" error)
- **AND** the server transitions to listening on
  `0.0.0.0:4096` successfully
- **AND** `permission`, `instructions`, and `provider` fields conform to
  the published OpenCode schema at `https://opencode.ai/config.json`

### Requirement: Config is additive — all OpenCode defaults preserved

The overlay config SHALL NOT use `enabled_providers` or otherwise restrict
the set of providers OpenCode exposes. Every provider OpenCode ships with
(OpenCode Zen, OpenRouter, Helicone, Anthropic, OpenAI, Google, and every
other entry in OpenCode's default set) MUST remain available inside a
Tillandsias forge container. Tillandsias adds an `ollama` provider entry
pointing at the enclave inference container, in addition to — not instead
of — OpenCode's defaults.

#### Scenario: OpenCode Zen is reachable
- **WHEN** the UI queries `GET /config/providers`
- **THEN** the response contains the `opencode` provider entry with its
  default Zen models (e.g. `gpt-5-nano`, `minimax-m2.5-free`)
- **AND** the user can select a Zen model and send a prompt without
  configuration changes

#### Scenario: Ollama is ADDED, not substituted
- **WHEN** the UI queries `GET /config/providers`
- **THEN** the response contains both the default providers AND an
  `ollama` provider
- **AND** the ollama provider's `options.baseURL` is
  `"http://inference:11434/v1"`
- **AND** the ollama provider's `models` map includes the curated local
  model list (qwen2.5, qwen2.5-coder, llama3.2, etc.)

### Requirement: OpenCode state is seeded fresh per container start

The forge OpenCode Web entrypoint SHALL delete
`/home/forge/.local/share/opencode/` before invoking `opencode serve`. This
clears any stale project rows or session state from a prior run of the same
container (e.g. after a crash-restart), ensuring OpenCode's first request
creates exactly one project row — the mounted project — and no "global"
pseudo-project or orphan entries.

#### Scenario: Only the mounted project is visible on first load
- **WHEN** a fresh forge container starts and the webview loads
- **THEN** `GET /project` returns exactly one project entry
- **AND** that entry's `worktree` matches the mounted project directory
  (`/home/forge/src/<project>`)
- **AND** no entry with `id: "global"` or `worktree: "/"` is present

#### Scenario: Per-container isolation survives crashes
- **WHEN** an OpenCode Web container is force-killed mid-session and
  restarted by the tray
- **THEN** the new container starts with a fresh
  `/home/forge/.local/share/opencode/` directory
- **AND** no ghost projects from the prior run appear in the UI

### Requirement: extract_config_overlay preserves the directory inode

`extract_config_overlay` MUST write config files in place without removing
and recreating the host-side directory. Running forge containers bind-mount
`/run/user/<uid>/tillandsias/config-overlay` into `/home/forge/.config-overlay`.
If a subsequent tray action (e.g. another Attach Here) calls
`extract_config_overlay` with `remove_dir_all` + recreate, the old directory
inode is discarded and the running container's mount becomes an orphan
"deleted" entry — the mount point appears empty, MCP scripts vanish,
OpenCode's MCP client hangs waiting for `prompts/list` responses, and the
webview UI freezes on its first `/command` fetch.

#### Scenario: Concurrent attaches don't invalidate existing mounts
- **WHEN** user attaches project A, then (with project A's forge still
  running) attaches project B
- **THEN** extracting the config overlay for project B reuses the existing
  directory inode
- **AND** project A's container continues to see the MCP scripts,
  opencode config, and tui config as before
- **AND** no `//deleted` orphan mount appears in either container's
  `/proc/self/mountinfo`

### Requirement: MCP stdio servers respond to every standard method

Tillandsias-shipped MCP server scripts (`git-tools.sh`, `project-info.sh`, and any future MCPs) MUST respond to every MCP method OpenCode issues during normal operation — including `initialize`, `tools/list`, `tools/call`, `prompts/list`, `resources/list`, and `resources/templates/list`. Methods with no results SHALL return an empty-list result, not stay silent. Unknown methods SHALL return a JSON-RPC `-32601 Method not found` error with the request id.

#### Scenario: prompts/list returns empty list
- **WHEN** OpenCode queries an MCP server's `prompts/list`
- **THEN** the server responds with
  `{"jsonrpc":"2.0","id":<id>,"result":{"prompts":[]}}`
- **AND** no response takes longer than 100ms
- **AND** the UI's `/command` endpoint completes in under a second

#### Scenario: silent method handling is forbidden
- **WHEN** OpenCode calls any JSON-RPC method on our MCP server
- **THEN** the server emits exactly one JSON-RPC response line per request
- **AND** no request results in the 60s MCP client timeout
  (`MCP error -32001: Request timed out`)

### Requirement: SSE-keepalive proxy injects CSP hashes for inline scripts

The `sse-keepalive-proxy` fronting `opencode serve` SHALL rewrite the
upstream `Content-Security-Policy` header on every HTML response to add
`'sha256-<digest>'` entries to the `script-src` directive — one per inline
`<script>` tag in the body. The proxy SHALL compute each digest dynamically
on every request (no hardcoded hash) so the fix survives opencode version
upgrades that change the inline script content.

**Context:** OpenCode's embedded web UI ships a `DEFAULT_CSP` header
(`default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; …`) AND an
inline `<script id="oc-theme-preload-script">`. The CSP blocks the inline
script; the UI's theme initialization fails and users see CSP violation
errors in the browser console. Upstream tracked at
[anomalyco/opencode#21088](https://github.com/anomalyco/opencode/issues/21088);
fix exists in PR #21089 but was auto-closed on template non-compliance.
The canonical fix per CSP Level 3 is to move inline scripts to external
files. Until upstream ships that, we hash them in place — the same approach
opencode takes on its proxied path at `app.opencode.ai`. We explicitly do
NOT add `'unsafe-inline'` (CSP3 + OWASP both say that's the worst option).

#### Scenario: Inline theme preload is allowed after proxy rewrite
- **WHEN** a browser fetches `/` or any base64url-directory-scoped route
- **THEN** the response's `Content-Security-Policy` contains a `sha256-…`
  entry in `script-src` matching the digest of the
  `<script id="oc-theme-preload-script">` body
- **AND** the browser executes the inline script without CSP violations
- **AND** `document.documentElement.dataset.colorScheme` is set by the
  preload script on first paint

#### Scenario: Hashes are computed dynamically, not hardcoded
- **WHEN** auditing `sse-keepalive-proxy.js`
- **THEN** the proxy computes each script's sha256 via
  `crypto.createHash('sha256').update(body, 'utf8').digest('base64')` at
  response time
- **AND** no hash constant is hardcoded in the proxy source
- **AND** an opencode version bump that changes the inline script content
  is handled transparently on the next request

#### Scenario: 'unsafe-inline' is not introduced
- **WHEN** auditing the patched CSP header the proxy emits
- **THEN** `script-src` does NOT contain `'unsafe-inline'`
- **AND** `script-src` contains `'self'` and `'wasm-unsafe-eval'` plus one
  or more `'sha256-…'` entries

### Requirement: Native browser launch contract

Every "Attach Here" in web mode SHALL launch the bundled Chromium binary
provided by capability `host-chromium` in app-mode (single-site window,
no tabs, no URL bar) against the forge's URL. The tray SHALL resolve
the Chromium binary via the detection priority defined in
`host-chromium`'s `Detection priority — userspace first, system fallback,
hard error` requirement (userspace install → system PATH fallback →
hard error). The tray SHALL NOT launch Safari, Firefox, or any non-
Chromium-family browser; the previous Safari/Firefox/OsDefault paths
in `src-tauri/src/browser.rs` are tombstoned and removed three releases
after this change ships per the project's `@tombstone` convention.

The launch flags SHALL match the `Per-launch CDP and ephemeral profile
flags` requirement in capability `host-chromium`:
`--app=<url>`, `--user-data-dir=<ephemeral-tmpdir>`, `--incognito`,
`--no-first-run`, `--no-default-browser-check`,
`--remote-debugging-port=<random-loopback-port>`. The CDP port enables
session-cookie injection by capability `opencode-web-session-otp`.

@trace spec:opencode-web-session, spec:host-chromium-on-demand, spec:opencode-web-session-otp

#### Scenario: Bundled Chromium present — used in app-mode

- **WHEN** the user clicks Attach Here on a project AND the userspace
  Chromium install at
  `~/.local/share/tillandsias/chromium/current/chrome-<platform>/chrome`
  exists
- **THEN** the tray spawns that exact binary with
  `--app=http://opencode.<project>.localhost:8080/`,
  `--user-data-dir=<tmpdir>`, `--incognito`, `--no-first-run`,
  `--no-default-browser-check`, and `--remote-debugging-port=<random-port>`
- **AND** a borderless single-site window opens
- **AND** the spawned process is a direct child of the tray (or its
  launch helper), not visible as a tab in any existing browser session

#### Scenario: Userspace install absent — system Chromium fallback

- **WHEN** the userspace install does not exist (e.g., user installed
  via direct AppImage download and has not yet re-run `install.sh`)
  AND `which chromium` resolves to `/usr/bin/chromium`
- **THEN** the tray spawns `/usr/bin/chromium` with the same flag set
- **AND** an info-level accountability log entry records the fallback
  with `category = "browser-detect"`,
  `spec = "host-chromium-on-demand"`, `using = "system-fallback"`

#### Scenario: No Chromium present — hard error, no UI prompt

- **WHEN** neither the userspace install nor any system Chromium-family
  binary is available
- **THEN** the attach fails with the message
  `Chromium not installed. Re-run the installer or run "tillandsias --install-chromium".`
- **AND** no dialog is shown
- **AND** no tray menu item is added
- **AND** no background HTTP download is triggered from the tray

#### Scenario: Safari, Firefox, OsDefault paths are removed

- **WHEN** auditing `src-tauri/src/browser.rs` after the three-release
  tombstone window for this change has elapsed
- **THEN** the `BrowserKind::Safari`, `BrowserKind::Firefox`, and
  `BrowserKind::OsDefault` variants and their launch arms are deleted
- **AND** during the tombstone window each removed branch carries a
  `// @tombstone superseded:host-chromium-on-demand` comment naming
  the release in which it was removed and the release after which it
  is safe to delete

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

### Requirement: Tray does not track or kill browser windows

The tray SHALL NOT track the PIDs of spawned browser processes for the
purpose of forcing them closed. Browser windows are the user's property.
When the tray's Quit menu runs `shutdown_all()`, the tray stops forge
containers and tears down the enclave network; any still-open browser
window pointing at a torn-down forge naturally transitions to a
connection-refused state, and the user closes it manually.

#### Scenario: Tray Quit stops containers, leaves browser alone
- **WHEN** the user clicks Tray → Quit with a browser window still
  open pointing at a forge
- **THEN** `shutdown_all()` runs (stops containers, removes them,
  destroys the enclave network)
- **AND** the tray process exits
- **AND** the user's browser window is not sent SIGTERM/SIGKILL
- **AND** the browser window shows the browser's own
  "This site can't be reached" page on next reload

### Requirement: SSE-keepalive proxy injects bootstrap script

The Node proxy fronting `opencode serve` SHALL inject a single classic
`<script>` tag as the first child of `<head>` in HTML responses. The
injected script seeds `localStorage.opencode-color-scheme = 'dark'` if
unset. The proxy SHALL compute the sha256 digest of the injected script
body and append `'sha256-<b64>'` to the `script-src` directive of the
upstream `Content-Security-Policy` header — alongside any hashes the
proxy already computes for opencode's own inline scripts.

The injected script MUST NOT:

- Call `Notification.requestPermission()` (requires a user gesture per
  the Notifications API spec; attempting it from a non-gesture context is
  a no-op that pollutes the console).
- Override `Notification.permission` or monkey-patch any browser API.
- Depend on Tauri IPC or any non-standard global.

The script MUST be synchronous and side-effect-only (no `type=module`,
no `defer`, no `async`) so it executes before OpenCode's
`/oc-theme-preload.js` external script loads.

#### Scenario: Dark theme on first paint
- **WHEN** the browser loads an HTML response through the proxy and
  `localStorage.opencode-color-scheme` is not set
- **THEN** the injected bootstrap script runs synchronously and sets it
  to `'dark'` before any other script
- **AND** OpenCode's `/oc-theme-preload.js` reads `'dark'` and paints
  the dark palette on first frame
- **AND** no light-theme flash is visible

#### Scenario: Bootstrap hash in CSP
- **WHEN** the proxy emits the patched response
- **THEN** the `Content-Security-Policy` header's `script-src` directive
  contains `'sha256-<b64>'` matching the UTF-8 SHA-256 of the bootstrap
  body
- **AND** the browser executes the bootstrap without CSP violations

### Requirement: Proxy drops the `Origin` header on upstream requests

The Node proxy SHALL strip the `Origin` header from requests it forwards
to `opencode serve`. OpenCode's `CorsMiddleware` is a strict exact-string
allowlist (`http://localhost:<port>`, `http://127.0.0.1:<port>`, plus
hardcoded tauri origins and `*.opencode.ai`). Arbitrary project subdomains
on `.localhost` do not match. Dropping `Origin` bypasses the allowlist
entirely without requiring a per-project config write.

#### Scenario: `<project>.localhost` origin reaches the server
- **WHEN** a browser tab at `http://myapp.localhost:17000/` issues a
  fetch to `/api/something`
- **THEN** the proxy forwards the request to upstream without the
  `Origin` header
- **AND** OpenCode serves a normal response (no CORS block)
- **AND** the response does not carry `Access-Control-Allow-Credentials`
  (dropping Origin means no CORS negotiation runs)

### Requirement: PWA install is explicitly disabled

The proxy SHALL prevent every Tillandsias-served page from being
installed as a Progressive Web App. Concretely:

1. The proxy SHALL remove every `<link rel="manifest" …>` tag from HTML
   responses.
2. The proxy SHALL respond with HTTP 404 to GET requests for any of:
   `/site.webmanifest`, `/manifest.json`, `/manifest.webmanifest`,
   `/sw.js`, `/service-worker.js`, `/worker.js`.
3. The proxy SHALL add `Service-Worker-Allowed: none` to HTML responses
   so any future service-worker registration is pre-rejected by the
   browser.

PWA install breaks the ephemeral contract — an installed PWA retains
IndexedDB/Cache/SW state across container lifetimes and survives the
user's expectation that `podman rm` resets everything.

#### Scenario: No install button in Chrome / Edge
- **WHEN** the user loads an OpenCode session in Chrome/Edge
- **THEN** the URL-bar "Install" icon never appears
- **AND** DevTools → Application → Manifest shows "No manifest detected"

#### Scenario: Manifest endpoints are 404
- **WHEN** any request hits `/site.webmanifest`, `/manifest.json`, or
  `/manifest.webmanifest`
- **THEN** the proxy responds with HTTP 404 (not 502, not passthrough)

#### Scenario: Service worker registration blocked
- **WHEN** any script attempts
  `navigator.serviceWorker.register('/sw.js')`
- **THEN** the proxy's 404 on the script path causes the registration
  promise to reject
- **AND** no worker is installed on the browser's per-origin registry

### Requirement: No pre-grant of Notification permission from JS

The tray and proxy SHALL NOT attempt to programmatically grant
Notification permission via `Object.defineProperty(Notification, 'permission', …)`,
overriding `requestPermission`, or similar monkey-patching. The
Notifications API spec requires a user gesture for every permission
grant; the native browser's built-in permission UI is the correct,
unsurprising flow.

#### Scenario: First notification prompts the user
- **WHEN** OpenCode calls `Notification.requestPermission()` in response
  to a user action (e.g. a "Send" click)
- **THEN** the browser's native permission prompt appears in its standard
  location (Chrome URL-bar badge, Firefox doorhanger, Safari dialog)
- **AND** the user's answer persists across sessions per the browser's
  per-origin policy
- **AND** the UI remains interactive while the prompt is open (not modal
  over the whole page)

#### Scenario: No monkey-patching in source
- **WHEN** auditing `src-tauri/src/browser.rs` and
  `images/default/sse-keepalive-proxy.js`
- **THEN** no code overrides `Notification.permission`
- **AND** no code replaces `Notification.requestPermission`

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
- `cheatsheets/web/cookie-auth-best-practices.md` — provenance
  to MDN cookie docs and RFC 6265bis.
- `openspec/changes/tray-host-control-socket/proposal.md` — Unix-socket and
  postcard-envelope contract this requirement consumes.
- `openspec/changes/host-chromium-on-demand/proposal.md` — bundled Chromium
  with CDP that this requirement uses for cookie injection.

