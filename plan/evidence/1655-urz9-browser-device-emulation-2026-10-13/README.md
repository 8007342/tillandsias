# 1655-urz9: browser.open{device} emulates the device; set_device switches it live

Host: lenovinha (Fedora Silverblue, podman 5.8.7, Wayland session). Date: 2026-10-13.

Every run uses the 1649-xqet live harness on a **private podman store**
(`*/harness.sh.txt`):
- a scratch CA in a private HOME;
- the real router image with this branch's `base.Caddyfile`, routing projects
  `demo` and `other`;
- stand-in dev servers for both projects;
- the installed chromium-framework image, unchanged. The relay runs from it as
  `node -e`, so no image change is needed.

The operator's inference, dev-inference and router containers, the network
list, the netavark runtime dir and `$XDG_RUNTIME_DIR/tillandsias/browser` were
unchanged before and after every run (`*/op-*`).

**What the window emulates is measured by the PAGE, not through CDP.** The
stand-in dev server's page (`web.js.txt`) has
`<meta name=viewport content="width=device-width">`. On load and on every change
(polled every 250 ms) it reports `[innerWidth, devicePixelRatio,
navigator.maxTouchPoints]` and `navigator.userAgent` back to the dev server, as
`GET /report?...` lines (`demo-web.log`).

## Red: the linux-next tree (5a8a77ba4 + the new live test)

`red/`. `browser.open{device: "iphone 12 pro max"}` opened a window, but the page
saw the host's values, `[913, 2, 0]`, with a desktop Linux UA.
`browser.set_device` answered `TOOL_NOT_FOUND`. The test failed (rc 101).

## Green: this branch

`green/` (rc 0):

| step | the page saw |
|---|---|
| `browser.open{device: "iphone 12 pro max"}` | `[428, 3, 5]`, UA `iPhone; CPU iPhone OS 14_4 ...` |
| `browser.set_device{device: "galaxy s24"}` on the same window | `[360, 3, 5]`, UA `Android 14; SM-S921U ... Chrome/156` |
| a fresh `browser.open{device: "galaxy s24"}` | `[360, 3, 5]` (the catalogue's 360 x 780 @3, 5 touch points) |

- **Host listeners:** the host had no new TCP listener while the window was
  open (`ss -ltnH` before vs. during: identical).
- **Window listeners:** the window container listened on no TCP port
  (`/proc/net/tcp`, `/proc/net/tcp6`).
- **CDP socket directory:**
  `$XDG_RUNTIME_DIR/tillandsias/browser/<window>.cdp` was mode 0700 and was
  removed on close.

`regression-1649-1651/`: the 1649-xqet/1651-5t7n live test still passes on this
branch (rc 0). It covers:
- the window's own network;
- the forwarder;
- no host chrome;
- the window loading the preview;
- every isolation probe.

## The touch quirk (measured, then fixed)

The first green attempt showed `[428, 3, 0]`: the viewport, dpr and UA held, but
touch did not. A variant page that navigates itself to `/again` after 9 s
showed the sequence:

```
[428,3,5,"/"]       first script on the site: touch emulated
[428,3,0,"/"]       a moment later: touch points gone
[428,3,5,"/again"]  same-site navigation: kept
[360,3,5,"/again"]  set_device: applied
```

The loss happens once, after the first cross-process commit (about:blank → the
site). Moving the touch commands ahead of the metrics did not change it.
Re-asserting touch on every main-frame `Page.frameNavigated` and on
`Page.loadEventFired` did: the same variant never reported a 0 (reports go out
on every change at 250 ms), and the standard run is green.

## Design

- **No host TCP listener.**
  - Chromium runs with `--remote-debugging-pipe` (fds 3/4, NUL-framed JSON).
  - The window's entrypoint is `node -e browser_window_cdp_relay.js -- <chromium
    args>`, passed as a JSON-array `--entrypoint`.
  - The relay serves the pipe on `/run/tillandsias-cdp/cdp.sock`. That is a bind
    mount of the per-window 0700 host dir, which the tray creates and removes.
  - It serves exactly ONE client and refuses a second. When that client
    disconnects, the relay ends Chromium, so overrides die with the session.
- **One session per window.**
  - `WindowCdp` (`window_cdp.rs`) holds the connection for the window's lifetime.
    The registry drops it before the container.
  - `Target.setAutoAttach {flatten, waitForDebuggerOnStart}` attaches the first
    page and every popup. Each page is emulated before it is released.
- **Window size and first navigation.**
  - The window is launched with `--window-size` set to the device's CSS
    viewport, in host DIPs (not multiplied by the device's dpr).
  - It opens `about:blank`. The tray emulates, then `Page.navigate`s, so the
    first request already carries the device's UA.
- **Emulation (from the 1643-q3at resolver):**
  - `setTouchEmulationEnabled {maxTouchPoints}`;
  - `setEmitTouchEventsForMouse`;
  - `setDeviceMetricsOverride {width, height, deviceScaleFactor, mobile,
    screen}`;
  - `setUserAgentOverride {userAgent, platform, userAgentMetadata}`. Client
    hints are derived only for Chromium UAs; Safari UAs send none.
- **Default device:** when `browser.open` names none, the project's
  `.tillandsias/config.toml` `[browser] device` is used, else `desktop`.
- **`browser.set_device{window_id, device}`** re-emulates every attached page
  and resizes the window with `Browser.setWindowBounds` (best effort).
- **CdpSession's framing is fixed.** The client wrote pipe framing to an HTTP
  port, which never worked. It is replaced by `CdpConnection`, which uses NUL
  framing over the relay's Unix socket, with a reader thread that routes
  replies by id and events to a channel. `browser.screenshot`, `click` and
  `type` now run on the window's own session.
