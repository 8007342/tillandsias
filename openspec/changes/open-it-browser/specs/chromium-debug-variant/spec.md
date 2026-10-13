## MODIFIED Requirements

### Requirement: Unrestricted domain access
<!-- req-id: 8eb9c8c5 -->

The debug variant gives FULL BROWSER CONTROL, NOT FULL INTERNET (coordinator
ruling on the operator's "full access" for development mode, 2026-10-12).
"Unrestricted" applies to what an agent may do to the browser. It does not
apply to where the browser may connect. The debug-variant browser MUST reach
every route of its own project, on any path and on the project's mapped ports,
including the local-preview TLS port. It MUST keep the network confinement of
`spec:browser-window-modes`:
- the per-window internal network;
- the SNI-bound forwarder;
- resolver pinning to the project's own `*.<project>.localhost` names.

It MUST NOT reach the public internet, other projects, host loopback services
or LAN addresses.

@trace spec:chromium-debug-variant, spec:browser-window-modes

#### Scenario: Any route of the own project is allowed
- **WHEN** the agent navigates the debug browser to any path of any
  `*.<project>.localhost` route of its own project, including the preview TLS port
- **THEN** the request MUST be allowed and reach the route

#### Scenario: Off-project destinations stay unreachable
- **WHEN** the debug browser navigates to a public domain, another project's
  route, `localhost:9000`, or `192.168.1.100:8080`
- **THEN** the navigation MUST fail
- **AND** debug mode MUST NOT have widened the window's network relative to
  normal mode

### Requirement: DevTools and console access
<!-- req-id: 393cad3c -->

Chromium DevTools MUST be enabled for debugging and inspection, and the full
Chrome DevTools Protocol MUST be available to the agent lane that owns the
window. CDP is reached only through the tray-brokered per-lane Unix socket of
`spec:browser-window-modes`, as typed tools or raw `browser.cdp`, or through a
`cdp.sock` mounted only into the owning lane. CDP MUST NOT be exposed on a
TCP port, on the host or in the container (`--remote-debugging-pipe`, never
`--remote-debugging-port`).

Full CDP means the agent can read the window's session state, including
cookies and storage set by a login (for example an OTP login to the project's
own app). This is accepted for development mode, MUST be stated in the tool
description, and is scoped to the owning lane. Other lanes get
`WINDOW_NOT_FOUND`, and the state dies with the ephemeral profile.

@trace spec:chromium-debug-variant, spec:browser-window-modes

#### Scenario: DevTools opens via keyboard
- **WHEN** the user presses `F12` or `Ctrl+Shift+I`
- **THEN** the DevTools panel MUST open
- **AND** Network, Console, Elements, Application tabs MUST all be available

#### Scenario: Remote DevTools over CDP
- **WHEN** a test framework in the owning lane connects through the brokered
  socket or the lane's mounted `cdp.sock`
- **THEN** the connection MUST be accepted
- **AND** full protocol access MUST be available (DOM manipulation, network capture, execution)
- **AND** no TCP debugging port exists on the host or in the container

#### Scenario: Cookies are readable only by the owning lane
- **WHEN** the owning lane calls `Network.getCookies` after a login in the window
- **THEN** the session cookies are returned
- **AND** the same call from another lane returns `WINDOW_NOT_FOUND`

#### Scenario: Console access
- **WHEN** the user opens the browser console (DevTools → Console)
- **THEN** full access to JavaScript console MUST be available
- **AND** the user MUST be able to execute arbitrary JavaScript in the page context
- **AND** console errors and logs MUST be visible
