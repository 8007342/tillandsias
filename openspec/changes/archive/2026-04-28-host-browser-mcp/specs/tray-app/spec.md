# tray-app delta — host-browser-mcp

## ADDED Requirements

### Requirement: Tray hosts the browser MCP server in-process

The tray binary SHALL embed the `tillandsias-browser-mcp` MCP server as
an in-process module spawned at tray startup. The module SHALL register
a handler for the `ControlMessage::McpFrame { session_id, payload }`
variant on the existing host control socket and SHALL run for the full
tray lifetime, terminated only at graceful shutdown.

The server SHALL hold its `WindowRegistry` and per-session state in
process memory only — no file-on-disk persistence, no database. On
tray Quit the registry SHALL be drained: every chromium PID SHALL be
sent SIGTERM, then SIGKILL after a 5 s grace, and every ephemeral
`--user-data-dir` SHALL be removed before the tray process exits.

@trace spec:tray-app, spec:host-browser-mcp

#### Scenario: MCP module starts with the tray

- **WHEN** the tray binary starts and reaches its post-init phase
- **THEN** the in-process MCP module is registered as the dispatcher for
  the `McpFrame` variant on the control socket
- **AND** `WindowRegistry` is initialised empty
- **AND** the dispatcher accepts and processes a probe-frame round-trip
  in a startup self-test

#### Scenario: Tray Quit reaps every MCP-launched window

- **WHEN** the tray has launched N chromium windows via MCP and the user
  invokes Quit
- **THEN** every chromium PID receives SIGTERM
- **AND** any process still alive 5 s later receives SIGKILL
- **AND** every ephemeral `--user-data-dir` directory is removed
- **AND** the tray exits with status 0

### Requirement: ControlMessage adds an McpFrame variant

The `ControlMessage` enum defined under `tray-host-control-socket` SHALL
be extended with exactly one new variant `McpFrame { session_id: u64,
payload: Vec<u8> }` so the host control socket can carry MCP JSON-RPC
frames between the forge stub and the in-tray MCP module. The new
variant SHALL appear last in the enum to preserve the postcard variant
indices of all pre-existing variants.

```rust
ControlMessage::McpFrame {
    session_id: u64,
    payload: Vec<u8>,
}
```

The variant SHALL be appended at the end of the enum to preserve the
postcard variant indices of existing variants (per the additive-evolution
rule in `tray-host-control-socket`). The forge stub SHALL receive its
`session_id` in the first server-side response frame and SHALL echo the
same id on every subsequent frame from the same connection.

@trace spec:tray-app, spec:tray-host-control-socket, spec:host-browser-mcp

#### Scenario: McpFrame deserialises round-trip

- **WHEN** a forge stub writes a postcard-encoded
  `ControlMessage::McpFrame { session_id: 7, payload: vec![...] }`
- **THEN** the tray reader deserialises the variant correctly
- **AND** dispatches the `payload` to the MCP module for the same
  `session_id`
- **AND** writes the response back wrapped in another `McpFrame` with
  the same `session_id`

#### Scenario: Existing variants still deserialise after addition

- **WHEN** an `IssueWebSession` envelope is sent on the control socket
  AFTER the `McpFrame` variant has been added
- **THEN** the existing `IssueWebSession` handler still receives the
  variant correctly
- **AND** no postcard variant-index reshuffling has occurred

### Requirement: Tray maintains the PeerPid → ProjectLabel table

The tray SHALL maintain an in-memory
`HashMap<u32, ProjectLabel>` mapping every container PID it spawned
to the project label the container was spawned for. The map SHALL be
updated synchronously at three points:

1. On forge container spawn: insert `(child_pid, project_label)`.
2. On forge container exit (any cause): remove the entry.
3. On tray graceful shutdown: clear the entire table.

The MCP module SHALL look up the connecting peer's PID via
`SO_PEERCRED` (Linux) or the platform-equivalent peer-credential API
on every fresh control-socket connection that carries an `McpFrame`.
A PID not present in the table SHALL cause the connection to be closed
with `Error { code: UnauthorisedPeer }`.

@trace spec:tray-app, spec:host-browser-mcp, spec:podman-orchestration

#### Scenario: Forge spawn populates the table

- **WHEN** the tray spawns a forge container for project `acme`
- **THEN** `child.id()` is read into the table with value `"acme"`
- **AND** the insertion happens before the container's stdio is
  released for normal use (so a forge stub cannot connect with a PID
  the tray has not yet recorded)

#### Scenario: Forge exit removes the entry

- **WHEN** a forge container exits (clean stop OR crash OR Quit)
- **THEN** the `(pid, project_label)` entry is removed from the table
- **AND** subsequent MCP connections from a process that inherited
  the PID (PID reuse) are rejected as unknown peer

### Requirement: Tray emits the control-socket bind-mount for forge containers

For every forge container the tray spawns, the podman command SHALL
include `-v <host-control-socket-path>:/run/host/tillandsias/control.sock`
and SHALL set `TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias/control.sock`
in the container environment. This mirrors the existing
`tray-host-control-socket` requirement for declared consumers; this
delta promotes forge containers to the consumer set so the in-container
MCP stub can reach the socket.

The bind mount SHALL be added without relaxing
`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`,
or `--rm`.

@trace spec:tray-app, spec:host-browser-mcp, spec:enclave-network

#### Scenario: Forge container gets the control-socket mount

- **WHEN** the tray spawns a forge container for any project
- **THEN** the podman command line contains
  `-v <abs-path-to-control.sock>:/run/host/tillandsias/control.sock`
- **AND** the environment carries
  `TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias/control.sock`
- **AND** all four required security flags remain in effect

## Sources of Truth

- `cheatsheets/runtime/forge-container.md` — `/run/host/...` convention
  for host-provided sockets bind-mounted into the enclave.
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` —
  ephemeral `--user-data-dir` location category.
- `cheatsheets/runtime/networking.md` — `SO_PEERCRED` semantics for
  peer-credential authorisation.
- `cheatsheets/architecture/event-driven-basics.md` — in-process MCP
  module hooked into the tray's tokio runtime; no busy loops.
- `cheatsheets/web/mcp.md` — protocol shape the in-process module
  speaks. (NEW, this change.)
