## MODIFIED Requirements

### Requirement: Framing and handshake are identical to the Unix-socket transport

The vsock transport SHALL reuse the existing `tillandsias-control-wire`
framing without modification: 4-byte big-endian `u32` length prefix followed
by a `postcard`-serialised `ControlEnvelope`. `MAX_MESSAGE_BYTES` and
`MAX_MCP_FRAME_BYTES` SHALL retain their current values. The `Hello`/`HelloAck`
handshake SHALL carry `wire_version` AND `wire_version_min` on both sides. A
connection SHALL be accepted when the peers' `[wire_version_min, wire_version]`
ranges intersect, and both sides SHALL speak the highest common version. A
peer outside the window SHALL be refused before `HelloAck` with
`refused:wire:incompatible:<peer-range>:<self-range>`, and the host SHALL
surface the drain-then-swap remedy (stop lanes, hot-install the guest
binary). Test fixtures SHALL reference the `WIRE_VERSION` constants rather
than literals. Framing and message shapes SHALL be byte-for-byte identical to
the Unix-socket variant.

@trace spec:vsock-transport

#### Scenario: Same encoder/decoder serves both transports
- **WHEN** the encoder code path is inspected
- **THEN** the same `encode` and `decode` functions SHALL serve both Unix and
  vsock streams
- **AND** the transport difference SHALL be isolated to `connect()` / `bind()`
  only

#### Scenario: Overlapping windows connect
- **WHEN** the host offers `[3,5]` and the guest offers `[4,4]`
- **THEN** the session runs at wire version 4.
- Pre-fix result: FAILS — any inequality is fatal (`vsock_server.rs:949`,
  `pty_vsock_bridge.rs:229`, `vsock_client.rs:182`).

#### Scenario: Disjoint windows refuse with the remedy
- **WHEN** the host offers `[5,6]` and the guest offers `[2,4]`
- **THEN** the host logs `refused:wire:incompatible:[2,4]:[5,6]`, closes
  before sending `HelloAck`, and the tray shows the guest-upgrade remedy; no
  other envelope is sent.
- Pre-fix result: FAILS on the message — the mismatch is logged as
  "rejecting vsock client with mismatched wire version" with no remedy.

#### Scenario: Fixtures use the constant
- **WHEN** `grep -n "wire_version: 2" crates/tillandsias-headless/src/control_dispatch.rs` runs
- **THEN** it finds nothing.
- Pre-fix result: FAILS — two hits (`:268`, `:618`).

#### Scenario: Message size enforcement
- **WHEN** a peer sends a framed message larger than `MAX_MESSAGE_BYTES`
- **THEN** the receiver SHALL abort the connection before decoding the body
- **AND** SHALL log the abort with `spec = "vsock-transport"`
