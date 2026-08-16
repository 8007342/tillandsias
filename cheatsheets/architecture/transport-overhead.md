---
tags: [transport, vsock, hvsocket, overhead, polling, live-client, control-wire, performance]
languages: [rust]
since: 2026-08-16
last_verified: 2026-08-16
sources:
  - crates/tillandsias-windows-tray/src/notify_icon.rs
  - crates/tillandsias-headless/src/main.rs
  - crates/tillandsias-headless/src/vsock_server.rs
authority: high
status: current
tier: committed
summary_generated_by: "windows meta-orchestration cycle, orders 147 + 690-xeda"
bundled_into_image: false
committed_for_project: true
---

# Transport Overhead Guarantee

@trace spec:cheatsheet-tooling, spec:vsock-transport

**Version baseline**: workspace v0.5 (audited at orders 147 / 690-xeda)
**Use when**: touching the host↔guest control wire, adding a poll/refresh
loop, or reviewing whether a change keeps the transport near-zero at idle.

## Provenance

- Order 147 `transport-negligible-overhead-audit` (plan ledger) — the audit
  this document closes the doc criterion of.
- Order 690-xeda `steady-state-polling-and-idle-wakeups` — measured idle
  wakeups and event-driven rewires; measurements quoted below.
- **Last updated:** 2026-08-16 (windows host, live-guest verification)

## The guarantee

The HvSocket/vsock control-wire stack adds NEGLIGIBLE overhead:

1. **Amortized O(0) connection setup.** The host tray keeps ONE persistent
   control-wire client (`LIVE_CLIENT`, a `OnceLock<Mutex<Option<Client>>>` in
   `crates/tillandsias-windows-tray/src/notify_icon.rs`). Every refresh
   reuses it on the fast path; a fresh connect + handshake happens only when
   the live client is absent or a request failed (`live_client_request`,
   same file). It is NOT reopened per poll tick.
2. **O(1) framing per message.** Postcard-encoded envelopes; no per-message
   allocation beyond the frame itself, no re-handshake per request.
3. **No steady-state polling NOOPs.** Refresh bodies are push-gated on the
   host (`should_poll_fallback`) and probe loops are subscriber-gated and
   event-driven in the guest (order 690-xeda): the liveness probe is driven
   by the `podman events` stream (300s backstop only), the login-state and
   local-projects loops PARK on `VmStateHandle::subscriber_nudge` when they
   have zero subscribers, and non-Ready phases park on the VmStatus push
   stream. Single-shot requests (`refresh_vm_status`,
   `refresh_github_login`) contain no retry loops — one fast-path attempt,
   at most one reconnect, then return.

## Evidence (measured, not asserted)

- Guest idle wakeups: 79 ctx-switches/20s (~4/s) baseline → 3 ctx/90s
  (~0.03/s) after the order 690-xeda event-driven rewires (measured
  2026-08-15 on a live idle guest, no client attached; methodology:
  voluntary+nonvoluntary context switches from `/proc/<pid>/status`).
- Tray steady-state: fallback poll bodies suppressed while the push
  subscription is healthy (orders 155/260); macOS residual timer justified
  in-code (690-xeda macOS event, 2026-08-16).

## Common pitfalls

- **Opening a connection inside a refresh function.** Route every request
  through `live_client_request` — it owns reuse and reconnect policy.
- **Adding a steady-state timer.** Polling is forbidden by doctrine;
  subscribe to an observable stream (`podman events`, VmStatus push,
  `subscriber_nudge`) and keep at most a LONG documented backstop. Every
  surviving timer must carry a written justification naming its removal
  condition (the 690-xeda pattern).
- **Trusting a flattering measurement.** A beautiful zero can be the wakeup
  count of a dead process — validate `MainPID` is alive and unchanged
  across the window before believing an idle measurement (690-xeda
  near-miss, 2026-08-15).
- **`notify_waiters` has no stored permit.** A subscribe landing between a
  loop's gate check and its `notified().await` is missed — always pair the
  park with a bounded backstop timeout.

## See also

- `architecture/event-driven-basics.md`
- `architecture/event-driven-ui-updates.md`
