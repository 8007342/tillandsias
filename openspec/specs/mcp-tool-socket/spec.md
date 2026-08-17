# mcp-tool-socket Specification

## Status

status: active

## Purpose
Define the per-lane Unix-domain socket that carries MCP JSON-RPC between a
forge lane and the host tray, and the attribution model that makes a request
answerable *on behalf of a specific project*.

This surface is shared: it serves the host-services tool family
(`publish_local` / `service_status` / `service_stop`) and the browser family
(`browser.*`, see `host-browser-mcp`). It exists as its own spec because it
is the socket and its guarantees — not any one tool family — that the code in
`crates/tillandsias-headless/src/tray/mod.rs` traces
(`@trace spec:mcp-tool-socket`), and because its security properties
(attribution, isolation, permissions) are the ones an auditor needs to read
in one place.

Historical note: order 505 replaced an earlier design in which MCP rode
`ControlMessage::McpFrame` on the shared postcard control socket, attributing
frames by reading the peer process's `/proc` environ. That attribution is
forgeable. The supersession record lives in `host-browser-mcp`, which is where
the retired requirement was written.

## Requirements

### Requirement: Each lane is served by its own socket

The tray SHALL create one socket per lane at
`$XDG_RUNTIME_DIR/tillandsias/mcp/<project>-<instance>/mcp.sock` and bind-mount
that lane's directory — and only that directory — into the lane's container at
`/run/host/tillandsias-mcp`, exporting
`TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias-mcp/mcp.sock`.

The socket SHALL be created mode `0600` and its parent directory mode `0700`.

@trace spec:mcp-tool-socket

#### Scenario: One lane cannot reach another lane's socket

- **WHEN** two lanes of the same or different projects are running
- **THEN** each lane's container sees only its own lane directory at
  `/run/host/tillandsias-mcp`
- **AND** neither lane's socket node is reachable from the other's mount
  namespace

#### Scenario: Socket permissions are owner-only

- **WHEN** the tray starts a lane listener
- **THEN** the socket node is mode `0600` and its parent directory `0700`

### Requirement: Attribution is derived from the accepting listener

The project (and instance) a request acts on SHALL be derived from WHICH
LISTENER accepted the connection. The tray SHALL NOT read the project from
the request body, from the peer process's environment, or from any other
peer-supplied source.

A connection that cannot be attributed SHALL receive exactly one JSON-RPC
error (`-32000`) naming the attribution requirement, after which the
connection SHALL be closed — deny loudly, then fail closed.

A project label that is not among the host's enumerated local projects SHALL
be refused the same way. Labels SHALL be compared by EQUALITY, never
sanitized into validity.

@trace spec:mcp-tool-socket, spec:tray-host-control-socket

#### Scenario: An unattributable peer is denied and closed

- **WHEN** a connection arrives that the tray cannot attribute to a lane
- **THEN** the tray writes one `-32000` error naming listener attribution
- **AND** closes the connection without dispatching any tool

#### Scenario: A forged environment does not change attribution

- **WHEN** the peer process's environment claims a different project
- **THEN** the tray still serves the project the accepting listener owns

### Requirement: NDJSON framing with a bounded per-line payload

The wire format SHALL be newline-delimited JSON: exactly one JSON-RPC object
per line in each direction, with no envelope and no length prefix.

Each line SHALL be at most `MAX_MCP_FRAME_BYTES` (4 MiB) — the same ceiling
the retired `McpFrame` transport carried, because the ceiling is a property
of what MCP payloads contain (screenshots, large tool results) rather than of
which transport carries them.

The inbound limit SHALL be applied to the READ, not measured after a line has
been accumulated: measuring afterwards would let a peer allocate without
bound, which is what the ceiling exists to prevent.

An oversized inbound line SHALL be refused with `-32000 RequestTooLarge` and
the stream SHALL resync at the next newline, leaving the connection usable. An
oversized outbound response SHALL be replaced by `-32000 ResponseTooLarge`
carrying the originating request's `id`.

@trace spec:mcp-tool-socket, spec:host-browser-mcp

#### Scenario: An oversized line is refused and the stream resyncs

- **WHEN** a peer writes a line longer than the ceiling
- **THEN** the tray replies `-32000` with a message beginning
  `RequestTooLarge:`
- **AND** the next well-formed request on that connection is served normally

#### Scenario: An oversized response is replaced, not truncated

- **WHEN** a tool produces a result whose line would exceed the ceiling
- **THEN** the client receives `-32000 ResponseTooLarge` carrying the
  request's `id`
- **AND** the oversized payload is not written

### Requirement: One request in flight per connection

The lane transport SHALL read one line, serve it to completion, and only then
read the next. Responses therefore return in request order even when a client
pipelines requests.

There SHALL NOT be a concurrent-call limit on this surface while the
transport is sequential: a limit that cannot bind reads as protection while
providing none (order 779-dqsv removed exactly such a limit). A transport
that pipelines requests SHALL introduce its limit in the transport itself,
where it can bind, and SHALL pin it with a test that observes a rejection.

@trace spec:mcp-tool-socket

#### Scenario: Pipelined requests are answered in order

- **WHEN** a client writes several requests without reading replies
- **THEN** the tray answers them one per line in the order received

### Requirement: The socket carries both host-services and browser tools

`tools/list` on this socket SHALL advertise the host-services family
(`publish_local`, `service_status`, `service_stop`) together with the browser
family defined by `host-browser-mcp`, and `tools/call` SHALL dispatch each to
its owning implementation. The advertised set SHALL be derived from the
implementations themselves, so that what is advertised is what is dispatched.

Tool-level denials MAY use either JSON-RPC errors or the MCP
`result.isError` convention, per the owning family; a denial SHALL always
name its reason.

@trace spec:mcp-tool-socket, spec:host-browser-mcp

#### Scenario: An unknown tool is refused without closing the connection

- **WHEN** a client calls a tool name neither family implements
- **THEN** the tray replies `-32601` naming the unknown tool
- **AND** the connection remains open for further requests
