## Context

The existing `tillandsias-control-wire` exposes a postcard-framed `ControlEnvelope { wire_version, body: ControlMessage }` over a single vsock connection per host-to-VM pair. The `ControlMessage` enum is `#[non_exhaustive]` and already carries Hello/HelloAck, VM lifecycle, project enumeration, and a `JsonRpc` payload variant. The 4-byte big-endian length prefix and `MAX_MESSAGE_BYTES` ceiling are stable invariants from `spec:vsock-transport`.

What's missing is a way to attach an interactive subprocess to a host-side terminal. The macOS tray's "Open Shell" menu item, the `--opencode` workflow that needs a TTY to render its REPL, and the device-code paste step of `--github-login` all require:
1. Allocating a PTY in the VM and a counterpart PTY (or pseudo-tty fd group) on the host.
2. Multiplexing bidirectional byte streams over a connection that already carries control envelopes.
3. Relaying SIGWINCH so the in-VM PTY rows/cols track the host terminal window.
4. Propagating exit status cleanly without breaking the control connection.

Opening a second vsock port for PTY traffic was considered (it would let PTY data avoid the postcard frame overhead). Rejected for D3 below.

## Goals / Non-Goals

**Goals:**
- One vsock connection carries both control envelopes and any number of concurrent PTY sessions, distinguished by `session_id`.
- PTY session lifecycle (open / write / resize / close) maps 1:1 to four new `ControlMessage` variants.
- Wire is forward-compatible: a peer without `pty.attach@v1` continues to function for non-PTY traffic.
- The host-side bridge code lives in `tillandsias-host-shell::pty`, kept platform-agnostic enough to share between macOS (`nix::pty`) and Windows (ConPTY).
- Backpressure: a slow PTY consumer (e.g. tray window minimized, host terminal scrolled into pager) must not block control-plane traffic on the same connection.

**Non-Goals:**
- Non-PTY raw byte streams (e.g. file transfer) — use `JsonRpc` or future dedicated variants.
- Persistent sessions surviving reconnect — PTY sessions die with the connection; relaunch is the host's job.
- Negotiating per-stream compression — postcard + vsock is fast enough at this granularity; lz4/zstd would just burn CPU.
- Multiplexing multiple host trays onto one in-VM headless's PTY (only one tray attaches per host).
- True terminal emulation on the host (we use the user's existing terminal app; we are the glue, not the renderer).

## Decisions

### D1: Four new `ControlMessage` variants, not a dedicated port

`PtyOpen / PtyData / PtyResize / PtyClose` each carry `session_id: u32`. The receiver dispatches by variant first, then by session id. The wire format is unchanged: same `ControlEnvelope`, same length-prefixed framing.

**Why over alternatives:**
- A second vsock port (e.g. 42421) for PTY traffic — saves ~3 bytes per frame, costs an entire port + CID negotiation + reconnect choreography + a fresh capability negotiation. Not worth it.
- A single `RawStream` variant with subtypes — collapses the session lifecycle into untyped payload bytes; loses the postcard schema's role as documentation.
- gRPC-style streaming RPC — would require a brand-new framing layer; postcard's additive enum encoding gives us streaming-equivalent for free.

### D2: `session_id` is allocated by the host, scoped to the connection

Host increments a per-connection `AtomicU32` starting at 1 (id 0 reserved for "not a session"). Guest echoes the id verbatim on every reply. On reconnect, ids reset — there is no cross-connection session continuity. This matches the host-shell philosophy that the host is the authoritative session manager.

**Why over alternatives:**
- Guest-allocated ids — would require the guest to manage a registry visible to the host; complicates restart semantics.
- UUIDv7 — overkill for a per-connection counter. 4 bytes (u32) vs 16 (uuid) on every frame matters when streaming `cargo build` output.

### D3: PTY traffic and control traffic share one connection — backpressure via per-session bounded channel

On the host side, each `PtySession` owns a bounded MPSC channel of `Vec<u8>` chunks (capacity ~256 frames = ~16 MiB pending). The connection writer pulls from a `select!` of (control-envelope queue, all session queues). If a session queue fills, the host PTY's reader blocks via OS pipe backpressure; control envelopes still flow.

**Why:** keeps the wire single, makes the dependency graph (sessions → connection) explicit, and lets us use `tokio::select!` to enforce fair scheduling between control and PTY traffic.

### D4: `Hello` capability negotiation gates PTY usage

`Hello { capabilities: [..., "pty.attach@v1"] }` is the gate. A peer that omits the capability MUST NOT receive `Pty*` envelopes. This lets us iterate the PTY protocol independently of the control envelope (e.g. a future `pty.attach@v2` adds env-var passthrough; v1 peers ignore the new field). Versioned capability strings match the precedent already established for control wire (`wire_version` for the envelope, capabilities for opt-in extensions).

### D5: `MAX_PTY_FRAME_BYTES = 65536`

Postcard envelope + 4-byte length prefix + bookkeeping fits under the existing `MAX_MESSAGE_BYTES`. 64 KiB is the common page-aligned read size and matches `tty_buffer.c` chunking in Linux. Larger reads chunk transparently at the sender.

### D6: PTY exit propagates as `PtyClose { session_id, exit: { code: i32, signal: Option<i32> } }` from guest to host

Mirrors `WIFEXITED` / `WIFSIGNALED` semantics. Host can show "exited 0" / "killed by SIGINT" in the tray's status text. Host-initiated close is sending `PtyClose` to the guest, which is interpreted as a SIGTERM-then-SIGKILL escalation on the in-VM child.

## Risks / Trade-offs

- **[R1] A noisy PTY (e.g. `tail -f` of a multi-MB log) saturates the vsock connection and delays control envelopes.** → Mitigation: the per-session bounded channel (D3) caps per-session memory and triggers PTY backpressure via OS pipe semantics. The connection scheduler interleaves control and PTY frames. If empirical testing shows control latency spikes, raise the priority of `ControlEnvelope::body != PtyData` in the select.
- **[R2] `Hello` capability bloat as features accrue.** → Acknowledged. We're starting with one capability string today; future audits can compact via a bitfield if the list passes ~16 entries.
- **[R3] ConPTY semantics on Windows differ from Unix PTYs (e.g. cooked mode, signal handling).** → Acknowledged; the abstraction in `tillandsias-host-shell::pty` documents the platform delta. Windows tray work owns Windows-specific oddities; macOS tray uses the Unix path verbatim.
- **[R4] Postcard's enum encoding writes a discriminant byte per envelope; for a `PtyData` storm, that overhead is ~1% of frame size — acceptable.**
- **[R5] Backwards compatibility regression: if a `Pty*` variant is sent to a v1-only peer that hasn't yet learned the variant, postcard decode errors close the connection.** → Mitigation: the capability gate (D4) prevents this exact scenario. Implementers must check `peer.capabilities.contains("pty.attach@v1")` before sending.
- **[R6] PTY environment leakage: passing the host's full `env` into the VM child could leak host paths and tokens.** → Mitigation: `PtyOpen.env` is an explicit allowlist provided by the caller (default empty); the host shell builds it from a curated set (`TERM`, `LANG`, `COLORTERM`). Specs codify this.

## Migration Plan

1. Land the spec delta and the `tillandsias-control-wire` enum + capability extensions on `linux-next` (no consumers yet).
2. Implement the `tillandsias-headless` in-VM handler — gated behind a `--enable-pty-attach` flag during rollout. Tests via integration-test fake control wire.
3. Implement `tillandsias-host-shell::pty` and a developer-facing CLI (`tillandsias-host-shell pty-test`) that opens `sh` on a vsock connection. Useful for smoke-testing without the tray.
4. Wire into `tillandsias-macos-tray` "Open Shell" menu item once §1–3 are green.
5. Symmetric wire into `tillandsias-windows-tray` (ConPTY path).
6. Remove the `--enable-pty-attach` flag once `tillandsias-vault` and the trays both ship with it on.

Rollback: revert the in-VM handler (or set `--enable-pty-attach=false`). The capability disappears from `HelloAck`; host trays automatically suppress PTY menu items.

## Open Questions

- **Stdin echo / line discipline:** does the host need to send `PtyOpen.line_discipline: enum { Raw | Cooked }` or is per-session `stty raw` from inside the guest sufficient? *Default:* `Raw` always — the host's terminal app handles cooked-mode emulation; we forward bytes verbatim.
- **Signal forwarding:** when the user hits `Ctrl-C` in the host terminal, do we want a dedicated `PtySignal { session_id, signal: i32 }` variant or rely on the bytes (`0x03`) flowing through `PtyData`? *Default:* bytes-only for v1; revisit if any host terminal app strips control bytes before forwarding.
- **Window-title relay:** terminals send escape sequences like `OSC 0; …` to update window title. Do we strip these, pass through, or transform? *Default:* pass through verbatim — the user's terminal app handles them natively.
- **PTY environment allowlist source of truth:** `methodology/` or `spec:vsock-transport`? *Default:* spec, since it's wire-visible.
