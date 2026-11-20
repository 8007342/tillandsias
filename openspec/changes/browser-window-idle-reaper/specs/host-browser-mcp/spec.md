## ADDED Requirements

### Requirement: Idle browser windows are reaped
A window opened by `browser.open` that is headless, or in development mode, and that receives no CDP command through the MCP server and no user input for the idle limit MUST be stopped together with its forwarder container and its network.
- The idle limit defaults to 15 minutes and MUST be configurable through `TILLANDSIAS_BROWSER_IDLE_MINUTES`; `0` disables it.
- Every tool call that names a window MUST count as that window's activity.
- A development-mode window MUST record user input through a page listener, so a window a person is using is not reaped.
- After a reap, the owning lane's next call that names the window MUST answer `browser.closed:idle`.
- A headed window not in development mode runs no page script and is not idle-reaped; its 48 h lifetime still bounds it.

@trace spec:host-browser-mcp

#### Scenario: An idle headless window is stopped
- **WHEN** a headless window receives no tool call and no input for longer than the idle limit
- **THEN** its window container, forwarder and network are stopped
- **AND** the next call naming it answers `browser.closed:idle`

#### Scenario: An active window survives
- **WHEN** a window received a tool call within the idle limit
- **THEN** the reaper leaves it running

### Requirement: The agent is told to close its windows
The `browser.open` result MUST carry a `lifecycle` hint, and the `browser.open` and `browser.close` tool descriptions and the forge's browser instructions MUST say "close it with browser.close when you are done". `browser.close` MUST stop the window container and its forwarder.

@trace spec:host-browser-mcp

#### Scenario: The open result names the close affordance
- **WHEN** `browser.open` returns a window
- **THEN** its result contains the close-when-done instruction and names `browser.closed:idle`
