# Native Browser Launch — Cheatsheet

@trace spec:opencode-web-session

Tillandsias launches the user's native browser (not an embedded webview) for every OpenCode Web session. This cheatsheet covers detection order, per-browser flags, debugging tips, and the URL/proxy contract the browser sees.

## Detection order

`src-tauri/src/browser.rs::detect_browser()` — first match wins:

1. **Safari** (macOS only) — `/Applications/Safari.app/Contents/MacOS/Safari` exists.
2. **Chromium family** — first binary in `$PATH`:
   - `google-chrome`, `google-chrome-stable`, `chromium`, `chromium-browser`, `chrome`, `microsoft-edge`, `microsoft-edge-stable`, `msedge`.
   - Fallback macOS bundle paths: `Google Chrome.app`, `Chromium.app`, `Microsoft Edge.app`.
3. **Firefox** — `firefox` in `$PATH`, or `/Applications/Firefox.app/...` on macOS.
4. **OS default** — `xdg-open` (Linux), `open` (macOS), `start` (Windows).

## Launch args per browser

| Browser | Launch | Notes |
|---|---|---|
| Safari | `open -n -a Safari <url>` | No app-mode or profile isolation — macOS limitation accepted. |
| Chrome / Chromium / Edge | `<bin> --app=<url> --user-data-dir=<tmp> --no-first-run --no-default-browser-check --disable-features=DesktopPWAsWithoutExtensions` | App-mode window (no tabs/URL bar), per-project tmpfs profile, PWA feature disabled as belt-and-braces (proxy kills install anyway). |
| Firefox | `<bin> --new-instance --no-remote --profile <tmp> <url>` | Site-Specific Browser mode, per-project profile. |
| OS default | `xdg-open <url>` / `open <url>` / `start <url>` | User's main browser, user's main profile. |

## URL format

```
http://<project>.localhost:<host_port>/<base64url(/home/forge/src/<project>)>/
```

- **`<project>.localhost`** — per RFC 6761 §6.3, browsers resolve any `*.localhost` to loopback without `/etc/hosts` edits. Hardcoded in Chromium (M64+), Firefox (84+). Resolved by systemd-resolved (v245+) for other browsers on Linux.
- **`*.localhost` is a secure context** per W3C Secure Contexts §3.1 — Notification, WebCrypto, clipboard, service workers all work over plain HTTP.
- **Base64url-encoded project path** — tells OpenCode's SolidJS `:dir` router which project this session is for; carried through to API calls via `x-opencode-directory` header automatically.

Example for project `ai-way` on port 17000:

```
http://ai-way.localhost:17000/L2hvbWUvZm9yZ2Uvc3JjL2FpLXdheQ/
```

## What the proxy does on the user's behalf

Between the browser and `opencode serve` (inside the forge), our Node proxy (`images/default/sse-keepalive-proxy.js`) handles:

| Concern | What the proxy does |
|---|---|
| SSE idle drops | Injects `:\n\n` comments every 5 s when upstream is silent so Bun's 10 s `idleTimeout` never fires. |
| CORS | Drops the `Origin` header on upstream requests so OpenCode's strict-exact allowlist (no regex, no wildcards) never blocks arbitrary `*.localhost` origins. |
| CSP inline scripts | Computes sha256 of every inline `<script>` body, appends `'sha256-<b64>'` to `script-src`. Handles opencode's own inline scripts + our bootstrap. |
| Dark theme default | Injects a `<script>` as first child of `<head>` seeding `localStorage.opencode-color-scheme = 'dark'` before opencode's theme-preload runs. |
| PWA install | Strips `<link rel="manifest">` from HTML, 404s `/site.webmanifest`, `/manifest.json`, `/manifest.webmanifest`, `/sw.js`, `/service-worker.js`, `/worker.js`. Adds `Service-Worker-Allowed: none` to HTML responses. |
| User gestures / notifications | Does NOT pre-grant Notification permission. The browser's native permission UI handles it on the user's first "Send" click (user gesture required per the Notifications API spec). |

## Debugging

### Which browser did the tray pick?

```bash
tail -f ~/.local/state/tillandsias/tillandsias.log \
  | grep -E 'launching native browser|browser='
```

Output includes:

```
INFO tillandsias::browser: launching native browser for opencode-web session
    browser=Chromium-family
    url=http://ai-way.localhost:17000/L2hvbWUvZm9yZ2Uvc3JjL2FpLXdheQ/
```

### Force a specific browser for testing

`browser.rs::detect_browser()` is PATH-driven. To force Firefox: `export PATH=/tmp/no-chrome:/usr/bin/firefox-only:$PATH` with only `firefox` in the earlier dir. Or symlink `firefox` to a unique dir and put that first.

### Inspect CSP / manifest handling

```bash
PORT=$(podman port tillandsias-<proj>-forge | awk -F: '{print $NF}')

# CSP (should include sha256 for bootstrap + any inline scripts)
curl -s -i "http://<proj>.localhost:$PORT/" | grep -i content-security-policy

# Manifest 404
curl -s -o /dev/null -w '%{http_code}\n' "http://<proj>.localhost:$PORT/site.webmanifest"
# -> 404

# Bootstrap injected?
curl -s "http://<proj>.localhost:$PORT/" \
  | grep -o "opencode-color-scheme" | head
```

### Browser window hangs after first prompt?

The Bun `idleTimeout` issue was fixed by the proxy's SSE keepalive. If the webview hangs at prompt completion:

1. F12 → Network → filter `event` → confirm the stream is still connected. If it's closed, the proxy may have failed.
2. F12 → Console → look for red errors.
3. `podman exec tillandsias-<proj>-forge tail -50 /home/forge/.local/share/opencode/log/*.log` for server-side trace.
4. Check if a notification permission prompt is sitting unanswered somewhere in the page — per CSP3 we cannot pre-grant programmatically.

### Per-project profile dirs

Chromium `--user-data-dir` and Firefox `--profile` target tmpfs:

```
$XDG_RUNTIME_DIR/tillandsias/browser/<project>-<epoch_ms>/
```

systemd cleans up `$XDG_RUNTIME_DIR` on user logout. No manual cleanup needed.

## References

- [RFC 6761 §6.3](https://www.rfc-editor.org/rfc/rfc6761#section-6.3) — `.localhost` reserved for loopback
- [W3C Secure Contexts §3.1](https://w3c.github.io/webappsec-secure-contexts/#localhost) — `*.localhost` is a secure context
- [WHATWG Notifications API §Permission model](https://notifications.spec.whatwg.org/#permission-model) — user-gesture requirement
- [web.dev Install criteria](https://web.dev/articles/install-criteria) — what triggers the Chrome install button
- [anomalyco/opencode#21088](https://github.com/anomalyco/opencode/issues/21088) — CSP inline script bug

Related cheatsheets: `opencode-proxy-egress.md`, `opencode-csp-hash-injection.md`, `opencode-web.md`.
