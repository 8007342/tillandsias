<!-- @trace spec:tray-host-control-socket -->
# tray-host-control-socket Specification

## Status

active
promoted-from: openspec/changes/archive/2026-04-26-tray-host-control-socket/
annotation-count: 20

## Purpose

Establish a Unix-socket control plane for out-of-band communication between the tray process and tray-spawned containers (router, browser MCP, future control-plane consumers). Provides a single reviewable wire protocol, framed message format, and capability-based routing mechanism instead of ad-hoc communication channels for each new feature.

## Requirements

### Requirement: Socket Creation and Lifecycle
<!-- req-id: 09d88b25 -->

The tray process SHALL:

1. Create a Unix domain socket at `$XDG_RUNTIME_DIR/tillandsias/control.sock` (typically `/run/user/<uid>/tillandsias/control.sock`)
2. Set socket permissions to `0600` (readable and writable by the owning user only)
3. Listen for incoming connections on tray startup (after `Quit` signal is handled)
4. Remove the socket on tray shutdown (after `shutdown_all` completes)
5. On tray start, detect and unlink any stale socket left from a previous crashed instance

#### Scenario: Tray startup and shutdown
- **WHEN** tray process starts
- **THEN** control socket is created at the standard location with mode 0600
- **AND** stale sockets from previous crashes are cleaned up
- **WHEN** tray process quits
- **THEN** socket is removed after all container teardown completes

### Requirement: Wire Format and Framing
<!-- req-id: d2e56cbf -->

Messages sent over the socket SHALL use postcard binary serialization (no JSON) with length-prefixed framing:

1. Each message is a postcard-encoded Rust struct
2. Framing: 4-byte big-endian length prefix followed by the postcard-encoded message body
3. A single frame SHALL NOT exceed `MAX_MESSAGE_BYTES` (65,536), the one frame-size ceiling the control wire has (`crates/tillandsias-control-wire/src/lib.rs`). Both directions enforce it: a reader whose length prefix exceeds the ceiling closes the connection with a local `io::ErrorKind::InvalidData` and sends NO reply, and a writer refuses to emit an oversize frame rather than letting the peer kill the connection at the far end (order 828-r2ek). Backpressure below that ceiling is managed by OS socket buffers.
4. Readers MUST handle EOF gracefully (container or client disconnects)

CORRECTED 2026-08-25 (order 795-5itp). Clause 3 previously read "No length limit
enforced at protocol level (backpressure managed by OS socket buffers)". That was
false for as long as the code has existed — `read_control_envelope`
(`crates/tillandsias-headless/src/tray/mod.rs`) has always refused a prefix over
`MAX_MESSAGE_BYTES`. The contradiction is load-bearing rather than cosmetic: this
spec is what a reader consults before touching the framing, and it told them a
bound they would find in the code was not part of the protocol. A migration onto
`LengthDelimitedCodec` that trusted this text would have left `max_frame_length`
defaulted at 8 MiB and silently widened every reader here 128x.

#### Scenario: Client sends a message to tray
- **WHEN** a container process writes a postcard-framed message to the socket
- **THEN** tray reads the length prefix and message body atomically
- **AND** deserializes the message into a strongly-typed enum

### Requirement: Message Types and Capability-Based Routing
<!-- req-id: 89c005d3 -->

The control protocol defines a typed message enum that grows over time:

```
enum ControlMessage {
    Otp(OtpRequest),          // from: router, opencode-web-session-otp
    OpenBrowser(BrowserOpen), // from: future browser MCP
    // ... future message types
}
```

Each message type is registered with the tray-side router at startup. Unrecognized message types are dropped silently (forward compatibility). Messages are routed to typed channels (each consumer has its own mpsc channel), making dispatch O(1) and preventing unauthorized consumers from reading other message types.

#### Scenario: Router sends OTP message
- **WHEN** router needs to notify tray of an OTP event
- **THEN** router serializes an `ControlMessage::Otp(...)` and sends it over the socket
- **AND** the tray deserializes and routes the message to the Otp consumer
- **AND** other message types are not visible to the Otp consumer

### Requirement: Error Handling and Reliability
<!-- req-id: c0d1d805 -->

- Malformed messages (deserialization failures) are logged and the connection is closed
- Socket read/write errors (EINTR, EPIPE, ECONNRESET) are logged but do not crash the tray
- If a consumer's channel fills (backpressure), the message is dropped and logged (not buffered indefinitely)
- Stale consumer channels are cleaned up on disconnection

#### Scenario: Malformed message arrives
- **WHEN** a consumer sends an invalid postcard message
- **THEN** deserialization fails and the connection is closed
- **AND** an error is logged (no crash)

### Requirement: Login completion is a notification, not a poll
<!-- req-id: 75fdec30 -->

<!-- @trace order:679-rp9m -->
`tillandsias --github-login` SHALL send one `ControlMessage::GithubLoginStored { seq, ts_unix }`
envelope to the control socket AFTER its Vault write is verified, and the tray SHALL answer
`IssueAck { seq_acked: seq }`. The variant is a trailing, additive addition (no `WIRE_VERSION` bump);
it is routed on the unix socket only and is `Unsupported` on vsock.

A tray waiting for a login SHALL wait for that notification under ONE 120-second deadline and then
settle the login state from ONE Vault presence check, whether the notification arrived or not. It
SHALL NOT poll Vault periodically. The notification is best-effort: a login with no tray running, or
with a tray too old to decode the variant, SHALL still succeed and exit 0, reporting the missing
notification as a note.

Consumers: the Linux tray (implemented). The macOS and Windows trays consume the same message on
their own control surfaces (follow-up rows filed under 679-rp9m).

#### Scenario: A login confirmed by the notification
- **WHEN** the operator clicks GitHub login and completes `tillandsias --github-login`
- **THEN** the tray receives `GithubLoginStored`, acks it, and logs the login-confirmed event within 5 s of the Vault write

#### Scenario: No notification arrives
- **WHEN** no `GithubLoginStored` reaches the tray (the login ran outside the tray, or the CLI could not connect)
- **THEN** the tray's login wait ends at 120 s and one presence check decides the login state

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee` — socket lifecycle and capability-based message routing

Gating points:
- Control socket created at `$XDG_RUNTIME_DIR/tillandsias/control.sock` with mode 0600 at tray startup
- Stale sockets cleaned up on tray restart
- Postcard-framed messages routed to correct consumer based on message type enum
- Malformed messages cause connection close without tray crash
- Socket removed on tray shutdown after all containers cleaned up

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — the socket lives at `$XDG_RUNTIME_DIR/` (XDG runtime), ephemeral by design
- Project memory: `feedback_design_philosophy` — no JSON for IPC; postcard for internal messaging
