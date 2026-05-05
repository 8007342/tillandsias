# tray-app delta — tray-host-control-socket

## ADDED Requirements

### Requirement: Tray binds a host-local Unix control socket at startup

The tray application SHALL bind a Unix-domain stream socket
(`SOCK_STREAM`) at `$XDG_RUNTIME_DIR/tillandsias/control.sock` on Linux
when `XDG_RUNTIME_DIR` is set, and at `/tmp/tillandsias-$UID/control.sock`
otherwise. macOS uses the same template against `$TMPDIR`. The bind SHALL
occur before the tray icon becomes interactive, and the socket SHALL remain
open for the entire tray lifetime. On graceful shutdown the socket node
SHALL be unlinked from the filesystem.

The parent directory SHALL be created with mode `0700` if absent. The
socket node SHALL have mode `0600`, set in-place between `bind(2)` and
`listen(2)` so that no other-user `connect(2)` can race the default-mode
window.

@trace spec:tray-host-control-socket, spec:tray-app

#### Scenario: Socket created at startup with owner-only permissions

- **WHEN** the tray process starts and reaches the post-init phase
- **THEN** the file at `$XDG_RUNTIME_DIR/tillandsias/control.sock` exists
- **AND** the file is a Unix-domain socket node (per `stat(2)`)
- **AND** the file mode is exactly `0600`
- **AND** the parent directory mode is exactly `0700`
- **AND** the socket owner UID matches the tray process EUID

#### Scenario: XDG_RUNTIME_DIR fallback

- **WHEN** the tray starts in an environment where `XDG_RUNTIME_DIR` is
  unset or empty
- **THEN** the tray binds the socket at `/tmp/tillandsias-<euid>/control.sock`
- **AND** the parent directory `/tmp/tillandsias-<euid>/` is created with
  mode `0700`
- **AND** the socket file mode is `0600`
- **AND** an accountability log entry records the fallback at
  `category = "control-socket"`, `spec = "tray-host-control-socket"`

#### Scenario: Socket unlinked on graceful shutdown

- **WHEN** the tray exits via the Quit menu item or a SIGTERM
- **THEN** the listener task closes accepted streams cleanly
- **AND** the socket node at the bind path is `unlink(2)`-ed before the
  process exits
- **AND** an accountability log entry records the teardown

### Requirement: Stale-socket recovery on startup

When the bind path already exists at tray startup, the tray SHALL probe the
existing node before binding its own. The probe SHALL `connect(2)` with a
200 ms timeout; on success it SHALL exchange a `Hello`/`HelloAck` envelope
with a 500 ms total deadline. A live peer means another tray instance is
running and the new tray SHALL exit through the existing singleton-guard
path. A failed probe (connect error or deadline exceeded) means the node is
stale; the tray SHALL `unlink(2)` it and proceed with its own `bind(2)`.

@trace spec:tray-host-control-socket, spec:tray-app

#### Scenario: Stale socket from a crashed prior tray is recovered

- **WHEN** the tray starts and the bind path exists but no live tray owns it
- **AND** `connect(2)` to the path fails with `ECONNREFUSED` (or the probe
  deadline elapses with no response)
- **THEN** the tray unlinks the stale node
- **AND** binds its own socket at the same path
- **AND** logs the recovery at `category = "control-socket"`,
  `spec = "tray-host-control-socket"`, `operation = "stale-recovered"`

#### Scenario: Live peer at the bind path blocks startup

- **WHEN** the tray starts and the bind path exists and the probe receives a
  valid `HelloAck` envelope from the existing socket
- **THEN** the new tray does NOT unlink the socket
- **AND** the new tray exits via the singleton-guard path with the same
  user-visible message used for PID-based singleton conflicts
- **AND** an accountability log entry records the conflict

### Requirement: Postcard-framed wire format with versioned envelope

Every message on the control socket SHALL be encoded as a 4-byte big-endian
length prefix `N` followed by exactly `N` bytes of postcard-serialised
`ControlEnvelope`. The envelope SHALL carry a `wire_version: u16` (currently
`1`), a per-connection monotonic `seq: u64`, and a `body: ControlMessage`
typed enum. JSON SHALL NOT appear on the wire.

The envelope SHALL be opened with a `Hello` / `HelloAck` exchange before any
other variant is accepted; a `wire_version` mismatch between peers SHALL
close the connection with an `Error { code: Unsupported }` frame.

The `ControlMessage` enum SHALL be evolved additively: new variants append
at the end, existing variants SHALL NOT be reordered or deleted, and
deprecated variants SHALL be tombstoned per project convention rather than
removed.

@trace spec:tray-host-control-socket, spec:secrets-management

#### Scenario: Length-prefixed postcard envelope round-trips

- **WHEN** a consumer sends a `ControlMessage::Hello { from: "router",
  capabilities: vec!["IssueWebSession".to_string()] }` framed as a 4-byte
  big-endian length followed by the postcard bytes
- **THEN** the tray-side reader deserialises the envelope into the same
  variant with the same field values
- **AND** the tray replies with a `ControlMessage::HelloAck { wire_version:
  1, server_caps: <list> }` framed identically
- **AND** the connection proceeds to accept further frames

#### Scenario: Wire-version mismatch closes the connection

- **WHEN** a consumer sends a `Hello` envelope with `wire_version = 2` and
  the tray supports only `wire_version = 1`
- **THEN** the tray replies with a single `Error { code: Unsupported }`
  envelope at `wire_version = 1`
- **AND** the tray closes the stream after the error frame is flushed
- **AND** an accountability log entry records the version conflict at
  `category = "control-socket"`, `spec = "tray-host-control-socket"`

#### Scenario: Unknown enum variant is rejected at deserialise

- **WHEN** a consumer writes a postcard payload whose variant index is not
  in the tray's `ControlMessage` enum
- **THEN** the tray's deserialise step fails
- **AND** the tray replies with `Error { code: UnknownVariant,
  seq_in_reply_to: <seq if recoverable, else None> }`
- **AND** the offending bytes do NOT mutate any tray-side state
- **AND** an accountability warning records the rejection

#### Scenario: No JSON appears on the wire

- **WHEN** auditing the byte stream of every message the tray sends or
  accepts on the control socket
- **THEN** the framing matches `[u32 length BE][postcard bytes]` exactly
- **AND** no JSON object delimiters (`{`, `}`, `"`) appear at the framing
  layer
- **AND** the postcard payloads decode against the project's
  `ControlEnvelope` schema

### Requirement: Per-connection resource limits

The tray SHALL enforce the following limits on every accepted connection:

- Maximum single-message length: 64 KiB (`65536` bytes); a length prefix
  greater than this SHALL close the connection after sending
  `Error { code: PayloadTooLarge }`.
- Per-connection idle timeout: 60 seconds with no inbound bytes SHALL close
  the connection.
- Maximum concurrent accepted connections: 32; the `accept(2)` loop SHALL
  use a `tokio::sync::Semaphore` permit to backpressure new connections
  beyond the cap.

@trace spec:tray-host-control-socket, spec:tray-app

#### Scenario: Oversized frame closes the connection

- **WHEN** a consumer writes a 4-byte length prefix encoding a value
  greater than `65536`
- **THEN** the tray sends an `Error { code: PayloadTooLarge }` envelope
- **AND** closes the stream
- **AND** does not attempt to read or buffer the would-be payload bytes

#### Scenario: Idle connection times out

- **WHEN** an accepted connection sends no bytes for 60 seconds
- **THEN** the tray closes the stream
- **AND** logs the timeout at `category = "control-socket"`,
  `spec = "tray-host-control-socket"`, `operation = "idle-timeout"`

#### Scenario: Concurrent-connection cap backpressures

- **WHEN** 32 connections are already active and a 33rd consumer attempts
  `connect(2)`
- **THEN** the kernel `accept(2)` queue holds the connection until a
  semaphore permit is released
- **AND** the tray does not OOM, panic, or refuse subsequent legitimate
  connections after a permit frees

### Requirement: Bind-mount of control socket into consumer containers

The tray SHALL include the control socket as a read-write bind mount in
every container it launches that is declared (in its container profile) as
a control-socket consumer. The mount target inside the container SHALL be
`/run/host/tillandsias/control.sock`. The launch context SHALL set the
environment variable `TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias/control.sock`
inside the container so client libraries can read a single canonical path.

The bind mount SHALL be added without relaxing any existing security flag —
`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`,
and `--rm` SHALL remain in effect for the consumer container.

@trace spec:tray-host-control-socket, spec:podman-orchestration

#### Scenario: Router container receives the bind mount

- **WHEN** the tray launches the router container
- **THEN** the podman command line contains
  `-v <host-socket-path>:/run/host/tillandsias/control.sock`
- **AND** the environment carries
  `TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias/control.sock`
- **AND** `--cap-drop=ALL` and `--security-opt=no-new-privileges` remain
  on the command line

#### Scenario: Forge container without consumer profile gets no mount

- **WHEN** the tray launches a forge container whose profile does NOT
  declare it as a control-socket consumer
- **THEN** the podman command line does NOT contain the control-socket
  bind mount
- **AND** the `TILLANDSIAS_CONTROL_SOCKET` environment variable is not set

### Requirement: Consumer reconnect after tray restart

Consumer containers SHALL implement reconnect with exponential backoff when
the control socket disconnects. The backoff SHALL start at 100 ms and
double on each failure, capped at 5 seconds, retrying indefinitely. After
each successful reconnect the consumer SHALL re-send `Hello` and re-issue
any session-scoped state required by its capability before resuming
normal operation.

@trace spec:tray-host-control-socket

#### Scenario: Consumer survives tray restart

- **WHEN** the tray exits while a router consumer holds an open control
  connection
- **AND** the tray restarts within 30 seconds
- **THEN** the consumer's reconnect loop establishes a new connection
- **AND** the consumer sends `Hello` on the new connection
- **AND** subsequent `IssueWebSession` envelopes succeed without operator
  intervention

#### Scenario: Backoff caps at five seconds

- **WHEN** a consumer attempts reconnect and the tray remains absent for
  more than 60 seconds
- **THEN** the backoff between attempts grows monotonically until reaching
  5 seconds, then stays at 5 seconds for all subsequent attempts
- **AND** the reconnect loop continues indefinitely (no abort) until the
  tray returns or the consumer container is stopped

## Sources of Truth

- `cheatsheets/runtime/networking.md` — Unix-domain socket semantics and
  filesystem-permission enforcement on `connect(2)`.
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — confirms
  `$XDG_RUNTIME_DIR` is the ephemeral category; the socket node belongs
  there and nowhere else.
- `cheatsheets/runtime/forge-container.md` — `/run/host/...` convention
  for host-provided sockets bind-mounted into the enclave.
- `cheatsheets/languages/rust.md` — tokio `UnixListener`, `select!`, and
  `Semaphore` idioms used by the implementation.
- `cheatsheets/architecture/event-driven-basics.md` — per-connection
  tokio task with a shared dispatcher pattern.
