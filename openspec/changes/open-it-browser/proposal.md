## Why

Operator direction (2026-10-12) for the prompt family "start this project
locally and open it": the agent launches the project's sibling web container
and opens it in an isolated browser window, sized to whatever device the user
named, with full development-mode control for the agent. The research
(`plan/issues/research/open-it-browser-2026-10-12.md`) found the specs in
conflict with that direction and with the code that has since landed:

- `host-browser-mcp` still says `browser.open` spawns Chromium directly on the
  host, with a loopback CDP TCP port. 1649-xqet moved it into the
  `tillandsias-chromium-framework` container.
- `local-web-preview` says no Chromium sibling is approved.
- `chromium-debug-variant` says "full network access (no allowlist)", while
  the ruling for development mode is full browser control, not full internet.
- `inference-engine-slots` SLOT-6 predates the operator's approval of
  confined host helpers for the NPU and Metal, and admits only a loopback TCP
  upstream.

Nothing specifies device presets as a first-class input, window sizing,
the Wayland-only display rule, development mode, or the per-platform engines
(WebKit, the macOS Safari appliance, WSLg on Windows).

## What Changes

- ADDED `device-presets`: a device preset is the input to every browser
  window. It covers the catalogue and its schema, one licence and source per
  entry, the resolution rules, and mobile first as a first-class citizen.
  It builds on the catalogue of 1643-q3at (change `device-catalogue`).
- ADDED `browser-window-modes`:
  - Wayland only, through one display-socket mount;
  - a per-window internal network and SNI-bound forwarder;
  - the window is the CSS viewport at host scale, plus CDP emulation;
  - development mode over a per-lane Unix socket brokered by the tray, with
    full CDP but not full internet;
  - the per-platform engine and isolation table, including the opt-in macOS
    Safari appliance and Windows via WSLg;
  - 100% separation from the user's personal accounts.
- MODIFIED `host-browser-mcp`: the browser provider is a container; Chromium
  never runs on the host, and there is no host CDP TCP port.
- MODIFIED `local-web-preview`: the Chromium window sibling is approved, and it
  trusts the router CA by pin inside the container. The host trust store
  is still never touched.
- MODIFIED `chromium-debug-variant`: full CDP, not full internet. The note that
  CDP exposes the window's session cookies, scoped to the owning lane.
- MODIFIED `inference-engine-slots` SLOT-6: confined host helpers for the NPU
  and Metal are approved. They do inference only, with no egress, under an OS
  sandbox (AppContainer, Seatbelt), on one socket, which may be a single named
  Unix socket.

## Impact

- Rows: 1656-iktu (dev-mode CDP broker), 1656-tjv4 (WebKit engine),
  1656-twhk (engine-neutral dev tools), 1656-cscv (macOS display path),
  1656-5rpe (macOS Safari appliance), 1656-kbfh (Windows NPU helper, child of
  483), 1656-6c97 (framework fonts and `--no-sandbox` fixture), 1656-mqvk
  (cheatsheet corrections). These build on 1641-xbvq, 1643-q3at, 1649-xqet,
  1651-5t7n, 1655-urz9, 1653-77bt and 1654-6me6.
- Code that will move: tillandsias-browser-mcp (`launcher::spawn_browser`, the
  CDP client, the tool table), tillandsias-headless (`build_project_browser_spec`),
  the chromium-framework image, the macOS tray's VM configuration, and the
  Windows tray's helper supervision.
- No spec change in this proposal widens egress, publishes a host port, or
  touches a host trust store.
