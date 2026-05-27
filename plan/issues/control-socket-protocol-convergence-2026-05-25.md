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
