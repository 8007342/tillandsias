## Why

Per the user's directive: "include its installer in userspace with our curl installer, and assume from the binary that it is installed. Our installer shall remain tiny and free of dependencies." Plus: "Use some ephemeral --user-dir [...] incognito mode and some random empty user dir only if required to override default. Our browsers should also run in isolation and support agentic control of web apps launched."

Today `browser.rs::detect_browser` walks `$PATH` looking for any chromium-family binary. That couples the user's tray-launched browser windows to whatever browser they happen to use for daily browsing (gmail, banking) — no isolation. Plus we can't enable CDP (`--remote-debugging-port`) because it would interfere with their running Chrome.

This change downloads Chrome for Testing into `~/.cache/tillandsias/chromium/<version>/` on first launch (or version bump), uses ONLY that binary for tray-launched windows, with `--incognito --user-data-dir=<random tmp>` per launch.

## What Changes

- **NEW** Host-side downloader: on tray init, check `~/.cache/tillandsias/chromium/<pinned-version>/chrome` exists. If missing or stale, download from `googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json` (verified by SHA-256). Surface progress via the additive chip (`✅🧭 Downloading browser runtime...`).
- **NEW** Per-launch flags: `--app=<url> --user-data-dir=$(mktemp -d) --incognito --no-first-run --no-default-browser-check --remote-debugging-port=<random-high-port>`. The `--user-data-dir` is destroyed on window close.
- **MODIFIED** `browser.rs::detect_browser` returns `BundledChromium { bin: ~/.cache/tillandsias/chromium/<version>/chrome }` always. `Safari` / `Firefox` / `OsDefault` paths tombstoned (kept three releases for traceability).
- **NEW** Download telemetry per `forge-cache-architecture` — first launch emits `category="download", source="host-tray", target="~/.cache/tillandsias/chromium/<version>/"`.
- Update mechanism: pinned-version bump in a Tillandsias release → init notices, downloads new version into a fresh `<version>/` dir, updates `~/.cache/tillandsias/chromium/current` symlink, old version cleaned up after one release.
- Zero new UX. Zero new prompts. Zero new menu items.

## Capabilities

### New Capabilities
- `host-chromium-on-demand`: download / verify / launch / update mechanism for the bundled Chromium.

### Modified Capabilities
- `opencode-web-session`: browser launch always uses bundled Chromium; `--incognito` + ephemeral `--user-data-dir`; CDP enabled per launch.

## Impact

- `src-tauri/src/browser.rs` — replace detection logic with download+resolve.
- `src-tauri/src/chromium_runtime.rs` (new) — download / verify / version-management.
- Host installer size unchanged (~80 MB AppImage). Chromium downloads on demand (~150 MB compressed).
- Bypasses user's daily Chrome entirely — privacy + isolation guarantees hold.
- Depends on `tray-host-control-socket` for future MCP integration but ships standalone.

## Sources of Truth

- Chrome for Testing official channel: `googlechromelabs.github.io/chrome-for-testing/`
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — confirms `~/.cache/tillandsias/chromium/` is host-managed shared state, never bind-mounted into forge.
