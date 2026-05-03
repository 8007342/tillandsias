<!-- @trace spec:tray-host-control-socket -->
# tray-host-control-socket Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-26-tray-host-control-socket/
annotation-count: 20

## Purpose

Establish a Unix-socket control plane for out-of-band communication between the tray process and tray-spawned containers (router, browser MCP, future control-plane consumers). Provides a single reviewable wire protocol, framed message format, and capability-based routing mechanism instead of ad-hoc communication channels for each new feature.

## Requirements

### Requirement: Socket Creation and Lifecycle

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

Messages sent over the socket SHALL use postcard binary serialization (no JSON) with length-prefixed framing:

1. Each message is a postcard-encoded Rust struct
2. Framing: 4-byte big-endian length prefix followed by the postcard-encoded message body
3. No length limit enforced at protocol level (backpressure managed by OS socket buffers)
4. Readers MUST handle EOF gracefully (container or client disconnects)

#### Scenario: Client sends a message to tray
- **WHEN** a container process writes a postcard-framed message to the socket
- **THEN** tray reads the length prefix and message body atomically
- **AND** deserializes the message into a strongly-typed enum

### Requirement: Message Types and Capability-Based Routing

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

- Malformed messages (deserialization failures) are logged and the connection is closed
- Socket read/write errors (EINTR, EPIPE, ECONNRESET) are logged but do not crash the tray
- If a consumer's channel fills (backpressure), the message is dropped and logged (not buffered indefinitely)
- Stale consumer channels are cleaned up on disconnection

#### Scenario: Malformed message arrives
- **WHEN** a consumer sends an invalid postcard message
- **THEN** deserialization fails and the connection is closed
- **AND** an error is logged (no crash)

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
