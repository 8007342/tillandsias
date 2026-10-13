# 1656-tjv4: Apple presets open in "WebKit (approximates Safari)", confined like a Chromium window

Host: lenovinha (Fedora Silverblue 44, podman 5.8.7, Wayland session). Date: 2026-10-13.
Every run was on a PRIVATE podman store. The operator's containers, networks,
netavark run dir and `$XDG_RUNTIME_DIR/tillandsias/browser` were unchanged
before and after each run (`*/op-*`).

The measure-first spike (why Ubuntu, why not Playwright's downloader) is in
`plan/evidence/1656-tjv4-webkit-spike-2026-10-13/`.

## Coordinator rulings (2026-10-13) and how they are met

- **A. Image:** `images/webkit/Containerfile`.
  - Base: `ubuntu:24.04@sha256:534baea6…`.
  - Node 22.23.3 (sha256-checked), since Playwright 1.63 needs node ≥ 20 and
    Ubuntu ships 18.
  - `playwright@1.63.0`, plus `playwright install-deps webkit` (apt only).
  - The WebKit 26.6 build (revision 2359), fetched by URL and sha256.
  - No Playwright browser downloader.
  - The same fonts as the chromium-framework image (1656-6c97).
  - 1.52 GB. It is built on the first Apple-preset `browser.open` by
    `ensure_versioned_images`, not at init.
- **B. Names:** `--add-host` maps exactly `www`/`web.<project>.localhost` to
  the forwarder, on the same `--internal` window network as 1651-5t7n. See the
  relay below for the one measured deviation, which the coordinator approved.
- **C. Trust:** the enclave CA is bind-mounted read-only as the container's
  WHOLE system bundle (`/etc/ssl/certs/ca-certificates.crt`). It holds one
  certificate, and `touch` on it is denied. `ignoreHTTPSErrors` is never used.

## The loopback relay (measured deviation, approved)

WebKitGTK resolves names through GLib, which answers EVERY `*.localhost` name
with loopback and never reads `/etc/hosts` for them. With `--add-host`
alone, WebKit dialled 127.0.0.1 and got "Could not connect to
www.demo.localhost: Connection refused", for its own project and for
`www.other` alike (`container-level/probe-run3.txt`).

So the window's launcher (`images/webkit/webkit-window.js`) runs a relay:
- on the window's own loopback, 127.0.0.1 and ::1;
- on the preview port only;
- passing raw TCP, unread, to the per-window forwarder.

The forwarder now also listens on that port (`TILLANDSIAS_FWD_EXTRA_PORTS`).

The binding is unchanged: the forwarder admits only this project's SNI, and
the router's `strict_sni_host` binds Host. The reason is written into the row
(a note event), the spec delta (browser-window-modes) and the code, so the
relay is not "simplified" away.

## Also measured

- **No USER line.** Under `--userns=keep-id` an explicit `USER 65534` cannot
  write the owner-only host Wayland socket: GTK reports "Failed to open
  display". With no USER, keep-id runs the process as the host user's uid.
  The Chromium image only works because its `chromium` user is uid 1000.
- **`label=disable`,** ContainerSpec's default, is needed for the same reason
  as 1641-xbvq: GTK must connect to the compositor socket. It is noted under
  1252-qyii.
- **Touch points.** Playwright's WebKit context with `hasTouch: true` still
  reports `navigator.maxTouchPoints = 0` to the page. Viewport and dpr match
  the device (393 and 3). Not an exit criterion; recorded for 1656-twhk.

## Live, through the tray's own path (`tray-live/`, rc 0, 91.8 s including the on-demand image build)

`browser_open::tests::live_webkit_window_for_an_apple_preset` runs on the
1649-xqet harness.

| arm | measured |
|---|---|
| `browser.open{device:"iphone 15"}` | `engine: "WebKit (approximates Safari)"`, image `tillandsias-webkit:v56.10.12.1` |
| the page itself | `[393, 3, 0]`; UA `Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 …) AppleWebKit/605.1.15 … Mobile/15E148 Safari/604.1`: AppleWebKit yes, `Chrome/` no |
| window listeners (tcp and tcp6) | exactly `127.0.0.1:18443` and `[::1]:18443`, the relay |
| host `ss -ltnH` while open | no new listener |
| own project | 200 `PREVIEW-DEMO` |
| `https://www.other.localhost:18443/` | TLS refused; the forwarder logs `refused sni="www.other.localhost"`; the other project's server saw no request |
| `https://example.com/`, `https://1.1.1.1/` | name not resolved; network unreachable |
| raw client: SNI demo, Host other | 421 (strict_sni_host) |
| enclave-CA cert / foreign-CA cert | loads (LOCAL-OK) / "Unacceptable TLS certificate" |
| `browser.close` | no `tillandsias-browser-*` container left |

`container-level/` holds the same arms run directly with podman, before the
tray integration (`harness.sh.txt`, `probe.js.txt`).

## Regressions on this branch (all rc 0)

- `regression-browser_open_emulates_the_requested_device/` (1655-urz9). Its
  iPhone 12 Pro Max now asks for `engine: "chromium"`, since Apple presets
  default to WebKit.
- `regression-dev_mode_gives_only_the_owning_lane_full_cdp/` (1656-iktu).
- `regression-1649-1651/` (isolation).

## Engine behaviour in browser.open

- **Engine choice:** taken from the device's catalogue engine (webkit becomes
  WebKit; blink and gecko become Chromium). `engine: "chromium" | "webkit"`
  overrides it.
- **Dev mode:** `dev: true` on WebKit is `ENGINE_UNSUPPORTED`, since dev mode
  is CDP.
- **CDP tools:** screenshot, click, type, eval and set_device on a WebKit
  window answer `ENGINE_UNSUPPORTED`, naming the engine and 1656-twhk.
- **Labelling:** the result, `list_windows` and `read_url` carry the engine
  label.
- **Window title:** the OS window title is MiniBrowser's, which follows the
  page title. It cannot carry the label without patching MiniBrowser, so the
  label is shown in the tool results instead.
