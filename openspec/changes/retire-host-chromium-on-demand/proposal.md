## Why

`spec:host-chromium-on-demand` describes a host-side Chromium:
- download Chrome for Testing into `~/.cache/tillandsias/chromium/`, verify it and repoint a `current` symlink;
- launch it as a host process with an ephemeral profile.

That behaviour no longer exists. Order 1649-xqet moved every browser window into the `tillandsias-chromium-framework` container. `crates/tillandsias-browser-mcp/src/launcher.rs` records it: "There is no host Chromium path: the old one looked for a binary under `~/.cache/tillandsias/chromium` that nothing downloads". The draft change `open-it-browser` already says the host-Chromium download path "is retired for `browser.open`", but it carries no REMOVED delta for this spec.

Evidence on linux-next, 2026-11-20 (order 2118-fk3w):
- `scripts/install-chromium.sh`, the downloader, has no caller. Its only consumer is `litmus:host-chromium-on-demand-shape`, which pins the script's own source.
- No crate reads `~/.cache/tillandsias/chromium` except the launcher comment above.

Coordinator ruling (macuahuitl-fedora, 2026-11-20): retire the whole spec, delete the installer and its shape litmus in the same PR, and keep `litmus:browser-ephemeral` by rebinding it to the spec that owns ephemeral profiles.

## What Changes

- **REMOVED** from `host-chromium-on-demand`: all four requirements.
- The spec becomes a tombstone, `superseded:host-browser-mcp+browser-window-modes`:
  - `host-browser-mcp` owns the browser window, its process-per-window ephemeral profile, and the bundled-engine-only rule.
  - `browser-window-modes`, proposed by `open-it-browser`, owns the separation from the user's personal browsers.
- `host-chromium`, already a tombstone that pointed at this spec, now points at the same two.
- Deleted: `scripts/install-chromium.sh` and `litmus:host-chromium-on-demand-shape`.
- `litmus:browser-ephemeral` is rebound from `host-chromium-on-demand` to `host-browser-mcp`, whose requirement "Process-per-window with ephemeral profile" it exercises.
- `@trace spec:host-chromium-on-demand` in code and cheatsheets is repointed to `spec:host-browser-mcp`.

## Impact

- No runtime behaviour changes: nothing called the installer or read its cache.
- `browser-window-modes` is not yet a main spec. Until `open-it-browser` lands it, the tombstone's live successor is `host-browser-mcp`.
- This lands as its own PR, so it can be reverted alone.
