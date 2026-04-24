## REMOVED Requirements

### Requirement: WebviewWindow launch contract

**Reason:** Tauri `WebviewWindow` is no longer used for OpenCode Web
sessions. Native browser launch replaces it — see
"Native browser launch contract" below.

### Requirement: Webview close does not terminate the tray

**Reason:** No more Tauri webview exists. The tray's lifecycle is
independent of the browser window the user opens; browser close never
affected the tray in the first place because the browser is an external
process.

### Requirement: Each webview gets an isolated WebContext

**Reason:** Replaced by per-project browser user-data-dir isolation (see
"Native browser launch contract" — each Attach Here launches the browser
with `--user-data-dir=<per-project-tmpdir>` on Chromium/Edge and
`--profile <per-project-tmpdir>` on Firefox; fresh state per attach).

### Requirement: Webview defaults to dark color scheme on first open

**Reason:** Replaced by "SSE-keepalive proxy injects bootstrap script"
below. Proxy now injects the `localStorage.opencode-color-scheme='dark'`
seed as a server-side inline script hashed into the CSP.

### Requirement: Webview exposes devtools

**Reason:** The native browser's devtools (F12, Ctrl+Shift+I, right-click
Inspect) are always available. No tray-side code is required to enable
them. Obsolete.

### Requirement: Webview URL loads the project-scoped route directly

**Reason:** Still true, but moved to "Native browser URL format uses
`*.localhost` subdomains" below, which subsumes both the base64
directory-path rule and the new hostname rule.

## ADDED Requirements

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
