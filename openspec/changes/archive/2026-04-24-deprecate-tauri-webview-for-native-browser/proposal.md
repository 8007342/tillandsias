## Why

Every problem we've hit with OpenCode Web in the last cycle came from the
Tauri/WebKit2GTK webview layer:

- **F12 / Ctrl+Shift+I does not open devtools** in WebKit2GTK under Tauri
  on Linux, even with `.devtools(true)`. Users can't inspect a stuck UI.
- **Modal dialogs from the browser (Notification permission, push prompts)
  block the UI indefinitely**. Tauri's WebKit2GTK renders these as modal
  banners with no clear dismissal path.
- **CSP, Permissions-Policy, and secure-context behaviour diverge** from
  Chromium/Firefox — APIs that "just work" in a real browser need webview-
  specific workarounds.
- **Every fix adds WebKit-specific code** (`incognito(true)`,
  `initialization_script`, monkey-patching `Notification.permission`,
  per-webview data dirs). The accumulation is a maintenance and threat-model
  smell.
- **PWA install** works in the real browser (advanced-user feature) but
  breaks our ephemeral contract — we want it explicitly disabled, and
  controlling that through a webview is harder than through a proxy.

The architectural call: **stop fighting the embedded webview. Launch the
user's native browser in app-mode instead.** Every OS has a good browser;
Chromium/Firefox have hardcoded `*.localhost` loopback resolution per
RFC 6761, full devtools, familiar permission UX, and PWA install we can
explicitly suppress. The tray stays in Rust/Tauri (tray icon is a first-
class feature), but the OpenCode Web UI becomes a separate, OS-owned window.

## What Changes

### Architecture shift

- **`handle_attach_web` no longer opens a Tauri `WebviewWindow`.** It
  launches the user's native browser in app-mode against the forge's URL.
- **`src-tauri/src/webview.rs` is removed** (or shrunk to a shim). The
  replacement, `src-tauri/src/browser.rs`, owns browser detection + launch.
- **Tauri webview-specific features are deleted**: `APP_HANDLE` global,
  `WebviewWindowBuilder` calls, `open_web_session*`, `close_web_sessions*`,
  `close_all_web_sessions*`, the `CloseRequested` filter in `main.rs`'s
  RunEvent handler, and the whole `initialization_script` pre-page-load hack.

### Browser detection + launch

Detection order (first match wins):

1. **Safari** on macOS (`/Applications/Safari.app/Contents/MacOS/Safari`).
2. **Chrome** / Chromium (`google-chrome`, `chromium`, `chrome`, platform
   bundle paths).
3. **Edge** (`microsoft-edge`, `msedge`, macOS bundle path).
4. **Firefox** (`firefox`, platform bundle paths).
5. **OS default browser** via `xdg-open` / `open` / `start`.

Launch in app-mode (no tabs, no location bar, single-site window):

| Browser | Command | Notes |
|---|---|---|
| Chrome / Chromium / Edge | `<bin> --app=<url> --user-data-dir=<per-project-tmpdir>` | Isolated profile per project; disables PWA install via `--disable-features=DesktopPWAsWithoutExtensions` |
| Firefox | `<bin> --new-instance --profile <per-project-tmpdir> --no-remote <url>` | Site-Specific Browser mode |
| Safari | `open -n -a Safari <url>` | Safari has no native app-mode; minimize chrome via window layout; document PWA-equivalent "Add to Dock" is explicitly out of scope |
| Fallback | `xdg-open <url>` / `open <url>` / `start <url>` | Plain browser tab |

### URL format — `*.localhost` subdomains

Every attach URL becomes:

```
http://<project>.localhost:<host_port>/<base64url(/home/forge/src/<project>)>/
```

Rationale:

- RFC 6761 §6.3 reserves the `.localhost` TLD — Chromium (since M64),
  Firefox (since 84), and systemd-resolved (since v245) all resolve
  `*.localhost` to loopback without any user/system config.
- `*.localhost` is a secure context per W3C Secure Contexts §3.1 —
  Notification API, WebCrypto, clipboard, service workers all work over
  plain HTTP.
- Per-project subdomains give the power user a readable URL
  (`forge.localhost:17000` vs `127.0.0.1:17000`) and keep origin isolation
  (localStorage per project) while staying on plain HTTP.
- HSTS-exempt on Chromium; cookies fine (host-only, no Domain attribute).

### Proxy gains four responsibilities

The SSE-keepalive proxy (already in every forge) takes on:

1. **Drop the `Origin` header on upstream requests.** OpenCode's
   `CorsMiddleware` is exact-string allowlist with no regex; dropping
   `Origin` bypasses the allowlist entirely. Cleaner than dynamically
   writing `server.cors` on every Attach.
2. **Inject a bootstrap `<script>` at the top of `<head>`.** Seeds
   `localStorage.opencode-color-scheme = 'dark'` before OpenCode's
   external theme-preload (`/oc-theme-preload.js`) reads localStorage.
   The proxy hashes the bootstrap body and adds `'sha256-<b64>'` to CSP
   (already has the hash-injection machinery).
3. **Strip `<link rel="manifest">` from HTML responses** + **404 every
   PWA-install entry point**: `/site.webmanifest`, `/manifest.json`,
   `/manifest.webmanifest`, `/sw.js`, `/service-worker.js`. Explicit PWA
   kill per the ephemeral-first doctrine.
4. **Preserve existing behaviour**: SSE keepalive every 5s on `/event` +
   `/global/event`, CSP hash injection for opencode's inline scripts (if
   present — upstream sometimes inlines, sometimes externalises).

### Notifications

- **No JS pre-grant.** Per Notifications API spec, `requestPermission()`
  requires a user gesture in every browser. We remove the monkey-patch
  that pretended to grant `'default' → 'granted'`.
- **Let the native browser's permission UI handle it.** User clicks the
  browser's "Allow" / "Block" banner like every other site. For a local
  dev tool the default "remember for this origin" behaviour is fine.
- **No `Permissions-Policy` header** is emitted by OpenCode, and we do not
  add one — default allowlist (`self`) is correct.

### Shutdown semantics

- Tray Quit still runs `shutdown_all()` — stops containers, removes them,
  destroys the enclave network.
- **We do NOT kill the user's browser processes.** The browser window for
  an Attach survives tray quit; the user closes it when they're done. This
  is a deliberate respect boundary: the browser belongs to the user.
- The forge container is removed on Quit. The browser window, still
  pointing at the defunct `<project>.localhost:<port>`, will show a
  "connection refused" state naturally. That's correct feedback.

## Capabilities

### Modified Capabilities

- `opencode-web-session`: replaces every Tauri-webview-specific requirement
  with native-browser-launch requirements. Removes
  `WebviewWindow launch contract`, `Webview close does not terminate the
  tray`, `Each webview gets an isolated WebContext`, `Webview exposes
  devtools`, `Webview URL loads the project-scoped route directly`, and
  the Notification monkey-patch. Adds browser-detection ordering, app-mode
  launch contract, `.localhost` URL contract, proxy bootstrap-inject
  contract, and PWA-disable contract.

## Impact

- **Rust**: `src-tauri/src/browser.rs` NEW (~150 LOC). `src-tauri/src/webview.rs`
  deleted. `src-tauri/src/handlers.rs::handle_attach_web` calls
  `browser::launch_for_project` instead of `webview::open_web_session_global`.
  `src-tauri/src/main.rs` drops the `CloseRequested` filter + `APP_HANDLE`
  install. `Cargo.toml` no longer needs webview-related Tauri features.
- **Shell**: `images/default/sse-keepalive-proxy.js` extended (~80 new LOC)
  for Origin-drop, bootstrap-inject, manifest-strip, 404s.
- **Config**: no changes to `opencode.json` / `config-overlay` — CORS is
  bypassed via proxy, not via config.
- **Images**: forge image must rebuild (proxy JS changed). Other images
  untouched.
- **Binary size**: tray binary shrinks (no WebKit webview features needed).
- **Tests**: new `browser.rs` unit tests for detection path ordering +
  per-browser arg construction. New proxy tests for origin-drop +
  manifest-strip + bootstrap-inject + PWA-404.
- **Docs**: new cheatsheet `docs/cheatsheets/native-browser-launch.md`.
  Existing `opencode-web.md` gets a "no longer uses Tauri webview" note.
- **Memory**: `feedback_opencode_web_debug_via_chrome.md` becomes partially
  obsolete (now the default). Update to note the remaining Safari edge case.

## Tradeoffs accepted

- **One more process per Attach** (the browser instance). Browser is
  already running most of the time in modern workflows; marginal cost.
- **Can't inject JS before page load** the way Tauri's
  `initialization_script` did. All seeding moves to a server-side
  `<script>` tag hashed into the CSP — proxy already has the machinery.
- **No programmatic pre-grant of Notifications.** Accepted: user clicks
  "Allow" once per origin; browser remembers. Better than the Tauri modal
  that blocked the UI.
- **Safari on older macOS may not treat `*.localhost` as secure context.**
  Mitigation in code: if Safari is the detected browser AND the launch
  fails, fall back to `http://127.0.0.1:<port>/` — we give up the
  per-project subdomain hygiene but keep all secure-context APIs.
