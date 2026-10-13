## ADDED Requirements

### Requirement: Browser windows are 100% separate from the user's personal accounts

A browser window opened by Tillandsias MUST run in a space that is fully
separate from the user's personal browsers, profiles, keychains and accounts.
That space is either:
- a podman container, directly on Linux, in WSL2 on Windows, or in the tray's
  Linux VM on macOS; or
- a separate guest VM, such as the macOS Safari appliance.

A host browser process, a host browser profile, a separate host OS user, or a
private/InPrivate window MUST NOT be used to satisfy this. Every window MUST
start from an ephemeral profile and MUST NOT read or write the user's host
cookies, saved passwords, keychain or browser sync state. Engines MAY differ
per platform to use native hardware ("platforms may drift"). The separation
requirement MUST NOT differ.

@trace spec:browser-window-modes, spec:host-browser-mcp

#### Scenario: No host browser process
- **WHEN** `browser.open` succeeds on any platform
- **THEN** the browser process runs inside a container or a guest VM
- **AND** no browser process is a child of the host session outside them

#### Scenario: A weaker isolation is refused, not substituted
- **WHEN** a platform cannot provide a container or guest VM for an engine
- **THEN** that engine is unavailable on that host with a named reason
- **AND** Tillandsias does not fall back to a host browser, a separate host
  user or a private window

### Requirement: Wayland only, through one display-socket mount

On Linux and under WSLg, a browser window MUST display through Wayland only.
The container MUST receive exactly one display mount: the
`$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` socket file, mounted into a private
runtime dir. Chromium MUST run with `--ozone-platform=wayland`.

The following MUST NOT be mounted:
- the rest of `$XDG_RUNTIME_DIR`, which holds the podman socket, the tray
  control socket, the D-Bus session bus and the keyring;
- `/tmp/.X11-unix`;
- an Xauthority file.

There is no X11 fallback. Without a Wayland socket, `browser.open` MUST refuse
with an error that names Wayland as the requirement. It MUST NOT open an X11
window, even when `DISPLAY` is set (order 1641-xbvq).

@trace spec:browser-window-modes

#### Scenario: Only the Wayland socket is mounted
- **WHEN** a window is open
- **THEN** the container's mounts include the Wayland socket file and no other
  path from `$XDG_RUNTIME_DIR`
- **AND** no X11 socket directory is mounted

#### Scenario: No Wayland, no window
- **WHEN** `WAYLAND_DISPLAY` is unset or its socket is absent, and `DISPLAY` is set
- **THEN** `browser.open` returns an error naming the Wayland requirement
- **AND** no container is started

### Requirement: Each window reaches only its own project

Each window MUST run on its own `--internal` podman network. The only other
member of that network is a per-window forwarder bound to the project's SNI,
which relays to the router (order 1651-5t7n). The router MUST enforce that
the HTTP Host equals the TLS SNI. Chromium's host resolution MUST be pinned so
that only the project's own `*.<project>.localhost` names resolve, and every
other name fails.

The router CA is trusted inside the container by SPKI pin
(`--ignore-certificate-errors-spki-list`). The host trust store MUST NOT be
touched. A window MUST NOT have general internet egress.

@trace spec:browser-window-modes, spec:local-web-preview

#### Scenario: Another project is unreachable
- **WHEN** a window for project `acme` navigates to `https://www.beta.localhost/`
- **THEN** the navigation fails
- **AND** the router logs no request for `beta`

#### Scenario: The internet is unreachable
- **WHEN** a window navigates to a public host
- **THEN** the navigation fails to resolve or connect

### Requirement: The window is the device's CSS viewport at host scale, plus CDP emulation

A window opened with a device preset (`spec:device-presets`) MUST be opened
with `--app=<url>` and `--window-size=W,H`, where W and H are the preset's CSS
viewport at the HOST scale factor, not multiplied by the device's DPR. The
device behaviour MUST then be applied over CDP:
- `Emulation.setDeviceMetricsOverride{width, height, deviceScaleFactor, mobile}`;
- `Emulation.setUserAgentOverride`, with client-hint metadata where the
  preset has it;
- `Emulation.setTouchEmulationEnabled{maxTouchPoints}`;
- `Emulation.setEmitTouchEventsForMouse` for touch presets.

These overrides last only while a CDP session is attached. The tray MUST hold
one CDP session per window for the window's lifetime and MUST auto-attach
popups. `browser.set_device{window_id, device}` MUST switch a live window
without reopening it. The override MUST hold the layout even when a tiling
compositor ignores `--window-size`.

@trace spec:browser-window-modes, spec:device-presets

#### Scenario: The page sees the device
- **WHEN** `browser.open{url, device: "iphone 12 pro max"}` opens a window
- **THEN** in the page `innerWidth` is 428, `devicePixelRatio` is 3 and
  `navigator.maxTouchPoints` is greater than 0

#### Scenario: Switching live
- **WHEN** `browser.set_device` switches that window to "galaxy s24"
- **THEN** the same evaluation returns the Galaxy S24's numbers without the
  window being reopened

### Requirement: Development mode is full browser control, not full internet

`browser.open{…, dev: true}` opens a window in development mode.

- **Transport.** Chromium MUST run with `--remote-debugging-pipe`, never with a
  TCP debugging port. An in-container relay exposes the pipe on a Unix socket
  in a host directory that only the tray can read.
- **Brokered tools.** The tray brokers the window over the requesting lane's
  peer-authenticated MCP socket (`spec:mcp-tool-socket`). It provides typed
  tools (navigate, evaluate, console and network tails, screenshot, emulate)
  and raw `browser.cdp{window_id, method, params, sessionId?}`, which forwards
  any CDP method.
- **Direct CDP.** On request, a `cdp.sock` MAY be mounted only into the owning
  lane's `/run/host/tillandsias-mcp/`, for Playwright or Puppeteer.
- **Ownership.** A window belongs to the lane that opened it. Any other lane
  MUST get `WINDOW_NOT_FOUND` for it.
- **No host listener.** No host TCP listener may exist for CDP.
- **No widened network.** Development mode MUST NOT widen the window's
  network: the per-window network, forwarder and resolver pinning stay
  exactly as in normal mode.

Full CDP exposes the window's session state, including cookies set by a login
(for example an OTP login to the project's own app). This is accepted and
MUST be documented in the tool description. That state is scoped to the
owning lane and dies with the window's ephemeral profile.

@trace spec:browser-window-modes, spec:chromium-debug-variant, spec:mcp-tool-socket

#### Scenario: Raw CDP from the owning lane
- **WHEN** the lane that opened a dev-mode window calls
  `browser.cdp{window_id, method: "Runtime.evaluate", params: {expression: "1+1"}}`
- **THEN** the result carries the value 2

#### Scenario: Another lane cannot see the window
- **WHEN** a different lane calls any browser tool with that `window_id`
- **THEN** the result is `WINDOW_NOT_FOUND`

#### Scenario: No host listener
- **WHEN** a dev-mode window is open
- **THEN** the host's listening TCP sockets are the same as before it opened

#### Scenario: Dev mode does not reach the internet
- **WHEN** a dev-mode window or a `browser.cdp` `Page.navigate` targets a public host
- **THEN** the navigation fails as it would in normal mode

### Requirement: Engines and isolation per platform

Each platform MUST provide the engines below, inside the isolation named for
it. Platforms MAY add engines later, under the separation requirement.

| | Linux | Windows | macOS (Apple silicon) |
|---|---|---|---|
| Engines | Chromium (`tillandsias-chromium-framework`); Playwright WebKit for Apple presets | the Linux containers in WSL2; optionally Edge-for-Linux in a container, once its redistribution terms are checked | default: the Chromium and WebKit containers in the tray's Linux VM; opt-in: the Safari appliance |
| Isolation | rootless podman, Wayland socket only, per-window internal network | podman in WSL2, the WSLg Wayland socket only. Windows Sandbox and Hyper-V are Pro-only; a separate Windows user or an InPrivate window does not qualify | the Linux VM plus a container; the appliance is a separate macOS guest VM |
| Automation | CDP (Chromium); the Playwright protocol (WebKit) | same as Linux | same as Linux in the VM; the appliance uses safaridriver (W3C WebDriver), with `safari:useSimulator` for iOS presets |
| Window | one Wayland window per browser window | one window per browser window through WSLg | the guest display is sized to the device, and there is one view per device: a `cage` kiosk in the Linux VM, which needs a virtio-gpu display device, or the Simulator window in the appliance |

The WebKit engine MUST be labelled "WebKit (approximates Safari)" wherever it
is named to the user or agent. It MUST NOT be presented as Safari.

The macOS Safari appliance:
- is a separate macOS guest VM, distinct from the tray's Linux VM, running
  Safari and the iOS Simulator;
- MUST be opt-in;
- MUST be off by default on floor-tier hosts;
- reaches the project through a forwarder to the host router, because inside a
  guest `*.localhost` is the guest's own loopback;
- trusts the router CA in the guest's keychain only. The host keychain MUST
  NOT be touched.

@trace spec:browser-window-modes

#### Scenario: Apple preset on Linux
- **WHEN** an iPhone preset is opened on Linux with the WebKit engine available
- **THEN** the window runs in the WebKit container
- **AND** the engine is reported as "WebKit (approximates Safari)"

#### Scenario: Safari appliance stays opt-in
- **WHEN** a macOS host has not opted in, or is floor tier and has not
  explicitly opted in
- **THEN** no macOS guest VM is created
- **AND** Apple presets use the WebKit container in the Linux VM

#### Scenario: Windows uses WSLg
- **WHEN** `browser.open` runs on Windows
- **THEN** the browser runs in a container in WSL2 and displays through the
  WSLg Wayland socket
- **AND** no Windows-side browser process is started
