# "Start this project locally and open it": the browser design, distilled

- classification: research (design distillation)
- filed: 2026-10-12 (linux/macuahuitl, coordinator), order 1656-urmk
- status: operator-approved design; implementation is filed as rows
- source: three read-only research agents (2026-10-12) plus the operator's
  decisions. Labels: **M** = measured, **D** = documented, **I** = inferred.
- spec change: `openspec/changes/open-it-browser/` (new `device-presets`,
  new `browser-window-modes`; modified `host-browser-mcp`, `local-web-preview`,
  `chromium-debug-variant`, `inference-engine-slots`)
- related rows: 1641-xbvq (Wayland-only socket, landed), 1643-q3at / 1644-u8b8 /
  1652-p8xv (device catalogue), 1649-xqet (containerized `browser.open`, landed),
  1651-5t7n (per-window SNI forwarder, landed), 1655-urz9 (`browser.open{device}`
  with CDP emulation), 1653-77bt (Mac GPU route: Metal helper, landed),
  1654-6me6 (macOS Metal helper), 483 (host-native sidecars), 793-a8e7
  (WSL2 GPU opt-in), 1637-yrz8 / 1637-5765 / 1637-qmmd (templates, Flutter,
  deploy parity). Windows is filing a separate WSLg browser-window row.
- new rows (fragment `plan/index.d/20261012t230000z-1656-open-it-browser-macuahuitl.yaml`):
  1656-iktu dev-mode CDP broker; 1656-tjv4 WebKit engine container;
  1656-twhk engine-neutral dev tools; 1656-cscv macOS display path;
  1656-5rpe macOS Safari appliance; 1656-kbfh Windows NPU confined helper;
  1656-6c97 framework fonts and `--no-sandbox` fixture; 1656-mqvk cheatsheet
  corrections.

## The prompt family

"Start this project locally and open it": the agent launches the project's
sibling web container (`publish_local`, spec `local-web-preview`) and opens it
in an isolated browser window. Operator: "we want the chromium-framework
automation next."

## Operator decisions (2026-10-12)

1. **Wayland only.** No X11 fallback; refuse clearly without Wayland.
   Fedora GNOME has no X11 session, KDE defaults to Wayland, WSLg provides
   Wayland, and X11 lets any client read the whole desktop.
2. **Mobile first is first class.** "iphone", "iphone 12", "iphon 12 pro",
   "iphone 12 pro max" must work as well as galaxy, xiaomi, xperia, oneplus.
   A catalogue of a few hundred kilobytes is acceptable.
3. **Native engines may drift per platform**, under one hard requirement:
   "a 100% separate space from their personal accounts, either fully
   containerized in podman, or at least running in a guest VM even if it's a
   separate VM". Safari on macOS and Edge on Windows are first class where the
   platform can isolate them.
4. **Host helpers for NPU and Metal are approved**, "triage for the following
   releases automatically": a confined host helper doing inference only, with
   no internet, under the OS sandbox (AppContainer on Windows, Seatbelt on
   macOS), with one narrow socket to the enclave. This realises SLOT-6 of
   `inference-engine-slots` and packet 483.
5. **Development mode** gives agents "full access" to debug and drive the
   app. Coordinator ruling: full browser control (CDP), not full internet.

## Current state of the code (M, linux-next 2026-10-12)

Two Chromium paths disagreed when the research ran:

- the tray's containerized path, `build_project_browser_spec` in
  tillandsias-headless, running `tillandsias-chromium-framework`, hardened by
  615-x3b8 (read-only root, cap-drop all, no-new-privileges, keep-id, tmpfs
  state, GPU devices);
- the agent path, `launcher::spawn_browser` in tillandsias-browser-mcp, which
  started Chromium directly on the host from `~/.cache/tillandsias/chromium`.
  Nothing downloads that binary, so `browser.open` returned
  `BROWSER_UNAVAILABLE` unless `TILLANDSIAS_BROWSER_BIN` was set.

Defects found, and where they went:

| # | defect | row |
|---|---|---|
| 1 | SECURITY: on Wayland the browser container mounted all of `$XDG_RUNTIME_DIR` read-write (podman socket, tray control socket, D-Bus, keyring); X11 won whenever `DISPLAY` was set | 1641-xbvq (landed) |
| 2 | the port allowlist (`allowlist::validate`, `BrowserAllowlist::is_allowed`) admitted only 80 and 8080, refusing the 18443 preview URL | 1649-xqet (landed) |
| 3 | the browser container sat on podman's default network, where `*.localhost` is its own loopback (I) | 1651-5t7n (landed) |
| 4 | no fixture pins the image entrypoint's `--no-sandbox` check (612-nvf3) | 1656-6c97 |
| 5 | the framework image has no fonts | 1656-6c97 |
| 6 | spec conflicts: host-browser-mcp put Chromium on the host; local-web-preview said no Chromium sibling was approved; chromium-debug-variant said "no allowlist" | this change |
| 7 | cheatsheets: `--use-angle=d3d11` is Windows-only; `macos-vz-gui-research-v2.md` says Virtualization.framework has no virtio-gpu, but Linux guests have it since macOS 13 | 1656-mqvk |

Nothing did device emulation, window sizing, development mode or WSLg handling.

## The design

- **One launcher.** `browser.open` starts a browser container, never a host
  process. The host-Chromium download path is retired.
- **Display.** Mount only the `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` socket file
  into a private runtime dir; pass `--ozone-platform=wayland`.
- **Network.** A per-window `--internal` network shared only with an SNI-bound
  forwarder to the router (1651-5t7n). Host resolution is pinned with
  `--host-resolver-rules` so only the window's own project resolves. The
  router CA is trusted inside the container by SPKI pin
  (`--ignore-certificate-errors-spki-list`); the host trust store is never
  touched. (Remapping the port inside a MAP rule is unverified.)
- **Window size.** `--app=<url> --window-size=W,H` with W,H the device's CSS
  viewport at the host scale, not multiplied by the device DPR.
- **Device behaviour over CDP.** `Emulation.setDeviceMetricsOverride{width,
  height, deviceScaleFactor, mobile}`, `Emulation.setUserAgentOverride` with
  client-hint metadata, `Emulation.setTouchEmulationEnabled{maxTouchPoints}`
  and `Emulation.setEmitTouchEventsForMouse`. Overrides live only while a CDP
  session is attached, so the broker holds one session per window and
  auto-attaches popups.
- **Tools.** `browser.open{url, device?, dev?}` (device default: the
  `.tillandsias` project config, then desktop) and
  `browser.set_device{window_id, device}`.
- **Development mode.** Chromium runs with `--remote-debugging-pipe`, so there
  is no TCP port. An in-container relay exposes the pipe on a Unix socket in
  a tray-only host dir. The tray brokers typed tools on the peer-authenticated
  per-lane MCP socket (navigate, evaluate, console and network tails,
  screenshot, emulate) plus raw `browser.cdp{method, params, sessionId}`. An
  optional `cdp.sock` is mounted only into the requesting lane's
  `/run/host/tillandsias-mcp/` for Playwright or Puppeteer. Other lanes get
  `WINDOW_NOT_FOUND`; the host gets no listener. Full CDP means the window's
  session cookies (for example from an OTP login) are readable by the owning
  lane: accepted, documented, scoped to that lane.
- **WebKit engine.** Playwright's Linux WebKit build (WebKit LGPL/BSD,
  Playwright Apache-2.0) serves Apple presets, labelled "WebKit (approximates
  Safari)". It probably needs a Debian/Ubuntu base (I) and headful Wayland is
  unverified. Its automation is the Playwright protocol, not CDP, so the
  development-mode tools must be engine-neutral.

## Per-platform engines and isolation (platforms may drift)

| | Linux | Windows (yolanda is Home) | macOS (Apple silicon) |
|---|---|---|---|
| Engines | Chromium; Playwright WebKit for Apple presets | the same containers in WSL2; optional Edge-for-Linux in the container for codecs/DRM (redistribution licence unchecked) | default: the Chromium and WebKit containers in the tray's Linux VM; first-class opt-in: a Safari appliance (a separate macOS guest VM with Safari and the iOS Simulator) |
| Isolation | podman, Wayland socket only, private network | podman in WSL2, WSLg Wayland socket only. Windows Sandbox and Hyper-V are Pro-only; a separate Windows user or InPrivate fails the requirement | Linux VM plus container. The appliance is a second macOS guest; the macOS licence allows two extra macOS VMs (section 2B(iii)) and the Linux VM does not count |
| Automation | CDP (Chromium); Playwright protocol (WebKit) | same | the same in the Linux VM; appliance: safaridriver (W3C WebDriver) with `safari:useSimulator` for iOS |
| Window | per-app Wayland window | per-app window via WSLg | Virtualization.framework shows only a whole-desktop `VZVirtualMachineView`: size the guest display to the device, one view per device (a `cage` kiosk in the Linux VM, the Simulator window in the appliance). The Linux VM needs a virtio-gpu device |

Appliance cost (I): about 30–35 GB, or 60–90 GB with Xcode and simulators;
4–8 GB RAM; cold boot 30–60 s, resume from saved state in seconds (macOS 14+).
Off by default on floor-tier Macs (esme, macneo). Inside a guest VM,
`*.localhost` resolves to the guest's own loopback, so the appliance needs a
forwarder to the host router plus the router CA in the guest keychain.

## Device registry

- **Base:** Playwright `deviceDescriptorsSource.json` (Apache-2.0): 207
  entries, 107 portrait, iPhone through the 17 family, Galaxy S24/A55/Fold
  and Flip 7, Pixel 10 Pro XL, desktop Chrome/Edge/Safari/Firefox. Example:
  iPhone 12 Pro Max is viewport 428×746, screen 428×926, scale 3. Its iPhone
  UA strings are synthetic.
- **Merge:** Chrome DevTools `EmulatedDevices.ts` (BSD-3-Clause, 49 entries):
  safe-area insets, client-hint UA metadata, laptops.
- **Overlay:** hand-written YAML for Xperia, OnePlus, Xiaomi and other
  missing brands, from manufacturer spec pages, one source URL per entry.
- **Avoid:** GSMArena scraping, `devices.json` (licence unverified), WURFL and
  DeviceAtlas (proprietary).
- **Schema:** id, brand, family, model, aliases[], released (YYYY-MM), form
  (phone|tablet|foldable|laptop|desktop), os{name,version}, engine
  (webkit|blink|gecko), screen{w,h}, viewport{w,h} (portrait CSS px), dpr, ua,
  ua_metadata, mobile, touch, max_touch_points, safe_area{portrait,landscape},
  source{kind,url,license}.
- **Resolution rules** (implemented by 1643-q3at, corrected by 1652-p8xv):
  1. normalise: lowercase; `+` becomes "plus"; split glued tokens
     (`iphone12`); expand shorthand (`s24u` → s24 ultra); brand synonyms
     (sony→xperia, google→pixel, samsung→galaxy);
  2. an exact alias wins;
  3. otherwise every requested token must be present and the fewest extra
     tokens wins; modifiers (pro, max, plus, ultra, mini, e, fold, flip,
     cover) always count, so "iphone 12", "12 pro" and "12 pro max" are three
     devices;
  4. a bare brand or family gives the newest dated base flagship (never an
     e/mini/fold/cover); "desktop" gives 1440×900 at scale 1;
  5. ties and near misses return the best match plus alternatives, flagged
     approximated, never across brands;
  6. a trailing "landscape" swaps the dimensions.

## Hardware (GPU and NPU)

- **Windows GPU:** already passed through (`/dev/dxg` and `/usr/lib/wsl` into
  the inference container, 793-zumy; audit 1267-fj2z). The engine never
  selects Vulkan today; 793-a8e7 adds the opt-in, crossover routing (0.5B
  decode is a 1.23× regression on the iGPU) and a CPU-fallback deadline. dzn
  is non-conformant (Vulkan 1.2, no shaderInt8).
- **Windows NPU:** WSL2 has no NPU device (WSL issue #40842, open). Route: the
  approved confined host helper under AppContainer, egress denied, one
  socket (1656-kbfh, child of 483).
- **macOS GPU:** Venus Vulkan in a krunkit VM, or the approved Seatbelt Metal
  helper. 1653-77bt measured and chose Metal on the host (prefill 1308 t/s vs
  477 t/s under Venus for qwen2.5:3b on an M5); 1654-6me6 builds it.
- **macOS Neural Engine:** Core ML on the host only, through the same kind of
  confined helper; a separate measurement row when wanted.
- **MXC verdict unchanged:** `windows_sandbox` is Pro-only, cannot restrict to
  a proxy and shows a whole desktop; `wslc` needs WSL ≥ 2.9.9 (yolanda has
  2.7.13; no pre-release by operator ruling); `processcontainer` runs on the
  host, acceptable only as the helper's sandbox.

## Unknowns

- Whether Safari, Web Inspector and the Simulator work in a guest with the
  paravirtualized GPU (FB11975037 display bugs).
- The appliance's real disk use and resume time.
- Edge-for-Linux redistribution terms.
- WSLg Wayland scale factors.
- Playwright WebKit headful under Wayland only.
- macOS VM slot leaks.
- Rootless podman and SELinux with WSLg mounts.
- Whether a tiling compositor (GNOME) honours `--window-size`; the CDP
  override holds the layout either way.
