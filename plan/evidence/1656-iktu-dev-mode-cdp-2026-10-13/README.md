# 1656-iktu: development mode gives the owning lane full CDP, and nothing more

Host: lenovinha (Fedora Silverblue, podman 5.8.7, Wayland session). Date: 2026-10-13.

## Red (the 1655-urz9 tree, 35c5d8380)

`red-unit.txt`: the four new server tests fail because the tool table has no
`browser.cdp`. Calling it answers `TOOL_NOT_FOUND: browser.cdp`, and
tools/list carries no description for it.

## Green: live, on a private podman store (`green/`, rc 0)

The run uses the 1649-xqet harness:
- a scratch CA;
- the real router image routing projects `demo` and `other`;
- stand-in dev servers;
- the installed chromium-framework image, unchanged.

There are two lanes of project `demo`, `lane-a` and `lane-b`. Each is its own
`BrowserMcpServer`, as the tray builds one per lane connection. Lane A opens
`https://www.demo.localhost:18443/` with `dev: true`.

| criterion | measured |
|---|---|
| 1. lane A: `browser.cdp{Runtime.evaluate, expression "1+1"}` | `{"result":{"type":"number","value":2}}` |
| 2. lane B, same window_id: `browser.cdp`, `browser.screenshot` | both `WINDOW_NOT_FOUND: win-…` (lane A's screenshot: 13 492 base64 bytes) |
| 3. host `ss -ltnH`, before vs. while open | identical; in the container, 0 processes with `--remote-debugging-port`, 10 with `--remote-debugging-pipe` |
| 4. raw `Page.navigate` to `https://example.com/`, and to `https://www.other.localhost:18443/` | both `errorText: net::ERR_NAME_NOT_RESOLVED`; the other project's dev server logged no request |
| 5. the `browser.cdp` description | states that full CDP exposes the window's session cookies to the owning lane (unit test) |

The typed tools ran on lane A, live:
- `browser.navigate` (allowlist-checked);
- `browser.eval` returned `{"value":42}`;
- `browser.console_tail` returned `dev-mode-hello`;
- `browser.network_tail` returned 24 entries, among them the two
  `ERR_NAME_NOT_RESOLVED` failures.

The operator's containers, networks, netavark dir and browser dir were
unchanged (`*/op-*`).

Regressions, both rc 0 on this branch:
- `regression-1655/`: device emulation;
- `regression-1649-1651/`: isolation.

## Measured and handled

The first live attempt failed at the window's first `Page.navigate` with
`net::ERR_NETWORK_CHANGED`. The navigation raced the new container's network
settling. `WindowCdp::navigate` now retries that one error, up to 4 attempts
500 ms apart, and the next run passed.

## Design

- **Owner.** A window records `owning_lane = <project>/<instance>`; the tray
  passes the listener's LaneIdentity instance with `with_lane`.
  - Every lookup that acts on a window checks the owner: `cdp_for`, `owned_by`,
    `list_for_lane`, read_url, close and the debounce. Another lane's window is
    indistinguishable from an absent one (`WINDOW_NOT_FOUND`).
  - Each lane connection already has its own server and registry, so this is
    also defence in depth for any future shared registry.
- **Dev mode is opt-in** (`browser.open{dev: true}`).
  - The broker enables Runtime and Network on every page of a dev window. It
    keeps the last 500 console and network entries.
  - A normal window gets `DEV_MODE_REQUIRED` from `browser.cdp`, `navigate`
    and the tails, and `EVAL_DISABLED` from `browser.eval`.
  - `screenshot`, `click`, `type` and `set_device` work on every window.
- **`browser.cdp{window_id, method, params?, sessionId?, browser_level?}`**
  sends any CDP command. It uses the page session by default, a given
  `sessionId`, or the browser target. Its description states the cookie
  exposure to the owning lane, and that the network is not widened.
- **The network is unchanged.** Dev mode adds no route: the window's
  resolver rules, its forwarder and the router's `strict_sni_host` still bound
  it to its project, which criterion 4 shows for raw CDP navigation.
- **Not done here:** the row's optional raw `cdp.sock` mounted into the owning
  lane (for Playwright or Puppeteer). The relay serves exactly one client, the
  tray's broker, so exposing it needs a second, lane-scoped relay endpoint.
  This is left for a follow-up and is not an exit criterion.
