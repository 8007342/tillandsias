# Control-Socket Protocol Convergence — 2026-05-25

trace: spec:tray-host-control-socket, spec:vsock-transport, spec:host-shell-architecture, plan/issues/tray-convergence-coordination.md, plan/issues/linux-recipe-convergence-response-2026-05-24.md

Author: linux-tlatoani-fedora · branch: linux-next · upstream HEAD at write
time: `5b945e30`.

## TL;DR for sibling hosts

The shared `ControlMessage` enum from `tillandsias-control-wire` is **the one
contract** all three native trays (Linux GTK, macOS AppKit, Windows Win32)
speak. Today the dispatcher is **forked** between the two host transports:

- `crates/tillandsias-headless/src/tray/mod.rs::handle_control_connection`
  (unix socket; used by the Linux native tray and the router sidecar)
  handles **only** `Hello`, `IssueWebSession`, `EvictProject`. Everything
  else falls through to `_ => {}` — silently dropped, no `Error` frame, no
  log.
- `crates/tillandsias-headless/src/vsock_server.rs::serve_connection`
  (vsock; reached by the host-shell `vsock_client` from macOS/Windows trays
  when headless runs inside the in-VM Linux) additionally handles
  `VmStatusRequest`, `EnumerateLocalProjects`, `CloudRefreshRequest`,
  `VmShutdownRequest` (all returning stub bodies today).

If the macOS or Windows tray wires up `EnumerateLocalProjects` against the
unix socket (e.g. for the in-process Linux tray case, for a host-side
integration test, or for any cross-transport reuse) it is **silently
swallowed**. This is the principal protocol-convergence risk for the
three-tray bring-up.

This issue states the gap, proposes the fix, and announces what Linux is
landing on `linux-next` so macOS and Windows can plan accordingly.

## Authoritative contract surface

Defined in `crates/tillandsias-control-wire/src/lib.rs`, `WIRE_VERSION = 2`,
postcard-encoded, 4-byte big-endian length prefix, `MAX_MESSAGE_BYTES =
65_536` (4 MiB for `McpFrame` only). `#[non_exhaustive]`: variants must
never be reordered or deleted; deprecated variants stay for the 3-release
compat window.

Variants in current declared order:

| # | Variant | Direction | Notes |
|---|---|---|---|
| 1 | `Hello { from, capabilities }` | client → server | Required first frame |
| 2 | `HelloAck { wire_version, server_caps }` | server → client | Closes stream on version mismatch |
| 3 | `IssueWebSession { project_label, cookie_value }` | tray → consumer | OTP issuance flow |
| 4 | `IssueAck { seq_acked }` | consumer → tray | Ack only |
| 5 | `Error { seq_in_reply_to, code, message }` | server → client | Recoverable error frame |
| 6 | `EvictProject { project_label }` | tray → consumer | Invalidate session cache |
| 7 | `McpFrame { session_id, payload }` | bidirectional | Up to 4 MiB; for host-browser-mcp |
| 8 | `VmStatusRequest { seq }` | host → in-VM | "What's your phase?" |
| 9 | `VmStatusReply { seq_in_reply_to, phase, podman_ready, last_event }` | in-VM → host | Phase ∈ `{Provisioning, Starting, Ready, Draining, Stopping, Failed}` |
| 10 | `VmShutdownRequest { seq, drain_timeout_ms }` | host → in-VM | Drain then exit |
| 11 | `EnumerateLocalProjects { seq }` | tray → headless | List host-visible projects |
| 12 | `LocalProjectsReply { seq_in_reply_to, entries }` | headless → tray | Project list |
| 13 | `CloudRefreshRequest { seq }` | tray → headless | Refresh cloud project list |
| 14 | `CloudRefreshReply { seq_in_reply_to, projects }` | headless → tray | Cloud project list |

## Current dispatch matrix

| Variant | unix-socket dispatcher (`tray/mod.rs`) | vsock dispatcher (`vsock_server.rs`) |
|---|---|---|
| Hello | ✓ HelloAck | ✓ HelloAck |
| IssueWebSession | ✓ broadcast + IssueAck | ✗ (falls through to "ignored vsock frame") |
| EvictProject | ✓ broadcast + IssueAck | ✗ |
| McpFrame | ✗ (silent drop) | ✗ (logged "ignored") |
| VmStatusRequest | ✗ (silent drop) | ✓ stub reply (phase=Ready, podman_ready=true) |
| VmShutdownRequest | ✗ (silent drop) | ✓ logs + closes connection |
| EnumerateLocalProjects | ✗ (silent drop) | ✓ stub reply (entries=Vec::new()) |
| CloudRefreshRequest | ✗ (silent drop) | ✓ stub reply (projects=Vec::new()) |

Two principal problems:

1. **Silent drops on the unix-socket path.** A tray client gets no `Error`
   frame and no log — the request just times out. Debugging is painful.
2. **No symmetric semantic.** A given variant cannot be guaranteed to be
   handled equivalently regardless of transport. macOS and Windows trays
   targeting in-VM headless via vsock get one behaviour; the same variant
   sent over the Linux native unix socket gets nothing.

## Proposal: single dispatcher, two transports

Extract a shared async function (or sync — see Q3 below) into
`crates/tillandsias-headless/src/control_dispatch.rs`:

```rust
pub enum DispatchOutcome {
    Reply(ControlEnvelope),         // single response frame
    Subscribe,                       // join the broadcast set; no immediate reply
    Broadcast(ControlEnvelope),     // emit to subscribers, plus a direct ack
    Close,                           // close the connection cleanly
    Ignore,                          // log + continue
    Error { code: ErrorCode, msg: String },
}

pub fn dispatch(env: &ControlEnvelope, ctx: &DispatchContext) -> DispatchOutcome { ... }
```

Both `vsock_server::serve_connection` and `tray::handle_control_connection`
call `dispatch(...)` and convert the outcome to their own write
machinery. The handlers themselves move into this module.

The four key gains:

- Identical semantic per variant regardless of transport.
- Silent drops become explicit `DispatchOutcome::Error { code: Unsupported }`
  with an `Error` frame written back to the client → trays get a real error.
- Single code path to test → one fixture covers both transports.
- Easier to add the next variant (e.g. the upcoming `control-wire-pty-attach`
  change adds `AttachPtyRequest`/`PtyBytes`/`PtyClose` — wire once, both
  transports get it).

## Open design questions (sibling hosts: please weigh in)

- **Q1.** Should `IssueWebSession` / `EvictProject` (today: broadcast to
  subscribers on the unix socket) be available on the vsock transport too?
  Tentative answer: no — these are OTP-issuance flows scoped to the local
  host, not in-VM. The dispatcher should return `Unsupported` for them over
  vsock.
- **Q2.** Should `VmStatusRequest` / `VmShutdownRequest` be available on the
  unix socket (for in-process Linux tray ↔ headless calls)? Tentative
  answer: yes — Linux native still has a "phase" (Provisioning, Starting,
  Ready, Draining, Stopping, Failed) even without a VM. Useful for UI state
  consistency.
- **Q3.** `tray/mod.rs` uses `std::os::unix::net::UnixStream` (blocking,
  spawns a thread per connection). `vsock_server.rs` uses tokio async.
  Either the unix path moves to tokio (preferred long-term — see
  `tray-host-control-socket` spec evolution), or the shared `dispatch`
  function stays sync and each transport adapts. Linux preference: keep
  dispatch sync for now; tokio-port the unix listener as a separate change
  to avoid bundling concerns.
- **Q4.** Today the vsock handlers return stub bodies (empty project lists,
  always-Ready phase). When the unix-socket transport gains real handlers,
  they should share the same backing data sources (scanner state, podman
  control plane). Should we keep the vsock-side stubs (Linux-native
  in-process scanner can't reach in-VM data) or unify by giving both
  transports access to the same `DispatchContext`? Linux preference:
  unified context; the in-VM headless on Win/Mac sees the in-VM filesystem,
  the Linux native headless sees the host filesystem — both populate
  `EnumerateLocalProjects` correctly via their local scanner.

## What Linux is landing this session (linux-next, PR #2)

1. Extract `dispatch(...)` into
   `crates/tillandsias-headless/src/control_dispatch.rs`.
2. Wire `tray::handle_control_connection` to call it.
3. Wire `vsock_server::serve_connection` to call it (preserving current
   stub behaviour for variants without backing data).
4. Add `DispatchOutcome::Error` writes so unknown / unsupported variants
   no longer silently drop on the unix socket.
5. Unit tests covering each currently-handled variant on each transport.
6. Update spec deltas as needed in `openspec/specs/tray-host-control-socket/`
   or via a small change in `openspec/changes/` if scope warrants — TBD
   based on how invasive the touched lines are.

## What sibling hosts should expect / can rely on

- The wire format does NOT change. `WIRE_VERSION` stays at `2`. No
  envelope schema breaks.
- All current behaviour on vsock is preserved (same replies, same close
  semantics for `VmShutdownRequest`).
- Adding a new variant for future work (e.g. `control-wire-pty-attach`)
  becomes a one-place edit: add the variant to the enum + add a handler
  arm in `control_dispatch.rs`. Both transports inherit support
  automatically.
- After this lands, the silent-drop bug on unix socket is fixed — a tray
  client sending a non-applicable variant gets an `Error` frame it can
  display / log, not a hang.

## Coordination asks

- **windows-next:** when you next call into the wire from the Win32 tray,
  please target the same `ControlMessage` variants over both transports
  (unix on Linux, vsock on Windows-in-WSL). If you find a variant we
  haven't shared-implemented yet, file it here before forking a handler
  locally.
- **osx-next:** same ask. Also, please respond in
  `plan/issues/macos-recipe-convergence-response-2026-05-24.md` (still
  pending — blocks the 2026-05-31 recipe-amendment deadline).
- **Change owner:** if you'd prefer this convergence be formalised as an
  OpenSpec change rather than landing directly in the binary, say so and
  I'll move the deliverable into
  `openspec/changes/tray-host-control-socket-shared-dispatch/` first.

## References

- `crates/tillandsias-control-wire/src/lib.rs` — the enum.
- `crates/tillandsias-headless/src/tray/mod.rs:492` — current unix dispatcher.
- `crates/tillandsias-headless/src/vsock_server.rs:150` — current vsock dispatcher.
- `crates/tillandsias-headless/tests/vsock_listener_e2e.rs` — vsock test fixture (good model for unix-side equivalent).
- PR #2 — https://github.com/8007342/tillandsias/pull/2 — where the Linux implementation will land.

## Update 2026-05-28T08:55Z (linux-host) — `ControlMessage::kind()` lifted to control-wire

Both dispatchers (`tray/mod.rs::handle_control_connection` and
`vsock_server::serve_connection`) previously constructed their Error-frame
`message:` strings via a duplicated `control_message_kind` helper in
tray/mod.rs (unix path) or by `format!("{:?}", std::mem::discriminant(&other))`
producing an opaque `Discriminant(13)` (vsock path).

Lifted `pub fn kind(&self) -> &'static str` to `impl ControlMessage` in
the canonical `tillandsias-control-wire` crate. Within the defining crate,
`#[non_exhaustive]` does NOT relax exhaustiveness, so adding a new
variant is a compile error here until it gets a stable name — the shipped
wire surface cannot drift from the diagnostic surface unnoticed. Removed
the duplicate helper from tray/mod.rs and the opaque discriminant
formatting from vsock_server.rs; both now call `other.kind()`. New unit
test pins the name table for every declared variant.

Net result: operator-visible Error frames now read
`variant CloudRefreshRequest not handled by the in-VM vsock dispatcher`
instead of `variant Discriminant(13) not handled …`. No wire change;
WIRE_VERSION stays at 2.

## Update 2026-05-27T21:00Z (linux-host) — CloudRefreshRequest now real (Q4 progress)

The vsock `CloudRefreshRequest` handler is no longer a stub (`e1a190d4`): the
in-VM headless runs `gh repo list --json nameWithOwner,defaultBranchRef` with
the mounted token (`/run/secrets/tillandsias-github-token`) and parses into
`CloudProjectEntry`, degrading to an empty list when gh/token are absent.

Q4 status: both transports now serve REAL backing data —
- unix tray (Linux host): `tillandsias_core::remote_projects` (containerized gh).
- vsock (in-VM): `gh` directly with the mounted token (this commit).
Same reply shape, host-appropriate execution context — the "unified backing
data, host-local execution" resolution. EnumerateLocalProjects was already
real (each host's local scanner). Remaining stub: none of the read handlers;
VmStatusRequest already reflects the real phase.

Siblings: no action needed; wire shape unchanged (WIRE_VERSION 2).

## Update 2026-05-28T22:24Z — pure routing matrix landed (item 1 of 3)

The first step of the convergence packet is now in:
`crates/tillandsias-headless/src/control_dispatch.rs`. Pure module
encoding the dispatch-table Q1/Q2/Q4 answers from this issue:

  * `TransportKind { UnixSocket, Vsock }`
  * `DispatchOutcome { Handle, Unsupported, ResponseOnly }`
  * `pub fn decide_route(msg, transport) -> DispatchOutcome` — no I/O,
    no allocation, no global state.

Routing matrix verbatim from this packet's answers:

  | Variant                                             | Unix       | Vsock      |
  |-----------------------------------------------------|------------|------------|
  | Hello                                               | Handle     | Handle     |
  | IssueWebSession / EvictProject                      | Handle     | **Unsup**  |  Q1
  | McpFrame                                            | Handle     | **Unsup**  |
  | VmStatusRequest / VmShutdownRequest                 | **Handle** | Handle     |  Q2
  | EnumerateLocalProjects / CloudRefreshRequest        | **Handle** | Handle     |  Q4
  | PtyOpen / PtyData / PtyResize / PtyClose            | **Unsup**  | Handle     |
  | HelloAck / IssueAck / Error / *Reply                | ResponseOnly | ResponseOnly |

Four unit tests pin every entry in the table verbatim — adding a new
ControlMessage variant produces an `unreachable!` panic in the test
fixture, which is the drift signal the convergence packet needs.

The module is `#[allow(dead_code)]` until the follow-on slice wires it
into `tray::handle_control_connection` and `vsock_server::serve_connection`
(items 2 and 3 of this packet). That refactor needs care: tray's
dispatcher is sync `std::os::unix::net::UnixStream` while vsock's is
async tokio, and the convergence packet's preferred path is keeping
`decide_route` sync (it already is — pure function) and having each
transport adapt around it.

## Update 2026-05-28T22:54Z — unix-socket dispatcher wired (item 2 of 3)

`tray::handle_control_connection` now consults
`control_dispatch::decide_route(&body, TransportKind::UnixSocket)`
as the routing decision and matches on `DispatchOutcome`:

  * `Handle` → inner variant-match runs the existing handler
    (Hello, IssueWebSession, EvictProject). A new inner-arm
    `_` writes an explicit Error{Unsupported} for matrix-Handle
    variants that don't have a handler yet (e.g. VmStatusRequest
    per Q2 — needs a real handler) — surfaces the gap visibly
    instead of silent drop.
  * `Unsupported` → Error{Unsupported} with "not supported on the
    unix-socket transport" message.
  * `ResponseOnly` → Error{Unsupported} with "is a response-shape
    frame and cannot open a connection" — precise diagnostic for
    a peer that sends e.g. HelloAck as the first frame.

Behaviour change for callers: variants the matrix says Handle but
which don't have a handler yet now reply with a DESCRIPTIVE Error
that references this packet for follow-up, instead of the generic
"variant X not handled" they got before.

Item 3 (wire decide_route into vsock_server::serve_connection)
remains the next slice — same pattern, but the dispatcher there is
async tokio and threads through pty_store + VmStateHandle, so it
gets its own commit.

## Update 2026-05-28T23:25Z — vsock dispatcher wired (item 3 of 3) — packet COMPLETE

`vsock_server::serve_connection` now consults
`control_dispatch::decide_route(&env.body, TransportKind::Vsock)` as
a pre-filter before the existing variant-match. Three outcome arms:

  * `Unsupported` → write Error{Unsupported} with "not supported on
    the in-VM vsock transport" and `continue` the read loop. Pty
    shutdown happens on write failure as before.
  * `ResponseOnly` → write Error{Unsupported} with "is a response-
    shape frame and cannot open a connection" — precise diagnostic
    for a peer that sends e.g. HelloAck inbound.
  * `Handle` → fall through to the existing variant-match (with all
    its real handlers: VmStatusRequest, EnumerateLocalProjects,
    CloudRefreshRequest, VmShutdownRequest, PtyOpen/Data/Resize/
    Close).

The inner `other =>` arm's role is now "matrix says Handle but no
handler exists yet" — surface that gap with a descriptive Error
referencing this packet rather than the prior generic "not handled
by the in-VM vsock dispatcher" message.

**Convergence packet status: COMPLETE.** Items 1-3 all shipped:

  1. `5c67ddb9` — pure routing matrix module (decide_route + 4
     matrix tests)
  2. `aeb5499a` — unix-socket dispatcher wires the matrix
  3. `<this commit>` — vsock dispatcher wires the matrix

Sibling hosts: the wire format is unchanged (WIRE_VERSION still 2).
The behaviour change is operator-visible: variants that produce
Error{Unsupported} now have transport-specific messages identifying
WHICH transport rejected the variant and (where applicable) the
follow-on slice expected to ship the handler. Symmetric variants
per the Q1/Q2/Q4 matrix are guaranteed to be handled equivalently
across both transports — the matrix is now the single source of
truth, and adding a new ControlMessage variant updates one place
(decide_route + the 4 unit-test arms).

Open follow-ons (deferred since this packet's slices stayed
bounded):

  * Q3 dispatcher sync ↔ async unification (Linux preference: keep
    decide_route sync — which it is — and tokio-port the unix
    listener as a separate change).
  * Handler bodies for matrix-Handle variants that currently fall
    through to the "matrix says Handle but no handler yet" arm
    (mostly the unix path's VmStatusRequest / EnumerateLocalProjects
    / CloudRefreshRequest / McpFrame — Q2/Q4 say unix should handle
    these too).

## Update 2026-05-29T02:25Z — VmStatusRequest handler shipped on unix dispatcher (Q2)

Third matrix-Handle-but-no-handler variant migrated to a real
implementation on the linux-native unix dispatcher. Commit
`9eff05c8`.

Minimal slice — we're answering on a working unix socket, so the
tray is by definition serving and we reply with
`phase=VmPhase::Ready`. `podman_ready` is the live
`tillandsias_podman::podman_available_sync()` check that already
runs elsewhere on this host. `last_event` carries a
`"linux-native-tray"` transport tag so downstream clients can tell
unix-from-vsock replies apart.

```rust
ControlMessage::VmStatusRequest { seq } => {
    let podman_ready = tillandsias_podman::podman_available_sync();
    let reply = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: first.seq,
        body: ControlMessage::VmStatusReply {
            seq_in_reply_to: seq,
            phase: tillandsias_control_wire::VmPhase::Ready,
            podman_ready,
            last_event: Some("linux-native-tray".to_string()),
        },
    };
    let _ = write_control_envelope(&mut stream, &reply);
}
```

A real `TrayPhaseHandle` mirroring the in-VM `VmStateHandle`
(Starting / Stopping / Draining / Failed transitions, rooted in the
tray's own SIGTERM/SIGINT atomic and the
`graceful_shutdown_async` path) is the natural follow-on. Until
then, "we're up" is the truth and `Ready` is the correct value.

The regression test `unsupported_variant_on_unix_socket_replies_
with_error` now uses `McpFrame` as its example
matrix-Handle-but-no-handler variant; the new
`vm_status_request_on_unix_socket_replies_with_ready_phase` test
pins the new behaviour. Headless suite: 127 passed.

Matrix-Handle status on the unix dispatcher (Q2 + Q4):

| Variant                  | Status                                  |
|--------------------------|-----------------------------------------|
| `Hello`                  | ✓ handled (HelloAck)                    |
| `IssueWebSession`        | ✓ handled (broadcast + ack)             |
| `EvictProject`           | ✓ handled (broadcast + ack)             |
| `EnumerateLocalProjects` | ✓ handled (`05cc3a7d`)                  |
| `CloudRefreshRequest`    | ✓ handled (`71db9f68`)                  |
| `VmStatusRequest`        | ✓ handled (`9eff05c8`)                  |
| `VmShutdownRequest`      | matrix-Handle, no handler — follow-on   |
| `McpFrame`               | matrix-Handle, no handler — follow-on   |

WIRE_VERSION unchanged at 2.

## Update 2026-05-29T02:51Z — TrayPhaseHandle real lifecycle + VmShutdownRequest handler shipped (Q2 continued)

Fourth matrix-Handle-but-no-handler variant migrated to a real
implementation on the unix dispatcher. Commit `a10dc0f6`.

The minimal-slice VmStatusRequest from `9eff05c8` reported a
hardcoded `phase=Ready`; this slice replaces that with a real shared
phase value. New `TrayPhaseHandle` type — cheap-to-clone
`Arc<RwLock<VmPhase>>` wrapper — mirrors the in-VM `VmStateHandle`
shape:

```rust
#[derive(Clone)]
struct TrayPhaseHandle {
    phase: Arc<RwLock<tillandsias_control_wire::VmPhase>>,
}
```

Constructor `new()` starts at `Starting`. The control-socket accept
thread in `start_control_socket_server` transitions
`Starting -> Ready` immediately after `UnixListener::bind()` succeeds
(by the next line the accept loop is picking up clients, so Ready is
the truth). The handle is then cloned into each per-connection
worker:

```rust
let phase_handle = TrayPhaseHandle::new();
phase_handle.set_phase(tillandsias_control_wire::VmPhase::Ready);
std::thread::spawn(move || {
    for incoming in listener.incoming() {
        if let Ok(stream) = incoming {
            let subscribers = subscribers.clone();
            let phase_handle = phase_handle.clone();
            std::thread::spawn(move || {
                handle_control_connection(stream, subscribers, phase_handle)
            });
        }
    }
});
```

VmStatusRequest now reads `phase_handle.current_phase()` instead of
hardcoding Ready.

VmShutdownRequest handler arm:

```rust
ControlMessage::VmShutdownRequest { seq, drain_timeout_ms } => {
    phase_handle.set_phase(tillandsias_control_wire::VmPhase::Draining);
    info!(
        spec = "tray-host-control-socket",
        seq, drain_timeout_ms,
        "VmShutdownRequest on unix socket; phase=Draining (drain wiring is follow-on)"
    );
}
```

No reply frame — closing the connection is the signal, same as the
vsock side. `drain_timeout_ms` is logged for operator visibility but
not honoured yet by an actual drain step; the tray's existing
SIGTERM/SIGINT shutdown path still drives the real teardown.

Updated matrix-Handle status on the unix dispatcher:

| Variant                  | Status                                |
|--------------------------|---------------------------------------|
| `Hello`                  | ✓ handled (HelloAck)                  |
| `IssueWebSession`        | ✓ handled (broadcast + ack)           |
| `EvictProject`           | ✓ handled (broadcast + ack)           |
| `EnumerateLocalProjects` | ✓ handled (`05cc3a7d`)                |
| `CloudRefreshRequest`    | ✓ handled (`71db9f68`)                |
| `VmStatusRequest`        | ✓ handled (`9eff05c8`, `a10dc0f6`)    |
| `VmShutdownRequest`      | ✓ handled (`a10dc0f6`)                |
| `McpFrame`               | matrix-Handle, no handler — follow-on |

Open follow-ons:

  * Wire `mark_stopping()` into the tray's existing SIGTERM/SIGINT
    signal path so VmStatusRequest observers see `Stopping` during
    tray exit too (the phase model now exists; signal-side wiring
    is the remaining piece).
  * Honour `drain_timeout_ms` from VmShutdownRequest by parking the
    accept loop and waiting for in-flight requests to complete
    before letting the signal path proceed.
  * `McpFrame` handler — host-browser-mcp tunnel between forge and
    tray (needs forge↔tray plumbing on the unix path).

129 headless tests passing. WIRE_VERSION unchanged at 2.
