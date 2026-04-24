# Design: deprecate-tauri-webview-for-native-browser

## Context

Every fix for OpenCode Web in the last cycle has been WebKit2GTK-shaped:
monkey-patching `Notification.permission`, opting into `incognito(true)` per
webview, enabling `devtools(true)` in release builds, injecting an
`initialization_script` to seed localStorage, computing CSP hashes to allow
inline theme scripts the upstream ships but the upstream's own CSP blocks,
and so on. The common denominator: the Tauri WebKit2GTK webview is a
locally-hostile environment for OpenCode's web UI.

Meanwhile, every macOS / Linux / Windows user of a coding agent has a good
browser already installed. Chromium and Firefox hardcode `*.localhost`
loopback resolution per RFC 6761; both have first-class devtools, per-site
permission UIs, extensions, dark-mode toggles the user already configured
for every other site, and PWA install we can explicitly block.

This change removes the Tauri webview path for OpenCode Web entirely and
replaces it with an "open in native browser in app-mode" model.

## Decisions

### Decision 1 — Remove Tauri WebviewWindow code, do not wrap it

We delete `src-tauri/src/webview.rs` and introduce `src-tauri/src/browser.rs`.
No compat shim, no "use webview if native browser missing" fallback — that
would preserve the complexity we're trying to shed. The only fallback is the
OS default launcher (`xdg-open`/`open`/`start`), which still lands in a real
browser.

### Decision 2 — Browser detection order, explicit + documented

User-chosen order: **Safari → Chrome → Chromium → Chrome (bundle) → Edge → Firefox → OS default**.
Rationale:

- Safari first on macOS: native look+feel, matches the OS idiom.
- Chromium family second: broadest RFC 6761 + devtools support, stable
  `--app=` kiosk mode, `--user-data-dir` for per-project isolation.
- Firefox next: solid `--profile` isolation, `--new-instance` fresh
  window.
- Fallback to the OS default so we don't hard-fail on exotic setups
  (Konqueror, Pale Moon, etc.).

Detection is PATH-based via `which`-equivalent + a small list of known
bundle paths (`/Applications/Safari.app/…`, `/Applications/Google Chrome.app/…`,
`C:\Program Files\…`). No registry queries, no DBus — simple filesystem
probes.

### Decision 3 — App-mode launch per browser family

| Browser | Launch | Per-project isolation |
|---|---|---|
| Safari | `open -n -a Safari <url>` | (none — Safari has no profile flag; accepts the tradeoff on macOS) |
| Chrome / Chromium / Edge | `<bin> --app=<url> --user-data-dir=<tmpdir>` | Per-project fresh profile directory under `$XDG_RUNTIME_DIR/tillandsias/browser/<project>-<epoch>` |
| Firefox | `<bin> --new-instance --no-remote --profile <tmpdir> <url>` | Same — fresh profile dir per attach |
| Fallback | platform launcher | User's primary browser, user's primary profile |

`--app=<url>` yields a borderless single-site window in Chromium; tabs
disabled, URL bar hidden, only the document chrome. The closest equivalent
of the old Tauri window from the user's perspective.

Profile dirs live on tmpfs (`$XDG_RUNTIME_DIR`); cleaned up when the tray
exits. No state survives tray quit → ephemeral contract preserved.

### Decision 4 — `*.localhost` URL, no /etc/hosts, no CA

RFC 6761 §6.3 reserves `.localhost` for loopback. Chromium (since M64) and
Firefox (since 84) hardcode this; systemd-resolved (since v245) resolves
arbitrary `*.localhost` to 127.0.0.1. No `/etc/hosts` edits, no sudo, no
local-CA TLS.

URL shape:

```
http://<project>.localhost:<host_port>/<base64url(/home/forge/src/<project>)>/
```

`*.localhost` is a secure context per W3C Secure Contexts §3.1 —
Notification, WebCrypto, clipboard, service workers all work over plain
HTTP. Safari on older macOS releases may be less forgiving about the
subdomain case; the browser module falls back to `http://127.0.0.1:<port>/…`
if a Safari launch fails (edge case; logged as a warning).

### Decision 5 — Proxy owns all client-visible script injection

We delete the Tauri `initialization_script` path because it has no browser-
side equivalent. The proxy — already sitting between the browser and
`opencode serve` for SSE-keepalive + CSP-hash injection — takes on three
more jobs:

1. **Drop the `Origin` header** on upstream requests. OpenCode's
   `CorsMiddleware` is a strict-exact allowlist; rewriting the config per
   attach is fragile; dropping `Origin` sidesteps the allowlist entirely.
   Matches the "proxy owns the browser-facing surface" doctrine.
2. **Inject a bootstrap `<script>`** at the top of `<head>`. Seeds
   `localStorage.opencode-color-scheme = 'dark'`. Classic script (no
   `defer`/`async`/`module`), synchronous, side-effect-only. Runs before
   OpenCode's `/oc-theme-preload.js` external script.
3. **Strip `<link rel="manifest">`** + **404 every PWA entry point**
   (`/site.webmanifest`, `/manifest.json`, `/manifest.webmanifest`,
   `/sw.js`, `/service-worker.js`) + **add `Service-Worker-Allowed: none`**
   to HTML responses. Kills PWA install three different ways so the
   ephemeral contract holds even as opencode upstream evolves.

The CSP-hash machinery already in place handles the new bootstrap script
body automatically — one more `'sha256-<b64>'` appended to `script-src`.

### Decision 6 — No programmatic Notification pre-grant

We explicitly remove the Tauri-era monkey-patch that forced
`Notification.permission === 'granted'` and overrode
`Notification.requestPermission`. Rationale:

- Notifications API spec requires a user gesture for every permission
  call. Browsers refuse non-gesture requests with no error; the
  monkey-patch hides a bug rather than fixing it.
- Native browsers have a well-understood permission UI: URL-bar badge
  in Chrome, doorhanger in Firefox, native dialog in Safari. Users know
  what to click. The Tauri modal was unfamiliar and obstructive.
- For a local dev tool, granting once per origin is a one-time cost. The
  remembered-decision persists via the browser's per-origin storage.

### Decision 7 — Tray doesn't manage browser lifecycle

Tray Quit runs `shutdown_all()` (stops containers, rms them, destroys
enclave). The browser window is NOT sent SIGTERM. Rationale:

- The browser belongs to the user. Killing user-spawned processes is a
  respect boundary.
- The browser already handles backend disappearance gracefully (renders
  "connection refused" on next reload).
- Tracking browser PIDs across browser-side window-manager operations
  (user opens new tab, splits window, etc.) is brittle; we'd end up
  killing too much or too little.

Per-project user-data-dir cleanup happens at tray exit via a tmpfs path
(`$XDG_RUNTIME_DIR` is cleaned by systemd on user logout regardless).

### Decision 8 — Block Tauri webview features in `Cargo.toml`

We drop `tray-icon` + `image-png` features that are already there (still
needed), but remove webview-window-specific code paths. Tauri still
hosts the tray + menu + system integration. The net effect on the binary
is small; the architectural win is eliminating a class of bugs.

### Decision 9 — Keep the tray-side knowledge of which browser launched

For log + telemetry purposes, the tray logs which browser it detected and
launched. No PID tracking beyond the launch's Stdio spawn (to surface
exec failures promptly). No lifecycle tracking after that.

## Alternatives Considered

- **Embedded Chromium via CEF / webkitgtk-6 port.** Rejected: defeats the
  "don't ship another browser" case. We'd own patching bugs in yet
  another webview.
- **Keep Tauri webview as fallback for "simple mode".** Rejected: user
  explicitly said NO HYBRID. Fallback = permanent maintenance cost on
  the worst-performing path.
- **Generate per-attach `server.cors` entry.** Rejected: fragile
  (regenerated on every port allocation), plus CORS allowlist is
  irrelevant once we drop `Origin`.
- **Use proxy to inject a nonce per response.** Rejected: overkill for
  static bootstrap content. sha256 hash is fine, cacheable, and matches
  what opencode itself does on its cloud path.
- **Force HTTPS with a local CA.** Rejected: `*.localhost` is already a
  secure context per spec; local CA adds per-browser trust-store setup
  (user pain) for zero feature gain.

## Verification plan

1. `cargo build --workspace` + `cargo test --workspace` pass.
2. `openspec validate --strict deprecate-tauri-webview-for-native-browser`
   passes.
3. Rebuild forge image + AppImage.
4. Launch tray, attach a committed-repo project (e.g. `ai-way`).
   - Chrome opens as an app-mode window at
     `http://ai-way.localhost:<port>/<base64>/`.
   - DevTools F12 works.
   - Dark theme renders on first paint; no light flash.
   - No CSP violations in console.
   - "Install" icon never appears in URL bar.
   - `GET /site.webmanifest` returns 404 (via curl from host).
5. Send multiple prompts with idle gaps. No hang; notification prompt
   (when it appears) is the browser's native one, not a modal.
6. Tray Quit: forge container removed, enclave network destroyed; browser
   window stays open and shows a connection-refused page on reload.

## Trace requirements

- `@trace spec:opencode-web-session` on `browser.rs` launch function,
  browser-detection helpers, and URL construction.
- `@trace spec:opencode-web-session` on the proxy's new Origin-drop
  branch, bootstrap-inject, manifest-strip, PWA-404 blocks.
- Commit body includes GitHub search URL for `@trace spec:opencode-web-session`.
