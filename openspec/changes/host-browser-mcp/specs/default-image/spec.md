# default-image delta — host-browser-mcp

## ADDED Requirements

### Requirement: Forge image ships the host-browser MCP stub

The forge image SHALL ship a stdio↔control-socket bridge stub at
`/home/forge/.config-overlay/mcp/host-browser.sh`. The stub SHALL be
invoked by the agent's MCP runtime (OpenCode / Claude Code config) and
SHALL relay JSON-RPC frames between the agent's stdio and the host
control socket bound at `$TILLANDSIAS_CONTROL_SOCKET`
(`/run/host/tillandsias/control.sock`).

The stub SHALL:

1. Connect to `$TILLANDSIAS_CONTROL_SOCKET` (failing with a clear
   error message on stderr if the env var is unset or the socket is
   unreachable, so the agent reports the failure to the user).
2. Perform the `Hello`/`HelloAck` exchange per the
   `tray-host-control-socket` wire format, declaring capability
   `"BrowserMcp"`.
3. Read JSON-RPC frames from stdin (newline-delimited per the existing
   forge MCP convention used by `git-tools.sh`), wrap each as a
   `ControlMessage::McpFrame` postcard envelope length-prefixed with a
   4-byte big-endian length, and write to the socket.
4. Read response envelopes from the socket, unwrap the JSON-RPC payload,
   and write to stdout.
5. Exit cleanly when stdin EOFs OR the socket disconnects.

The stub MAY be implemented as a shell script using `socat` and
`printf`-based length prefixing if `socat` is reliably present in the
forge image; otherwise a tiny Rust binary (≤ 200 KB) baked into the
image SHALL be used. The choice is locked in tasks.md per design.md
Decision 9.

The OpenCode MCP config (`~/.config-overlay/opencode/config.json`)
SHALL register the stub as a `local` MCP server named `host-browser`
under `mcp`:

```json
"host-browser": {
    "type": "local",
    "command": ["/home/forge/.config-overlay/mcp/host-browser.sh"],
    "enabled": true
}
```

The Claude Code MCP config SHALL register the same stub under its
equivalent key, so both agent runtimes see the eight `browser.*` tools.

@trace spec:default-image, spec:host-browser-mcp, spec:tray-host-control-socket

#### Scenario: Stub launches and bridges a tools/list round trip

- **WHEN** an agent inside the forge invokes the configured `host-browser`
  MCP server
- **THEN** the stub connects to `$TILLANDSIAS_CONTROL_SOCKET`
- **AND** completes `Hello`/`HelloAck`
- **AND** an agent-issued `tools/list` reaches the host MCP module and
  the response — listing the eight `browser.*` tools — reaches the
  agent within 500 ms

#### Scenario: Stub fails clearly when env var is missing

- **WHEN** the stub is invoked in a context where
  `TILLANDSIAS_CONTROL_SOCKET` is unset or the socket file does not
  exist
- **THEN** the stub writes a one-line error to stderr naming the
  missing variable / unreachable path
- **AND** exits with a non-zero status
- **AND** writes a JSON-RPC error response on stdout for the in-flight
  `initialize` request so the agent's MCP client surfaces a clean
  failure rather than a 60 s timeout

#### Scenario: Stub disconnect on EOF

- **WHEN** the agent closes stdin (terminating the MCP server lifecycle)
- **THEN** the stub closes its socket connection cleanly within 1 s
- **AND** exits with status 0
- **AND** the host-side `WindowRegistry` retains any open windows per
  the host-browser-mcp window-survival requirement

## Sources of Truth

- `cheatsheets/runtime/forge-container.md` — `~/.config-overlay/`
  layout for forge agent configuration.
- `cheatsheets/web/mcp.md` — MCP `local` stdio server registration
  shape the forge config consumes. (NEW, this change.)
- `cheatsheets/runtime/networking.md` — `socat`-style Unix-socket
  bridging idioms used by the shell stub.
