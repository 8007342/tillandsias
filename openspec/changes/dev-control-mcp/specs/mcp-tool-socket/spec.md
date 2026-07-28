# mcp-tool-socket — capability (retro-spec of the order-363 NDJSON MCP transport, with the order-505 per-lane model)

## ADDED Requirements

### Requirement: Per-lane socket location, permissions, and lifecycle

The tray SHALL serve the MCP tool surface over per-lane Unix domain
sockets: for each launched lane `(project, instance)` it SHALL bind
`$XDG_RUNTIME_DIR/tillandsias/mcp/<project>-<instance>/mcp.sock` (falling
back to `/run/user/<uid>` when `XDG_RUNTIME_DIR` is unset), mode `0600`,
and SHALL bind-mount ONLY that lane's subdirectory into that lane's forge
container at `/run/host/tillandsias-mcp` (read-only), with
`TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias-mcp/mcp.sock` naming the
in-forge path. The DIRECTORY — never the socket file — is mounted, so a
tray restart's re-bind stays visible inside an already-running forge. Stale
sockets from a previous tray instance SHALL be unlinked before bind.

The pre-order-505 layout (one shared `tillandsias/mcp/mcp.sock` mounted
into every forge of every project) is the documented legacy hazard this
requirement replaces: it allowed any in-forge agent to reach the socket
under any project's name.

#### Scenario: Lane launch mounts only its own subdirectory
- **WHEN** the tray launches a forge for lane `(alpha, w1)` while lane
  `(beta, w2)` is also running
- **THEN** the `alpha`-`w1` forge SHALL see exactly one socket,
  `/run/host/tillandsias-mcp/mcp.sock`, backed by the host path
  `…/tillandsias/mcp/alpha-w1/mcp.sock`
- **AND** no mount in the `alpha`-`w1` forge SHALL expose any other lane's
  socket directory

#### Scenario: Tray restart re-bind stays visible
- **WHEN** the tray restarts while a forge is running
- **THEN** the tray SHALL unlink and re-bind each lane socket inside the
  still-mounted per-lane directory
- **AND** the running forge SHALL be able to reconnect without a container
  restart

### Requirement: Attribution is listener-derived; peer environment is untrusted, permanently

The identity `(project, instance)` of every MCP connection SHALL be derived
from WHICH per-lane listener accepted it — kernel/filesystem-enforced,
unforgeable, requiring zero `/proc` reads — and SHALL map to exactly one
container name that the tray itself chose at launch. The peer's process
environment (`/proc/<pid>/environ`, `TILLANDSIAS_PROJECT`, or any other
peer-asserted value) SHALL NOT be used for attribution of any tool call:
environ is self-asserted at execve (red-team PoC:
`env TILLANDSIAS_PROJECT=attacker-wins …`), and the host never injects an
instance identity into forge containers, so environ-derived identity is
both forgeable and incomplete. Any project label the identity is compared
against SHALL be validated by EQUALITY against the tray's enumerated local
projects — never by sanitizing — before use in any container name or host
path construction.

A connection that cannot be attributed to a lane SHALL receive exactly one
JSON-RPC error object (code `-32000`, message naming the attribution gate)
and the connection SHALL then be closed — deny loudly, then fail closed.

#### Scenario: Forged environ does not change identity
- **WHEN** a process inside lane `(alpha, w1)`'s forge execs a client with
  `TILLANDSIAS_PROJECT=beta` in its environment and calls a tool over its
  lane socket
- **THEN** the tray SHALL attribute the call to `(alpha, w1)` — the
  accepting listener — and the forged variable SHALL have no effect

#### Scenario: Unattributable peer is denied once, loudly
- **WHEN** a connection arrives that the tray cannot map to a launched lane
- **THEN** the tray SHALL write one `-32000` error object and close the
  connection
- **AND** SHALL log the denial

### Requirement: NDJSON JSON-RPC framing

The transport SHALL be newline-delimited JSON-RPC 2.0: exactly one JSON-RPC
object per line in each direction. Notifications (`notifications/*`) SHALL
be absorbed silently — no reply line, per JSON-RPC 2.0. A line that fails
to parse as JSON SHALL be answered with error `-32700` (id `null`, message
naming the one-object-per-line contract). Empty lines SHALL be skipped.
EOF SHALL end the connection gracefully. There is no server-push
notification convention on this transport: multi-step operations MUST be
modelled as ticket-issue + poll, never as progress notifications.

#### Scenario: One request line, one response line
- **WHEN** a client writes `{"jsonrpc":"2.0","id":1,"method":"tools/list"}` followed by a newline
- **THEN** the server SHALL write exactly one line containing the JSON-RPC
  response with `id` 1

#### Scenario: Parse error
- **WHEN** a client writes a non-JSON line
- **THEN** the server SHALL reply with error code `-32700` and id `null`
- **AND** the connection SHALL remain open

### Requirement: Method surface and protocolVersion negotiation

The server SHALL handle `initialize`, `tools/list`, `tools/call`, and
`notifications/*`; every other method SHALL be answered with `-32601`
("Method not found"). `initialize` SHALL perform MCP version negotiation:
if the client's requested `protocolVersion` is in the server's supported
set, the server SHALL echo it; otherwise the server SHALL answer with its
latest supported revision. The supported set SHALL include `2024-11-05`
(the revision existing in-forge clients were written against) and the
latest SHALL be `2025-06-18`. The latest-supported revision SHALL be
sourced from a single shared constant used by BOTH host MCP surfaces (this
socket and the host-browser-mcp bridge), so the historical drift — this
transport pinning `2024-11-05` while host-browser-mcp speaks `2025-06-18`
— cannot recur. `serverInfo.name` SHALL identify the tray host-services
server; tool results SHALL keep the existing bare-JSON `result` object
shape (retro-specified as-is; this surface predates MCP content arrays and
its clients depend on the current shape).

#### Scenario: Client requests the latest revision
- **WHEN** a client sends `initialize` with `protocolVersion` `2025-06-18`
- **THEN** the server SHALL answer `protocolVersion` `2025-06-18`

#### Scenario: Legacy client requests 2024-11-05
- **WHEN** a client sends `initialize` with `protocolVersion` `2024-11-05`
- **THEN** the server SHALL answer `protocolVersion` `2024-11-05`
- **AND** the tool surface SHALL be identical to the latest revision's

#### Scenario: Unknown revision falls back to latest
- **WHEN** a client sends `initialize` with `protocolVersion` `2099-01-01`
- **THEN** the server SHALL answer `protocolVersion` `2025-06-18`

### Requirement: Baseline tool surface (order 363, retro-specified)

`tools/list` SHALL return the baseline host-services tools —
`publish_local`, `service_status`, `service_stop` — for every attributed
connection. The project a tool acts on SHALL come from the SESSION (the
listener-derived identity), never from request arguments: a forge cannot
publish or stop another project's service by naming it. `tools/call` with
an unknown tool name SHALL be answered with `-32601` ("Unknown tool") —
the same shape used for every tool that does not exist for this
connection. Tool argument schemas are ADVERTISEMENT, not enforcement: the
server SHALL dispatch through an explicit match with a default-deny arm
before any name or path construction.

#### Scenario: publish_local is session-scoped
- **WHEN** lane `(alpha, w1)` calls `publish_local` with `category: "WEB"`
- **THEN** the tray SHALL publish project `alpha`'s worktree and return its
  `www.alpha.localhost` URL
- **AND** no request argument SHALL select a different project

#### Scenario: Unknown tool
- **WHEN** an attributed client calls tool `frobnicate`
- **THEN** the server SHALL reply `-32601` with message naming the unknown
  tool

### Requirement: Control-plane separation

The postcard control socket (`control.sock` — VmShutdownRequest,
IssueWebSession, credential delivery, the full host control plane) SHALL
NEVER be mounted into forge containers. Only the per-lane MCP tool socket
directory crosses the container boundary; the MCP socket SHALL carry only
the JSON-RPC tool surface. The repository — including the postcard wire
format — is checked out inside every forge, so exposing `control.sock`
would hand agent code the entire control plane.

#### Scenario: Forge mounts exclude control.sock
- **WHEN** any forge container is launched
- **THEN** its mounts SHALL include the lane's MCP socket directory and
  SHALL NOT include `control.sock` or its parent directory
