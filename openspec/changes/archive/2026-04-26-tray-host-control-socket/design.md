# Design — tray-host-control-socket

## Context

Tillandsias is a tray-resident orchestrator. Several in-flight capabilities
need an out-of-band channel between the tray (host process) and tray-spawned
processes — most acutely the router container that fronts OpenCode Web (per
`opencode-web-session-otp/design.md`, the OTP transport for per-window session
cookies). Future consumers in flight or anticipated:

- `host-browser-mcp` — the host-side allowlist gate for "open this URL" calls
  from a forge-resident MCP server.
- A future log-event ingest path that lets enclave processes contribute to the
  host accountability log without each one re-implementing a logging client.
- A future health-probe channel so the tray can ask "are you alive" cheaply.

Each of these would otherwise grow its own ad-hoc transport (TCP loopback
socket, file-on-disk poll, environment variable, named pipe). The user has
explicitly stated: *"We're going to need a unix socket anyway to share messages
later on."* This change reifies that decision as a single reviewable control
plane — typed, framed, length-prefixed, postcard-encoded, mode `0600`.

The control socket is **infrastructure**: the v1 message catalogue is small
(`Hello`, `IssueWebSession`, error frames) and explicitly designed for
additive evolution. Consumers ship as separate OpenSpec changes that add
variants to the shared `ControlMessage` enum.

This design only covers the socket primitive. The OTP semantics, cookie
attributes, browser-launch flow, and audit-logging policy live in
`opencode-web-session-otp` and `secrets-management`.

## Goals / Non-Goals

**Goals:**

- A single Unix-domain control socket the tray binds at startup, removes at
  shutdown, and listens on for the entire tray lifetime.
- A typed, postcard-framed, length-prefixed wire format with a stable
  envelope that supports forward-compatible variant addition without breaking
  older consumers.
- Owner-only file permissions (`0600` on the socket node, `0700` on the
  parent directory) so other users on a shared host cannot connect.
- Bind-mounted into forge / router / future enclave consumers at a fixed
  in-container path (`/run/host/tillandsias/control.sock`) so consumer code
  is identical inside and outside the enclave.
- Survives the consumer crashing — the listener stays up, the consumer
  reconnects with retry + jitter.
- Tray restart is a recoverable event for consumers — the consumer detects
  the disconnect, retries with backoff, and re-establishes the session.
- Bounded resources: per-connection message size cap, per-connection idle
  timeout, max concurrent connection cap.

**Non-Goals:**

- Authentication beyond filesystem permissions. The socket relies on Unix
  ownership + mode; there is no token handshake. The user that owns the
  tray is the only principal.
- Cross-host transport. The socket is local-only; remote scenarios are out
  of scope and would use a different capability.
- Replacing structured logging or metrics. Consumers may emit log events
  via the socket as a future variant, but the socket is not a general
  log shipping channel.
- Replay semantics. Messages are fire-and-forget unless a variant explicitly
  defines an ack frame (e.g., `IssueWebSession` returns `IssueAck` so the
  tray knows the router accepted the cookie value).
- Persisting messages across tray restart. The socket is in-memory state on
  the tray side; a tray restart drops in-flight messages, and consumers
  reconnect to the new listener.

## Decisions

### Decision 1 (Q1) — Transport: Unix-domain stream socket on the host

**Choice**: A single SOCK_STREAM Unix-domain socket bound by the tray at:

```
$XDG_RUNTIME_DIR/tillandsias/control.sock        (Linux primary)
/tmp/tillandsias-$UID/control.sock               (Linux fallback if XDG missing)
```

The macOS path follows the same template using `$TMPDIR` (which APFS provides
per-user). Windows is out of scope for v1 — the control socket is a Unix
primitive; Windows consumers would land via a separate change adopting Named
Pipes with the same envelope format.

**Why**: SOCK_STREAM gives ordered byte delivery and natural framing (we
length-prefix on top). `$XDG_RUNTIME_DIR` is the freedesktop-standard
ephemeral per-user directory, mode `0700` by default, automatically cleaned
on logout. Falling back to `/tmp/tillandsias-$UID/` preserves correctness on
minimal systems (no logind, no systemd-user) without changing the wire
contract.

**Rejected alternatives**:

- **TCP loopback**: lifetime-tied to a port number; needs allocation; sniffable
  by any process on the host with `127.0.0.1` access; no native owner-only
  permission. Worse on every axis.
- **D-Bus**: heavy dependency; the project already minimises D-Bus usage to
  the keyring bridge alone. Adds an XML interface file, generated bindings,
  and an introspection surface that would need its own threat model.
- **Named pipes (FIFO)**: Linux FIFOs are unidirectional — would need two,
  doubling the bookkeeping. SOCK_STREAM already provides bidirectional in one
  node.

### Decision 2 (Q2) — Filesystem location and permissions

**Choice**: At tray startup, `ensure_control_socket_dir()` creates
`$XDG_RUNTIME_DIR/tillandsias/` (or `/tmp/tillandsias-$UID/`) with mode
`0700` if absent. The socket node is bound as `control.sock` inside that
directory and `chmod`-ed to `0600` immediately after `bind()` returns
(before `listen()`). On graceful shutdown the socket node is unlinked.

**Why**: The directory mode `0700` blocks `stat()` from other users so the
socket's existence is not even discoverable. The socket mode `0600` blocks
`connect(2)` from other users — the kernel enforces Unix-socket connect
permission against the file mode. Setting the mode between `bind()` and
`listen()` closes the race where another user could race-connect during the
brief default-mode window.

**Rejected alternative — `/var/run/tillandsias/`**: requires root or a setuid
helper to create. Tillandsias is a user-mode tray app; per-user runtime
directories are the right scope.

### Decision 3 (Q3) — Stale socket recovery

**Choice**: On startup, if the socket node already exists at the bind path:

1. Attempt `connect()` to it from inside the tray with a 200 ms timeout.
2. If `connect()` succeeds, send a `ControlMessage::Hello { from: "tray-probe" }`
   envelope and read for an envelope or EOF with a 500 ms deadline.
3. If a peer responds (or the connection is held open without immediate EOF),
   another tray instance is alive — the new tray exits with the same
   "another instance is running" path used by the existing singleton guard.
4. If `connect()` fails with `ECONNREFUSED`, or the probe times out without a
   response, the socket node is stale. The tray unlinks it and proceeds with
   its own `bind()`.

**Why**: A crashed tray leaves the socket node behind; the next start must
not refuse to bind. The probe step distinguishes "stale leftover" from
"another tray instance is live" without racing the existing PID-based
singleton check (this is a defence-in-depth confirmation, not a replacement).

**Rejected alternative — always unlink before bind**: silently kicks an
already-running tray instance off its own socket. Bad if the singleton check
ever has a race; the probe gives a second line of defence.

### Decision 4 (Q4) — Wire format: postcard envelope, length-prefixed framing

**Choice**: Every message on the wire is:

```
[ 4-byte big-endian u32 length N ] [ N bytes of postcard-serialised ControlEnvelope ]
```

`ControlEnvelope` is a versioned wrapper:

```rust
struct ControlEnvelope {
    wire_version: u16,      // currently 1
    seq: u64,               // monotonic per-connection sender sequence; consumers ack with same seq
    body: ControlMessage,   // the typed enum below
}

enum ControlMessage {
    Hello { from: String, capabilities: Vec<String> },     // first frame after connect
    HelloAck { wire_version: u16, server_caps: Vec<String> },
    IssueWebSession { project_label: String, cookie_value: [u8; 32] },
    IssueAck { seq_acked: u64 },
    Error { seq_in_reply_to: Option<u64>, code: ErrorCode, message: String },
    // future variants land via additive changes; postcard's enum-by-index
    // encoding requires that new variants append, never reorder existing ones.
}

enum ErrorCode {
    UnknownVariant,
    PayloadTooLarge,
    Unauthorized,           // reserved; v1 enforces auth via fs perms only
    Internal,
    Unsupported,
}
```

**Why postcard over JSON**: project standing rule (`feedback_design_philosophy`):
no JSON in IPC hot paths. Postcard is compact, schema-evolving via additive
enum variants, and zero-copy on the deserialise side. The 4-byte length
prefix is the standard length-delimited framing pattern documented in the
postcard cookbook; we explicitly do NOT use postcard's COBS variant because
the framing is simpler and the channel is reliable in-order (Unix stream
socket).

**Forward compatibility rule**:

- New `ControlMessage` variants append to the enum. Postcard encodes enums by
  variant index, so older readers reject unknown indices via deserialise error
  — we treat this as the documented `Error::UnknownVariant` response.
- `wire_version` bumps when the envelope shape itself changes (renaming `seq`,
  adding a required field). The `Hello`/`HelloAck` exchange surfaces the
  mismatch on connect; both peers MUST refuse to proceed if their majors
  disagree.
- v1 = `wire_version = 1`. The next breaking envelope change is `wire_version
  = 2` and triggers a tombstoned-compat shim per project convention.

**Rejected alternatives**:

- **JSON-RPC**: violates the no-JSON rule; debate already settled.
- **gRPC**: drags in protoc, generated code, HTTP/2 framing — wildly
  oversized for a 5-variant enum.
- **Raw postcard without envelope**: works but breaks forward-compat the
  moment we want to add a header (sequence number, version). Pay the
  envelope cost once.

### Decision 5 (Q5) — Resource limits per connection

**Choice**:

| Limit | Value | Enforcement |
|---|---|---|
| Max single-message size | 64 KiB | length-prefix > 65536 → connection closed with `Error::PayloadTooLarge` |
| Per-connection idle timeout | 60 s | `tokio::time::timeout` on read; expired → connection closed |
| Per-connection in-flight unacked frames | 16 | sender backpressures; tray reader drops connections that exceed it |
| Max concurrent connections | 32 | `Semaphore` permits in the `accept` loop |

**Why**: v1 message bodies are tens of bytes; 64 KiB is two orders of
magnitude headroom for future variants while still preventing a malicious
4 GiB length prefix from exhausting the tray's heap. 60 s idle matches the
OTP TTL in `opencode-web-session-otp` so timeouts compose naturally. 32
concurrent connections covers ~10 forge containers + router + browser MCP
+ headroom; `Semaphore` is the canonical tokio backpressure primitive.

**Rejected alternative — no limits, trust enclave peers**: violates the
defence-in-depth principle. The socket is mode `0600` so peers are
trustworthy in v1, but a buggy consumer (or an MCP variant introduced
later) must not be able to OOM the tray.

### Decision 6 (Q6) — Tokio listener; one task per accepted connection

**Choice**:

- Listener: `tokio::net::UnixListener::bind(path)`.
- Accept loop: `tokio::spawn(handle_connection(stream, dispatcher))` per
  accepted stream.
- Per-connection: `tokio::select!` between read frames and dispatcher
  outbound channel. Reads use a `tokio_util::codec::LengthDelimitedCodec`
  (length-prefix framing).
- Dispatcher: a single-owner async task holding the `ControlMessage`
  router (variant → handler). New consumers register handlers at tray
  startup; the router is built once and shared `Arc<Dispatcher>` across
  all per-connection tasks.

**Why**: Native tokio idioms; the codec crate handles the length prefix
correctly (no DIY framing bugs); per-connection tasks isolate failures
(one consumer crashing does not stall others); the single-owner dispatcher
serialises mutation of shared state without locks in handlers.

**Rejected alternative — async-std / smol**: the project is already on
tokio everywhere (`feedback_design_philosophy`). No reason to mix.

### Decision 7 (Q7) — Tray restart and consumer reconnect

**Choice**: On tray graceful shutdown, the listener task closes accepted
streams cleanly (write any pending acks, then shut). On unclean exit
(panic, SIGKILL), kernel closes the streams; consumers see `EOF`. In both
cases the socket file is unlinked — by tray-side `Drop` on graceful exit
and by the next-start probe (Decision 3) on unclean exit.

Consumers (router, browser MCP, future) MUST implement reconnect with
exponential backoff: 100 ms → 200 ms → 500 ms → 1 s → 2 s → cap at 5 s,
indefinitely. On reconnect they MUST re-send `Hello` and re-establish any
session-scoped state (e.g., the router does not assume previously-issued
session cookies survived the tray restart — but cookies live in router
memory, not tray memory, so they DO survive a tray restart; only the
tray↔router channel is re-established).

**Why**: tray restarts are rare but real (update install, crash recovery).
The consumer reconnect pattern is standard for any connection-oriented
service; mandating it here keeps consumer code uniform.

**Rejected alternative — abstract socket (`@`-prefixed)**: Linux-specific,
not portable to macOS, no filesystem-permission gate. Filesystem socket is
correct here.

### Decision 8 (Q8) — In-container mount path

**Choice**: The control socket bind-mounts into every consumer container at
`/run/host/tillandsias/control.sock` (read-write — the kernel enforces socket
semantics, mount ro/rw is irrelevant for socket connect). The container's
client library reads `TILLANDSIAS_CONTROL_SOCKET` env var (set by the launch
context) defaulting to `/run/host/tillandsias/control.sock`.

The mount is added to the podman command via:

```
-v $XDG_RUNTIME_DIR/tillandsias/control.sock:/run/host/tillandsias/control.sock
```

with the `--security-opt no-new-privileges` flag preserved (the socket mount
does not relax existing security flags).

**Why**: A fixed in-container path lets consumer images hard-code the
default; no per-launch config needed. `/run/host/...` is a conventional
namespace for host-provided services exposed inside the container (used by
toolbox, flatpak, distrobox).

**Rejected alternative — exposing the host path verbatim inside the
container**: leaks the host UID, makes the path container-image-specific,
breaks the principle that container images are environment-agnostic.

### Decision 9 (Q9) — v1 message catalogue and additive evolution rule

**v1 ships exactly these variants**:

| Variant | Direction | Purpose |
|---|---|---|
| `Hello` | client→server | First frame after connect; declares `from` (consumer name) and `capabilities` (which message classes the consumer understands). |
| `HelloAck` | server→client | Replies with `wire_version` and `server_caps`; `wire_version` mismatch = connection closed. |
| `IssueWebSession { project_label, cookie_value }` | client→server (router-initiated) OR server→client (tray-initiated, the actual flow) | Tray sends to router-side consumer to register a session cookie. |
| `IssueAck { seq_acked }` | reply | Receiver acknowledges the prior `IssueWebSession` with the same `seq`. |
| `Error { seq_in_reply_to, code, message }` | bidirectional | Generic error frame; `seq_in_reply_to` ties to a sender frame when applicable. |

**Future variants land via additive OpenSpec changes**. Each must:

1. Append to the `ControlMessage` enum (never reorder existing variants —
   postcard is index-positional).
2. Bump `wire_version` ONLY if the envelope shape changes; appending an
   enum variant keeps `wire_version = 1`.
3. Document the new variant in this capability's spec (delta requirement).
4. Tombstone any superseded variants per project convention (`@tombstone
   superseded:<new-spec>`); old variants stay in the enum for the 3-release
   compat window.

**Why locked now**: the user mandated the socket as a load-bearing primitive
beyond OTP. Locking the additive-evolution rule now prevents the second-
consumer change (e.g., `host-browser-mcp`) from re-litigating the wire
format. Decisions about *what* messages are allowed are per-capability;
the *how* is fixed here.

## Risks / Trade-offs

- **Single point of failure for cross-process control**: every consumer
  depends on the tray. If the tray crashes, consumers reconnect — but
  in-flight operations (e.g., a router waiting for an OTP) abort. Mitigated
  by tray-side singleton-guard rigour; consumers retry idempotent operations.
- **No authentication beyond filesystem mode**: a malicious local process
  running as the same user can connect and send messages. The threat model
  treats same-user processes as trusted (they could read tray memory anyway
  via `ptrace`). Out of scope: hardening against same-user attackers.
- **Postcard variant-index brittleness**: reordering or deleting a variant
  silently corrupts the wire. Mitigated by the additive-evolution rule
  (locked above) and by tombstones (no silent deletes).
- **macOS `$XDG_RUNTIME_DIR`**: macOS does not set this by default. The
  fallback `/tmp/tillandsias-$UID/` covers it; documented behaviour rather
  than a workaround.
- **Container restart races the socket bind-mount**: if the tray rebinds the
  socket (new inode) while a consumer container holds the bind-mount, the
  consumer's mount references the old inode and stops working. Mitigated by:
  the socket node is preserved across reconnects (Decision 7 — only unlinked
  on tray exit); the socket file mode is set in-place; the inode survives
  individual connection lifetimes.
- **Bind-mount semantics for sockets across podman**: podman bind-mounts the
  socket node into the container's mount namespace; the in-container
  `connect(2)` resolves to the same socket the host binds. Verified
  behaviour on Linux + Fedora/Silverblue podman; documented as a
  prerequisite.
- **Length-prefix endianness mismatch**: 4-byte big-endian (network order)
  is the locked choice. A consumer using little-endian would deserialise
  garbage lengths. Documented in the wire-format requirement; client-library
  code uses `LengthDelimitedCodec` defaults (big-endian) so the bug is
  prevented at the API level.

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — the socket
  lives in `$XDG_RUNTIME_DIR` (ephemeral by definition); never under any
  persistent category.
- `cheatsheets/runtime/forge-container.md` — bind-mount conventions for
  host-provided sockets exposed inside the enclave at `/run/host/...`.
- `cheatsheets/languages/rust.md` — tokio idioms; `UnixListener`, `select!`,
  `Semaphore` patterns.
- `cheatsheets/runtime/networking.md` — Unix-domain socket semantics,
  filesystem-permission enforcement, in-container bind-mount behaviour.
- `cheatsheets/architecture/event-driven-basics.md` — per-connection tasks +
  shared dispatcher pattern.
- `openspec/specs/secrets-management/spec.md` — the loopback-only /
  never-at-rest discipline this socket extends to in-memory IPC.
- `openspec/specs/podman-orchestration/spec.md` — the launch context that
  attaches the bind-mount and sets `TILLANDSIAS_CONTROL_SOCKET`.
- `openspec/changes/opencode-web-session-otp/design.md` — the consumer
  whose requirements drove v1 of the `IssueWebSession` variant.
- `openspec/changes/host-browser-mcp/proposal.md` — anticipated consumer for
  `OpenBrowser` variant in a later additive change.
