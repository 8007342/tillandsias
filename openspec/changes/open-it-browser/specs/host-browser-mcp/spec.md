## MODIFIED Requirements

### Requirement: Browser provider is bundled Chromium only
<!-- req-id: 9b03bb93 -->

`browser.open` SHALL launch ONLY a Tillandsias browser engine CONTAINER: the
`tillandsias-chromium-framework` image by default, or another engine permitted
by `spec:browser-window-modes`, such as the WebKit container or the opt-in macOS
Safari appliance guest VM. Chromium SHALL NEVER run as a host process. That
includes a binary downloaded to `~/.cache/tillandsias/chromium/` and one named
by `TILLANDSIAS_BROWSER_BIN`. The host-Chromium download path of
`host-chromium-on-demand` is retired for `browser.open`. System Chrome, Safari,
Firefox, Edge, or any other host-installed browser SHALL NOT be used.

If the engine image is missing, or the host lacks the display or isolation the
engine needs (for example no Wayland socket), `browser.open` SHALL return MCP
tool error
`{ isError: true, content: [{ type: "text", text: "BROWSER_UNAVAILABLE: <reason>" }] }`
without launching anything. `<reason>` names what is missing.

Operator direction 2026-10-12 (`plan/issues/research/open-it-browser-2026-10-12.md`):
a browser window must be "a 100% separate space from their personal accounts";
order 1649-xqet moved `browser.open` into the container.

@trace spec:host-browser-mcp, spec:browser-isolation-tray-integration, spec:browser-window-modes

#### Scenario: No browser runs on the host

- **WHEN** the user has Google Chrome installed at a system path, a Chromium
  binary exists under `~/.cache/tillandsias/chromium/`, AND `browser.open` is called
- **THEN** the tray starts a browser engine container, not a host process
- **AND** neither the system Chrome nor the cached binary is executed
- **AND** the container starts from a fresh ephemeral profile, so cookies and
  localStorage from the user's daily browser cannot leak into the window

#### Scenario: Engine unavailable returns BROWSER_UNAVAILABLE

- **WHEN** the engine image is absent or the host has no Wayland socket
- **AND** an agent calls `browser.open`
- **THEN** the tool result has `isError: true` and contains the literal
  string `BROWSER_UNAVAILABLE`, naming the missing piece
- **AND** an accountability log entry records the failed launch with
  `category = "browser"`, `spec = "host-browser-mcp"`,
  `outcome = "browser-unavailable"`

### Requirement: Process-per-window with ephemeral profile
<!-- req-id: ef6ab932 -->

Each successful `browser.open(url)` call SHALL start a fresh engine container
(one window, one container) whose Chromium runs with the following
non-negotiable flags:

- `--app=<url>` — single-window app mode
- `--user-data-dir=<path on the container's tmpfs>` — ephemeral; destroyed
  with the container when the window closes
- `--incognito` — no persistent state
- `--no-first-run`
- `--no-default-browser-check`
- `--ozone-platform=wayland`
- `--remote-debugging-pipe` — CDP over the process's pipe, NEVER a TCP port

An in-container relay SHALL expose the CDP pipe on a Unix socket in a
host directory readable only by the tray. The tray SHALL attach a CDP client
over that socket, capture the first target id, and register the tuple
`(window_id, container_id, cdp_socket, target_id, owning_lane)` in an
in-process `WindowRegistry`. The `window_id` SHALL be a fresh UUID v4 with the
prefix `win-`. No host TCP listener SHALL exist for CDP
(`spec:browser-window-modes`).

A single engine container SHALL host exactly one window target. The MCP
server SHALL NOT use `Target.createTarget` to multiplex multiple windows
into a single container.

@trace spec:host-browser-mcp, spec:browser-window-modes

#### Scenario: Each open call starts its own container

- **WHEN** an agent calls `browser.open` twice for two different
  allowlisted URLs in the same project
- **THEN** the host has two distinct browser engine containers running
- **AND** the two profiles live on separate container tmpfs mounts with no
  shared files

#### Scenario: Ephemeral profile is deleted on window close

- **WHEN** an agent calls `browser.close(window_id)` OR the user closes
  the window manually OR the browser process exits for any reason
- **THEN** the window's container and its tmpfs profile are removed
  within 5 s
- **AND** the entry is removed from the `WindowRegistry`
- **AND** an accountability log entry records the cleanup

#### Scenario: No CDP TCP port

- **WHEN** a window is open
- **THEN** no host or container process listens on a TCP debugging port
- **AND** the CDP Unix socket lives in a tray-only host directory

## ADDED Requirements

### Requirement: A window plays sound and cannot record

A visible browser window on a Linux host SHALL play its page's audio on the
host speakers, through ONE more socket file: that of a dedicated
PulseAudio-protocol server the tray starts from a configuration shipped in
the binary (never an edit of the host's audio configuration). That server
SHALL refuse every record stream (microphone, and the monitor of any sink),
every module load, and source volume changes. The browser container SHALL NOT
mount the host's own pulse socket or any runtime directory. The server runs
only the PulseAudio-protocol module and no network module, and it exits with
the tray. The `browser.open` reply SHALL state the window's audio: playback,
or none and why. Headless windows, WSL2 windows and the macOS guest have no
audio and say so.

> Delta: on 2026-10-15 a game in a host-browser window was silent (packet
> 1722-2haw). `client.access = "restricted"` alone is not a boundary:
> WirePlumber grants restricted clients read access to every object, and a
> capture through it recorded the microphone.

Known residual: a page can LIST audio device names (metadata only, no
audio). Device names can fingerprint a host.

@trace spec:host-browser-mcp

#### Scenario: A page's tone reaches the speakers
- **WHEN** a page in a visible window plays a tone
- **THEN** a host-side capture of the default sink's monitor records it

#### Scenario: A page cannot record
- **WHEN** a page calls `getUserMedia({audio: true})`, even with the
  permission granted
- **THEN** the capture fails and no audio reaches the page
- **AND** a client of the window's audio socket that records the default
  source or a sink monitor is refused with 0 bytes, and load-module is refused
