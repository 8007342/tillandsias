# tasks

## 1. Browser detection + launch module (Rust)

- [ ] Create `src-tauri/src/browser.rs`:
  - `detect_browser()` → enum `BrowserKind { Safari, Chrome, Chromium, Chrome2, Edge, Firefox, OsDefault }`
  - PATH-based probes + known bundle paths per platform (Linux + macOS + Windows).
  - `launch_for_project(project_name, host_port) -> Result<Child, String>` constructs the URL
    `http://<sanitized-project>.localhost:<port>/<base64url(/home/forge/src/<project>)>/` and spawns
    the detected browser with the correct flags.
  - Per-browser flag tables for app-mode + isolated profile dir.
  - Detailed `tracing::info!` on detection + launch choices.
- [ ] Add unit tests:
  - Detection order respected given mocked PATH.
  - URL construction: base64url correctness (reuse the existing helper).
  - Args per browser kind (snapshot test).

## 2. Remove Tauri webview code

- [ ] Delete `src-tauri/src/webview.rs` entirely.
- [ ] `src-tauri/src/main.rs`:
  - Drop `webview::set_app_handle(...)` call.
  - Drop the `CloseRequested` filter for `web-*` labels in the `RunEvent`
    handler (no more webviews to filter).
  - `RunEvent::ExitRequested` handler simplifies — `code.is_none()` still
    `api.prevent_exit()` so OS last-window auto-exit doesn't fire (there
    are no windows now, but the contract stays defensive).
- [ ] `src-tauri/src/handlers.rs::handle_attach_web`:
  - Replace `webview::open_web_session_global(...)` with
    `browser::launch_for_project(...)`.
  - Drop the reattach path's `open_web_session_global` — if the forge is
    already running, re-launch the browser (new window) instead of
    reusing a webview handle.
- [ ] Grep the codebase for any remaining `WebviewWindow` / `webview::`
  references and clean up.
- [ ] `Cargo.toml`: remove any webview-only features/plugins no longer used.

## 3. Proxy — Origin drop + bootstrap inject + PWA kill

- [ ] `images/default/sse-keepalive-proxy.js`:
  - Add `delete headers['origin']` in the request-forwarding path (always,
    not just for SSE).
  - Add bootstrap script constant (one classic `<script>` body that seeds
    `localStorage.opencode-color-scheme = 'dark'` guarded by try/catch).
  - In the HTML-buffering branch:
    - Strip `<link rel="manifest" …>`.
    - Inject `<script>bootstrap</script>` as first child of `<head>`.
    - Compute sha256 of bootstrap body, add to the CSP's `script-src`
      alongside any other hashes.
    - Add `Service-Worker-Allowed: none` to the response headers.
  - Add 404 short-circuit for `/site.webmanifest`, `/manifest.json`,
    `/manifest.webmanifest`, `/sw.js`, `/service-worker.js`, `/worker.js`.
  - Preserve existing SSE-keepalive behaviour untouched.
- [ ] Add proxy tests via a tiny Node smoke script (host-side, no podman
  needed): spin up a mock upstream on an ephemeral port that returns a
  canned HTML + the manifest, then assert the proxy's response has the
  bootstrap, hashes, no manifest link, and 404s on manifest paths.

## 4. OpenSpec + cheatsheets

- [x] `openspec/changes/deprecate-tauri-webview-for-native-browser/` —
  proposal, design, tasks (this file), specs delta.
- [ ] `openspec validate --strict deprecate-tauri-webview-for-native-browser` passes.
- [ ] New `docs/cheatsheets/native-browser-launch.md`: detection order,
  per-browser flags, debugging tips (how to see which browser the tray
  picked, how to force one via env var for testing).
- [ ] Update `docs/cheatsheets/opencode-web.md`: "no longer uses Tauri
  webview" note + pointer to the new cheatsheet.
- [ ] Update the memory at
  `memory/feedback_opencode_web_debug_via_chrome.md` to note the new
  default (browser-first, no more F12-in-Tauri dead end).

## 5. Build + integration test

- [ ] `./build.sh --check` clean.
- [ ] `./build.sh --test` all green (new unit tests pass).
- [ ] `./build.sh --release --install` rebuilds AppImage.
- [ ] Rebuild forge image (new proxy JS baked in).
- [ ] Launch tray. Click Attach Here on a committed-repo project.
- [ ] Verify: app-mode window opens in the detected browser; URL is
  `<project>.localhost:<port>`; dark theme on first paint; F12 opens
  devtools; no CSP console errors; no "Install" prompt; notifications
  prompt appears only on a user gesture; Tray Quit cleans up containers;
  browser window stays open with a "can't reach" page.

## 6. Spec convergence + archive

- [ ] `/opsx:verify deprecate-tauri-webview-for-native-browser`.
- [ ] `/opsx:archive deprecate-tauri-webview-for-native-browser`.
- [ ] Bump version via `./scripts/bump-version.sh --bump-changes`.
- [ ] Commit with `@trace spec:opencode-web-session` + GitHub search URL.
