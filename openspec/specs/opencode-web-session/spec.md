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

Every "Attach Here" in web mode SHALL launch the user's native browser
in app-mode (single-site window, no tabs, no URL bar) against the forge's
URL. The tray MUST detect the browser in the following order, using the
first match:

1. Safari (`open -a Safari`) on macOS.
2. Chrome / Chromium / Edge via the platform binary paths, in order:
   `google-chrome`, `chromium`, `chrome`, `microsoft-edge`, `msedge`.
3. Firefox (`firefox`).
4. OS default browser via `xdg-open` (Linux), `open` (macOS), `start`
   (Windows).

For Chromium-family browsers, the launch arguments SHALL include
`--app=<url>` (app-mode) and `--user-data-dir=<per-project-tmpdir>`
(isolated profile). For Firefox, `--new-instance --profile <per-project-tmpdir> --no-remote <url>`.
Safari does not support app-mode and is launched with `open -n -a Safari <url>`.

#### Scenario: Chrome installed — app-mode window
- **WHEN** the user clicks Attach Here and `google-chrome` (or `chromium`,
  `chrome`, `microsoft-edge`, `msedge`) is in `PATH`
- **THEN** the tray spawns the browser with
  `<bin> --app=http://<project>.localhost:<port>/<base64dir>/ --user-data-dir=<tmpdir>`
- **AND** a borderless single-site window opens
- **AND** the browser process is a direct child of the tray (or of its
  launch helper), not visible as a tab in any existing browser session

#### Scenario: Firefox installed, Chrome absent
- **WHEN** `google-chrome`/`chromium`/`chrome`/`microsoft-edge`/`msedge`
  are not in `PATH` and `firefox` is
- **THEN** the tray spawns Firefox with
  `--new-instance --profile <tmpdir> --no-remote <url>`
- **AND** a fresh Firefox window opens (Site-Specific Browser mode)

#### Scenario: Only default browser available
- **WHEN** none of Safari/Chrome/Chromium/Edge/Firefox are detected
- **THEN** the tray falls back to the platform default launcher
  (`xdg-open`, `open`, or `start`) with the URL
- **AND** a regular browser window/tab opens pointing at the URL

#### Scenario: Safari on macOS — preferred
- **WHEN** the platform is macOS
- **THEN** Safari is tried first, via `open -n -a Safari <url>`
- **AND** if the launch succeeds, no Chromium/Firefox branch runs

### Requirement: Native browser URL format uses `*.localhost` subdomains, no path segment

The webview-replacement URL SHALL be
`http://<project>.localhost:<host_port>/` — hostname carries the
project identity, path is bare `/`. `<project>` is the sanitized
project name (lowercase alphanumeric + hyphen); `<host_port>` is the
loopback-only port the tray allocated for the forge.

Rationale: hostnames of the form `*.localhost` are hardcoded to
loopback in Chromium (since M64), Firefox (since 84), and
systemd-resolved (since v245); no `/etc/hosts` entries are required.
OpenCode's `InstanceMiddleware` determines the project directory via
`?directory=` → `x-opencode-directory` header → `process.cwd()`. The
forge entrypoint `cd`s into `$PROJECT_DIR` before launching
`opencode serve`, so `process.cwd()` is always the mounted project's
absolute path. Adding a `<base64url(path)>` segment — the format
OpenCode's SolidJS router uses for its `:dir` route — is redundant:
the hostname already identifies the project and the server already has
the directory via CWD. The SPA handles client-side routing from `/`
onward.

#### Scenario: URL is hostname-only — no encoded path
- **WHEN** the tray constructs the launch URL for a project named
  `thinking-service`
- **THEN** the URL is exactly
  `http://thinking-service.localhost:<port>/`
- **AND** the URL contains no base64-encoded path segment
- **AND** the URL contains neither `127.0.0.1` nor a bare `localhost:`

#### Scenario: Subdomain is a secure context
- **WHEN** the browser loads `http://<project>.localhost:<port>/`
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

