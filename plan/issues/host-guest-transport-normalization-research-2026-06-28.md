# Research: Host↔Guest Transport Normalization (vsock, all platforms)

**Status:** `completed`
**Owner:** linux (research) — drives osx/windows implementation packets
**Date:** 2026-06-28
**Kind:** research
**Trace:** `spec:vsock-transport`, `spec:vm-idiomatic-layer`, `spec:tray-host-control-socket`

## Operator Mandate

> "[All platforms] have been drifting trying to fix different versions of the
> same problem: connecting from a host to a guest. We've been hacking the
> architecture, and it's time to make vsock properly implemented on all
> implemented layers for interactive streams, and commandline exec for quick
> interactions and one-off reads. … standardise protocols, layers, nomenclature,
> etc, and make sure that linux, windows, and macos tray all have 1:1 feature
> parity and user experience."

Release gate: a release will be cut **after the macOS host completes its current
work** — so this normalization lands across branches first, then ships together.

## The Drift (current state, evidence)

Three independent "connect host→guest" implementations have grown organically,
each fixing a local symptom of the same problem:

| Layer | Linux | macOS | Windows |
|---|---|---|---|
| Stream transport | `control-wire::Transport::Vsock{cid,port}` (tokio-vsock, Linux-only) | `vm-layer/transport_macos.rs` (`VZVirtioSocketDevice`) | `vm-layer/wsl.rs` (WSL pipe/hvsock) |
| Same-host fallback | `control-wire::Transport::Unix(path)` | Unix | Unix |
| One-shot exec | `vm-layer/vsock_exec.rs` — **5** overlapping `exec_over_stream*` fns | partially reuses vsock_exec via VZ stream | wsl.rs exec path |

Evidence:
- `control-wire/transport.rs` doc: "Vsock is … `Vsock` variant returns
  `io::ErrorKind::Unsupported`" on non-Linux — so the shared crate does NOT carry
  the macOS/Windows host transports; they live in `vm-layer` instead.
- `vsock_exec.rs` exposes 5 one-shot variants: `exec_over_stream`,
  `exec_over_stream_with_input`, `exec_over_stream_with_input_streaming`,
  `exec_over_stream_expect`, `exec_over_stream_expect_dynamic`. This is API sprawl
  for what should be **two** primitives.
- Nomenclature varies across the tree: `vsock` (83×), `VZVirtioSocket` (24×),
  `VsockStream` (22×), `virtio-vsock` (4×), `AF_VSOCK`, `hvsock`, "control-wire",
  "transport", "control socket" — no canonical glossary.
- Open issues all circling this one problem: `control-socket-protocol-convergence`,
  `optimization-macos-vz-idiomatic-exec-layer`, `tray-convergence-coordination`,
  `macos-tray-github-login-blank-terminal`, `windows-next-architecture-decision`.

## Two Canonical Primitives (the target)

The operator named exactly two host↔guest interaction modes. Normalize everything
to these:

1. **InteractiveStream** — a long-lived, bidirectional, low-latency byte stream
   for PTY/attach sessions (terminal agents, login flows). Backpressure-aware,
   resize-aware, survives partial reads.
2. **ExecOneShot** — a run-to-completion command for quick interactions and
   one-off reads (status probes, single config/secret reads, `gh api` style
   calls). Request → {stdout, stderr, exit code}, with optional stdin and an
   optional streaming-callback variant. Replaces the 5 `exec_over_stream*` fns.

## Questions This Packet Must Answer (deliverable)

1. **Layer boundary:** Does the unified transport abstraction live in
   `tillandsias-control-wire` (so all platforms share one `GuestTransport`
   trait with per-OS backends behind features), or does `control-wire` stay
   stream-only and `vm-layer` own a `GuestChannel` facade? Decide the single
   home and the trait shape, with the rule that **no tray/headless caller picks a
   transport by `cfg!(target_os)`** — they ask for `InteractiveStream` /
   `ExecOneShot` and the layer resolves the backend.
2. **Backend matrix:** the canonical backend per platform and the CID/port/pipe
   addressing model unified under one `GuestEndpoint` type (Linux AF_VSOCK,
   macOS VZ virtio-vsock, Windows WSL/hvsock). Where each backend's "connect from
   host" actually executes.
3. **Exec consolidation:** map the 5 `exec_over_stream*` variants onto the single
   `ExecOneShot` API (+ a streaming variant) and list every call site to migrate.
4. **Wire protocol canon:** confirm one framing (length-prefixed `encode/decode`,
   `WIRE_VERSION`, `MAX_MESSAGE_BYTES`, `Hello/HelloAck`) is the single protocol
   for BOTH primitives on ALL transports; document the handshake + version-skew
   contract once.
5. **Nomenclature canon:** a glossary fixing one term per concept
   (host/guest, endpoint, transport, channel, stream vs exec, CID, port). Retire
   the synonyms (`hvsock`, `virtio-vsock`, `VZVirtioSocket` become *backend impl
   names*, not protocol names).
6. **Parity definition:** the authoritative list of tray features/UX that MUST be
   1:1 across linux/macos/windows (see the parity-matrix packet), and which are
   genuinely platform-specific (and why).
7. **Migration safety:** `WIRE_VERSION` must not break mid-migration; sequencing
   so each branch can land its backend independently behind the unified facade.

## Deliverable

A target-architecture verdict appended here: the `GuestTransport`/`GuestChannel`
trait + `GuestEndpoint` type + the two primitive signatures + backend matrix +
the nomenclature glossary + the exec-migration map + the openspec spec to author.
This feeds the normalization-spec packet and the three per-platform impl packets.

## Spawned Packets (filed alongside this)

- `host-guest-transport-normalization-spec` — author the canon (openspec spec + glossary + facade API)
- `host-guest-transport-linux` — Linux backend conforms; collapse the 5 exec fns → ExecOneShot
- `host-guest-transport-macos` — macOS VZ virtio-vsock backend conforms (owner: osx)
- `host-guest-transport-windows` — Windows WSL/hvsock backend conforms (owner: windows)
- `tray-feature-parity-matrix` — verifiable 1:1 tray feature/UX parity across platforms

## Related (the drift this supersedes/coordinates)

- `plan/issues/control-socket-protocol-convergence-2026-05-25.md`
- `plan/issues/optimization-macos-vz-idiomatic-exec-layer-2026-06-21.md`
- `plan/issues/tray-convergence-coordination.md`
- `plan/issues/macos-tray-github-login-blank-terminal-2026-06-21.md`
- `plan/issues/windows-next-architecture-decision-2026-05-24.md`
- `container-dependency-graph` (orders 121/122) — same "make implicit architecture explicit" theme

---

## Design Verdict (2026-06-28)

Concrete decisions for the normalization-spec packet (order 124) and the three
per-platform conformance packets (125/126/127).

### 1. Layer home (no cycle, no cfg in callers)
- **`tillandsias-control-wire`** owns the **contract**: the `GuestTransport`
  trait, the `GuestEndpoint` addressing type, and the `ExecRequest` / `ExecOutput`
  value types — alongside the existing wire protocol (`encode/decode`,
  `WIRE_VERSION`, `MAX_MESSAGE_BYTES`). It already has no `cfg`-divergent public
  API and no dependency on `vm-layer`.
- **Backends** implement the trait where the platform code lives:
  - Linux AF_VSOCK + same-host Unix → in `control-wire` (it already has
    `tokio-vsock`, gated by the `vsock` feature).
  - macOS VZ virtio-vsock → in `vm-layer` (`transport_macos.rs`/`vz.rs`).
  - Windows WSL/hvsock → in `vm-layer` (`wsl.rs`).
- Callers hold a `Box<dyn GuestTransport>` resolved **once at the platform
  boundary** and never branch on `cfg!(target_os)`. Enforced by
  `litmus:host-guest-no-cfg-transport-selection`.

### 2. Facade shape (object-safe via `async-trait`)
```rust
// control-wire::guest_transport
pub enum GuestEndpoint {
    Unix(PathBuf),                 // same-host headless
    Vsock { cid: u32, port: u32 }, // Linux AF_VSOCK
    MacVz { port: u32 },           // macOS VZ virtio-vsock (CID resolved by backend)
    Wsl   { port: u32 },           // Windows WSL (pipe/hvsock resolved by backend)
}

pub struct ExecRequest { pub argv: Vec<String>, pub stdin: Option<Vec<u8>> }
pub struct ExecOutput  { pub stdout: Vec<u8>, pub stderr: Vec<u8>, pub exit_code: i32 }

#[async_trait::async_trait]
pub trait GuestTransport: Send + Sync {
    /// InteractiveStream — long-lived bidirectional byte stream (PTY/attach).
    async fn open_stream(&self, ep: &GuestEndpoint)
        -> io::Result<Box<dyn AsyncReadWrite + Unpin + Send>>;
    /// ExecOneShot — run-to-completion command for quick reads / one-offs.
    async fn exec(&self, ep: &GuestEndpoint, req: ExecRequest) -> io::Result<ExecOutput>;
    /// ExecOneShot with incremental stdout/stderr delivery.
    async fn exec_streaming(
        &self, ep: &GuestEndpoint, req: ExecRequest,
        on_chunk: &mut (dyn FnMut(ExecChunk) + Send),
    ) -> io::Result<ExecOutput>;
}
```
`open_stream` returns the same `AsyncReadWrite` the wire layer already frames, so
the PTY/attach framing is unchanged. `exec*` use the existing `encode/decode` +
`Hello/HelloAck` + `WIRE_VERSION` handshake — one protocol for both primitives.

### 3. Exec consolidation (5 → 2)
| Current `vsock_exec.rs` fn | New facade method |
|---|---|
| `exec_over_stream` | `exec` (no stdin) |
| `exec_over_stream_with_input` | `exec` (with `stdin`) |
| `exec_over_stream_with_input_streaming` | `exec_streaming` |
| `exec_over_stream_expect` | `exec` + caller asserts (drop bespoke expect) |
| `exec_over_stream_expect_dynamic` | `exec_streaming` + caller predicate |
Order 125 migrates the call sites; the `exec_over_stream_*` symbols are retired
(grep litmus).

### 4. Nomenclature glossary (canonical term per concept)
- **host / guest** — the two endpoints (never "VM side"/"native side").
- **GuestEndpoint** — where/how to reach the guest (the addressing value).
- **GuestTransport** — the backend that opens streams / runs exec.
- **InteractiveStream** / **ExecOneShot** — the two primitives.
- **CID / port** — vsock addressing fields.
- `vsock` = the protocol family; **`virtio-vsock` / `hvsock` / `VZVirtioSocketDevice`
  are backend implementation names only**, never used as the protocol's name in
  public APIs, logs, or docs.

### 5. Parity
Enumerated separately in `tray-feature-parity-matrix` (order 128); the
InteractiveStream/ExecOneShot rows there are the acceptance gate proving the
backends deliver identical UX.

### 6. Migration safety
`WIRE_VERSION` stays 2 (additive only). Order 124 lands the contract + Linux
reference backend + a stub for macOS/Windows backends (`unblock-noop`, marked
`PLEASE REVIEW: osx|windows`) so 126/127 compile against a real interface and
each backend lands independently behind the facade.

**Status:** research complete → order 124 ready.
