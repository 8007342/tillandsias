## ADDED Requirements

### Requirement: `pty.attach@v1` capability advertises PTY multiplexing

The `Hello` and `HelloAck` envelopes SHALL advertise `pty.attach@v1` in their `capabilities` field when the peer implements the PTY-attachment extension defined below. A peer that does NOT advertise this capability SHALL NOT receive `PtyOpen`, `PtyData`, `PtyResize`, or `PtyClose` envelopes. Senders SHALL check the peer's advertised capabilities before transmitting any `Pty*` variant.

@trace spec:vsock-transport

#### Scenario: Capability advertised on Hello
- **WHEN** a host with PTY support sends `Hello`
- **THEN** the `capabilities` vector SHALL contain `"pty.attach@v1"`

#### Scenario: Capability absent suppresses Pty envelopes
- **WHEN** a host sends `Hello` without `"pty.attach@v1"`
- **AND** the guest receives a `PtyOpen` request internally for that connection
- **THEN** the guest SHALL log the suppression with `spec = "vsock-transport"` and SHALL NOT transmit any `Pty*` variant on that connection

#### Scenario: Mixed-capability negotiation
- **WHEN** the host advertises `"pty.attach@v1"` but the guest does not
- **THEN** the host SHALL surface a user-facing reason "guest does not support interactive terminal attach"
- **AND** the menu items that depend on PTY (Open Shell, --opencode) SHALL be disabled with that reason

### Requirement: `ControlMessage` gains four PTY variants

The `ControlMessage` enum SHALL be extended with the following variants, in a postcard-compatible additive position (existing decoders treat them as unknown variants and SHALL NOT panic):

```rust
PtyOpen {
    session_id: u32,
    rows: u16,
    cols: u16,
    argv: Vec<String>,
    env: Vec<(String, String)>,
    cwd: Option<String>,
}
PtyData {
    session_id: u32,
    direction: PtyDirection, // ToGuest | ToHost
    bytes: Vec<u8>,
}
PtyResize {
    session_id: u32,
    rows: u16,
    cols: u16,
}
PtyClose {
    session_id: u32,
    exit: PtyExit, // { code: i32, signal: Option<i32> }
}
```

@trace spec:vsock-transport

#### Scenario: PtyOpen launches subprocess in VM
- **WHEN** the host sends `PtyOpen { session_id: 1, rows: 24, cols: 80, argv: ["/bin/bash"], env: [("TERM","xterm-256color")], cwd: None }`
- **THEN** the guest SHALL allocate a PTY pair, fork `/bin/bash` with that PTY as its controlling tty
- **AND** the guest SHALL begin emitting `PtyData { session_id: 1, direction: ToHost, bytes: ... }` as the child writes
- **AND** the child SHALL inherit `TERM=xterm-256color` and no other environment variables

#### Scenario: PtyData echoes user input to guest
- **WHEN** the host sends `PtyData { session_id: 1, direction: ToGuest, bytes: b"ls\n" }`
- **THEN** the guest SHALL write those bytes to the master side of the PTY
- **AND** the child shell SHALL receive them as if typed at the terminal

#### Scenario: PtyResize updates window dimensions
- **WHEN** the user resizes their host terminal window and the host sends `PtyResize { session_id: 1, rows: 50, cols: 200 }`
- **THEN** the guest SHALL invoke `ioctl(pty_fd, TIOCSWINSZ, ...)` with the new dimensions
- **AND** the in-VM child SHALL receive `SIGWINCH`

#### Scenario: PtyClose signals graceful exit
- **WHEN** the in-VM child exits with status 0
- **THEN** the guest SHALL emit `PtyClose { session_id: 1, exit: { code: 0, signal: None } }`
- **AND** SHALL stop forwarding any further bytes for `session_id: 1`

#### Scenario: Host-initiated PtyClose terminates the subprocess
- **WHEN** the host sends `PtyClose { session_id: 1, exit: { code: 0, signal: None } }` (host-initiated)
- **THEN** the guest SHALL send `SIGTERM` to the in-VM child
- **AND** SHALL escalate to `SIGKILL` after a 2-second grace period if the child has not exited

### Requirement: Session id is host-allocated, connection-scoped

`session_id: u32` SHALL be allocated by the host from a per-vsock-connection monotonic counter starting at 1. Id `0` is reserved for "no session". The guest SHALL echo the host's id verbatim on every reply. On vsock disconnect, all in-flight session ids SHALL be considered terminated by both peers; no cross-connection session continuity is provided.

@trace spec:vsock-transport

#### Scenario: First session id is 1
- **WHEN** the host opens its first PTY on a fresh connection
- **THEN** `PtyOpen.session_id` SHALL be `1`

#### Scenario: Concurrent sessions get distinct ids
- **WHEN** the host has session 1 open and opens a second concurrent PTY
- **THEN** `PtyOpen.session_id` SHALL be `2`
- **AND** the guest SHALL maintain two independent PTY pairs

#### Scenario: Reconnect terminates all sessions
- **WHEN** the vsock connection drops while sessions 1, 2, 3 are active
- **THEN** both host and guest SHALL release all PTY resources for those sessions
- **AND** the next session opened on the new connection SHALL start from id 1 again

### Requirement: `MAX_PTY_FRAME_BYTES` caps single `PtyData` payload

A new constant `MAX_PTY_FRAME_BYTES: usize = 65_536` SHALL be exported from `tillandsias-control-wire`. Senders SHALL chunk PTY streams larger than this into multiple `PtyData` envelopes. Receivers SHALL reject any `PtyData` whose `bytes` field exceeds this constant by closing the connection with `TransportError::MessageTooLarge`. `MAX_PTY_FRAME_BYTES` SHALL be less than `MAX_MESSAGE_BYTES` to guarantee the envelope itself fits within the existing transport ceiling.

@trace spec:vsock-transport

#### Scenario: 256 KiB stream chunks into four frames
- **WHEN** the in-VM child writes 256 KiB in one syscall to the PTY
- **THEN** the guest SHALL emit four `PtyData` envelopes with 65,536 bytes each (the last possibly smaller)
- **AND** in-order delivery SHALL be preserved by the vsock connection

#### Scenario: Oversized frame closes connection
- **WHEN** a malformed peer sends `PtyData { bytes: <70 KiB> }`
- **THEN** the receiver SHALL close the connection with `TransportError::MessageTooLarge`
- **AND** SHALL log the violation with `spec = "vsock-transport"`

### Requirement: PTY-traffic does not starve control-plane envelopes

The host's vsock connection writer SHALL schedule pending control envelopes and per-session PTY queues fairly such that no `ControlMessage` variant other than `PtyData` is delayed by more than 250 ms when at least one PTY stream is saturating the connection. The scheduler implementation MAY use `tokio::select!` with a bias for non-`PtyData` variants.

@trace spec:vsock-transport

#### Scenario: Status request during PTY storm
- **WHEN** a `PtyData` stream is writing at line-rate
- **AND** the host injects a `VmStatusRequest`
- **THEN** the guest SHALL receive and respond to `VmStatusRequest` within 250 ms
- **AND** the `PtyData` stream SHALL continue (no deadlock)

### Requirement: PTY environment is an explicit allowlist

`PtyOpen.env` SHALL contain only the environment variables the host explicitly opts in to forward. The guest SHALL NOT inherit any host environment variable that is not present in `PtyOpen.env`. The default forward list for tray-spawned PTYs SHALL be `["TERM", "LANG", "LC_ALL", "COLORTERM"]`; other variables (including `PATH`, `HOME`, `USER`) SHALL be set by the guest's in-VM defaults, not inherited.

@trace spec:vsock-transport, spec:tillandsias-vault

#### Scenario: Token-bearing variables are not forwarded
- **WHEN** the host has `GH_TOKEN` set in its environment
- **AND** the tray opens an Open Shell session
- **THEN** `PtyOpen.env` SHALL NOT contain a `GH_TOKEN` entry
- **AND** the in-VM child SHALL NOT see `GH_TOKEN` in its environment

#### Scenario: Allowlisted variables flow through
- **WHEN** the host has `TERM=xterm-256color COLORTERM=truecolor`
- **AND** the tray opens an Open Shell session
- **THEN** `PtyOpen.env` SHALL contain both entries
- **AND** the in-VM child SHALL inherit them

## ADDED Invariants

### Invariant: PTY variants share the control connection
- **ID**: vsock-transport.invariant.pty-shares-control-connection
- **Expression**: `connection.port == CONTROL_WIRE_VSOCK_PORT for all PtyOpen/PtyData/PtyResize/PtyClose`
- **Measurable**: true

### Invariant: PTY frame size respects `MAX_PTY_FRAME_BYTES`
- **ID**: vsock-transport.invariant.pty-frame-size-bounded
- **Expression**: `pty_data.bytes.len() <= MAX_PTY_FRAME_BYTES for all PtyData frames on the wire`
- **Measurable**: true

### Invariant: Session id is connection-scoped
- **ID**: vsock-transport.invariant.pty-session-id-connection-scoped
- **Expression**: `forall session_id S: lifetime(S) is_subset_of lifetime(vsock_connection)`
- **Measurable**: true
