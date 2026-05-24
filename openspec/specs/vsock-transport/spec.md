<!-- @trace spec:vsock-transport -->
# vsock-transport Specification

## Status

proposed
phase: 2

## Purpose

Extend `tillandsias-control-wire` with a virtio-vsock transport so the
Windows and macOS host-side trays can talk to the in-VM
`tillandsias-headless` process. Today the control wire only listens on a Unix
domain socket at `$XDG_RUNTIME_DIR/tillandsias/control.sock`; that path is
Linux-only and does not survive an OS-VM boundary. vsock is the
host↔guest IPC primitive that works on both WSL2 (Hyper-V vsock) and macOS
Virtualization.framework (virtio-vsock).

The wire protocol — postcard envelope, 4-byte big-endian length prefix,
`WIRE_VERSION`, `MAX_MESSAGE_BYTES`, `MAX_MCP_FRAME_BYTES`, `Hello` /
`HelloAck` handshake — is unchanged. Only the listener and connector
plumbing is new.

This spec is part of the Windows + macOS host-shell design wave. See plan:
`/home/tlatoani/.claude/plans/stateless-riding-newt.md`.

Cross-references:
- `host-shell-architecture` — the consumer of this transport.
- `vm-idiomatic-layer` — the abstraction that sets up the VM's vsock device.
- `windows-native-tray`, `macos-native-tray` — the binaries that use the transport.

## Requirements

### Requirement: CID allocation contract
- **ID**: vsock-transport.cid.host-and-guest-allocation@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vsock-transport.invariant.host-cid-is-2, vsock-transport.invariant.guest-cid-is-stable-per-boot]

The host SHALL connect using CID `VMADDR_CID_HOST = 2` (the standard
host-side CID across both WSL2 and VZ). The in-VM headless SHALL listen on
CID `VMADDR_CID_ANY = -1` (binds on any local CID). The guest's own CID is
allocated by the hypervisor and is negotiable per backend:
- WSL2: the distro's CID is assigned by Hyper-V on boot; the host
  enumerates active distros via `hcsdiag list` (or the `tillandsias-vm-layer`
  WSL backend) and picks the CID for the `tillandsias` distro.
- VZ: the host SHALL set the guest's CID explicitly when constructing
  `VZVirtioSocketDeviceConfiguration` and SHALL reuse the same value across
  start/stop cycles for the lifetime of the host process.

@trace spec:vsock-transport

#### Scenario: Host connects from CID 2
- **WHEN** the host shell opens a vsock connection
- **THEN** the local address SHALL be `(cid=2, port=<ephemeral>)`
- **AND** the remote address SHALL be `(cid=<vm-cid>, port=42420)`

#### Scenario: Guest listens on VMADDR_CID_ANY
- **WHEN** the in-VM headless starts with `--listen-vsock 42420`
- **THEN** it SHALL call `bind` on a vsock socket with `sa_family = AF_VSOCK, svm_cid = VMADDR_CID_ANY, svm_port = 42420`
- **AND** it SHALL accept connections from any CID

#### Scenario: VZ guest CID is stable across restarts
- **WHEN** the macOS host stops and restarts the VM via `VmRuntime::stop` then `start`
- **THEN** the new VM SHALL be constructed with the same `cid` value that was used in the previous start
- **AND** the host shell SHALL connect to the same `(vm-cid, 42420)` tuple without rediscovery

### Requirement: Stable port `42420`
- **ID**: vsock-transport.port.stable-control-wire-port@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vsock-transport.invariant.port-constant-defined-in-control-wire]

The control wire SHALL use vsock port `42420` for the primary control
channel. The port number SHALL be exported as `pub const
CONTROL_WIRE_VSOCK_PORT: u32 = 42420;` from
`tillandsias-control-wire::transport`. Future additional vsock ports MAY be
allocated for log forwarding or MCP framing, but they SHALL also be exported
as named constants.

@trace spec:vsock-transport

#### Scenario: Port constant is the single source of truth
- **WHEN** the host shell and the in-VM headless are both updated to use a new port
- **THEN** only the constant in `tillandsias-control-wire::transport` SHALL change
- **AND** no hardcoded `42420` literals SHALL exist in the consuming crates

#### Scenario: Default port is reachable on a clean install
- **WHEN** a fresh host runs the tray and the VM boots
- **THEN** the host's `connect` to `(vm-cid, 42420)` SHALL succeed within 5s of the VM's `app.started` event
- **AND** no port collision SHALL occur (vsock port space is per-CID and isolated from TCP/UDP)

### Requirement: Framing and handshake are identical to the Unix-socket transport
- **ID**: vsock-transport.framing.protocol-unchanged@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vsock-transport.invariant.framing-shared-with-unix, vsock-transport.invariant.wire-version-1]

The vsock transport SHALL reuse the existing
`tillandsias-control-wire` framing without modification: 4-byte big-endian
`u32` length prefix followed by a `postcard`-serialised `ControlEnvelope`.
`WIRE_VERSION`, `MAX_MESSAGE_BYTES`, and `MAX_MCP_FRAME_BYTES` SHALL retain
their current values. The `Hello`/`HelloAck` handshake (client sends
`Hello { wire_version, client_kind }`; server replies `HelloAck { wire_version,
server_kind }`; mismatched versions abort the connection) SHALL be byte-for-byte
identical to the Unix-socket variant.

@trace spec:vsock-transport

#### Scenario: Same encoder/decoder serves both transports
- **WHEN** the encoder code path is inspected
- **THEN** the same `encode_envelope` and `decode_envelope` functions SHALL serve both Unix and vsock streams
- **AND** the transport difference SHALL be isolated to `connect()` / `bind()` only

#### Scenario: Handshake version mismatch aborts cleanly
- **WHEN** a client with `wire_version = 2` connects to a server with `wire_version = 1`
- **THEN** the server SHALL reply with `HelloAck { wire_version: 1, … }`
- **AND** the client SHALL detect the mismatch, close the connection with a structured `VersionMismatch` error, and surface the error in `MenuStructure.status_text`

#### Scenario: Message size enforcement
- **WHEN** a peer sends a framed message larger than `MAX_MESSAGE_BYTES`
- **THEN** the receiver SHALL abort the connection before decoding the body
- **AND** SHALL log the abort with `spec = "vsock-transport"`

### Requirement: New `ControlMessage` variants for VM lifecycle and remote enumeration
- **ID**: vsock-transport.messages.vm-lifecycle-additions@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vsock-transport.invariant.new-variants-postcard-stable, vsock-transport.invariant.no-tokens-in-messages]

The `ControlMessage` enum SHALL be extended with the following new variants:
- `VmStatusRequest` and `VmStatusReply { phase: VmPhase, ready: bool,
  podman_ready: bool, last_event: Option<String> }` where `VmPhase` is one
  of `Provisioning | Starting | Ready | Draining | Stopped | Failed`.
- `VmShutdownRequest { drain_timeout_ms: u32 }` (no reply — the response is
  observed by the connection closing).
- `EnumerateLocalProjects` and `LocalProjectsReply { entries: Vec<ProjectEntry> }`
  where `ProjectEntry` carries `{ name, path, git_remote, mtime_unix }`.
- `CloudRefreshRequest` and `CloudRefreshReply { repos: Vec<RemoteRepo>,
  rate_limit_remaining: u32 }`.

None of the new messages SHALL carry GitHub tokens, API keys, or other
long-lived secrets — credentials remain inside the VM (see
`tillandsias-vault`).

@trace spec:vsock-transport, spec:tillandsias-vault

#### Scenario: VmStatusReply surfaces all enclave readiness states
- **WHEN** the host shell sends `VmStatusRequest` immediately after VM start
- **THEN** the reply SHALL include `phase: Starting` while podman is initialising
- **AND** the reply SHALL transition to `phase: Ready, podman_ready: true` once `podman info` succeeds inside the VM

#### Scenario: CloudRefreshReply contains no token material
- **WHEN** the host shell sends `CloudRefreshRequest`
- **THEN** the reply SHALL contain a list of repo names + URLs only
- **AND** the reply SHALL NOT contain the `gh auth token` value, OAuth refresh tokens, or any header that includes a token

#### Scenario: VmShutdownRequest is fire-and-forget
- **WHEN** the host shell sends `VmShutdownRequest { drain_timeout_ms: 10000 }`
- **THEN** the in-VM headless SHALL begin shutdown and SHALL NOT reply
- **AND** the host shell SHALL detect completion by observing the vsock connection close

### Requirement: Error model surfaces transport failures explicitly
- **ID**: vsock-transport.errors.explicit-error-types@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vsock-transport.invariant.errors-enumerated, vsock-transport.invariant.errors-traced]

The transport layer SHALL define an enumerated `TransportError` with at
least these variants: `ConnectRefused`, `Disconnected`, `VersionMismatch`,
`MessageTooLarge`, `DecodeFailed`, `IoError`. Each variant SHALL carry enough
context for the host shell to build a user-facing status string, and SHALL be
emitted as a structured log event with `spec = "vsock-transport"`.

@trace spec:vsock-transport

#### Scenario: VM not yet listening surfaces as ConnectRefused
- **WHEN** the host attempts to connect before the in-VM headless has bound
- **THEN** the `connect()` call SHALL return `Err(TransportError::ConnectRefused)`
- **AND** the host shell SHALL retry per the reconnect backoff schedule

#### Scenario: Decode failure aborts the connection
- **WHEN** a malformed postcard payload arrives
- **THEN** the receiver SHALL emit `Err(TransportError::DecodeFailed)` and close the connection
- **AND** SHALL log `spec = "vsock-transport"` with the byte offset where decoding failed

## Invariants

### Invariant: Host CID is 2
- **ID**: vsock-transport.invariant.host-cid-is-2
- **Expression**: `host_side_connect.local_cid == VMADDR_CID_HOST == 2`
- **Measurable**: true

### Invariant: Guest CID is stable per host-process boot
- **ID**: vsock-transport.invariant.guest-cid-is-stable-per-boot
- **Expression**: `start[i].guest_cid == start[i+1].guest_cid FOR_ALL i WITHIN host_process_lifetime`
- **Measurable**: true

### Invariant: Port constant defined in control-wire
- **ID**: vsock-transport.invariant.port-constant-defined-in-control-wire
- **Expression**: `CONTROL_WIRE_VSOCK_PORT IS_DEFINED_IN tillandsias-control-wire AND == 42420`
- **Measurable**: true

### Invariant: Framing shared with Unix transport
- **ID**: vsock-transport.invariant.framing-shared-with-unix
- **Expression**: `encode_envelope AND decode_envelope ARE_SHARED_FNS BETWEEN unix AND vsock paths`
- **Measurable**: true

### Invariant: Wire version is 1
- **ID**: vsock-transport.invariant.wire-version-1
- **Expression**: `WIRE_VERSION == 1`
- **Measurable**: true

### Invariant: New variants are postcard-stable
- **ID**: vsock-transport.invariant.new-variants-postcard-stable
- **Expression**: `ControlMessage variant_discriminants HAVE explicit u8 values AND NEVER reordered`
- **Measurable**: true

### Invariant: No tokens in messages
- **ID**: vsock-transport.invariant.no-tokens-in-messages
- **Expression**: `ControlMessage_fields CONTAIN no field_named_like(token|secret|key|password)`
- **Measurable**: true

### Invariant: Errors are enumerated
- **ID**: vsock-transport.invariant.errors-enumerated
- **Expression**: `TransportError IS enum AND COVERS [ConnectRefused, Disconnected, VersionMismatch, MessageTooLarge, DecodeFailed, IoError]`
- **Measurable**: true

### Invariant: Errors are traced
- **ID**: vsock-transport.invariant.errors-traced
- **Expression**: `TransportError emission EMITS log_event WITH spec="vsock-transport"`
- **Measurable**: true

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:vsock-handshake` — primary handshake verification.
- `litmus:vm-shutdown-drains-forges` — exercises `VmShutdownRequest` semantics.

## Litmus Chain

Smallest actionable boundary: `cargo test -p tillandsias-control-wire
transport::vsock::tests::handshake_roundtrip --filter vsock-transport
--strict`. Runtime entry boundary: spawning the in-VM headless with
`--listen-vsock 42420` and connecting from the host with `socat
VSOCK-CONNECT:<cid>:42420 -`.

## Sources of Truth

- `cheatsheets/runtime/vsock-transport.md` — vsock CID/port mechanics and debugging.
- `cheatsheets/utils/podman-secrets.md` — discipline for keeping tokens off the wire.
- Plan: `/home/tlatoani/.claude/plans/stateless-riding-newt.md`.

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:vsock-transport" crates/ --include="*.rs"
```
