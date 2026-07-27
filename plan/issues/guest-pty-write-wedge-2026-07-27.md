# Guest PTY: write_to_guest blocks unboundedly inline in the connection loop — wedge kills the session/connection (D6 follow-up)

- **Date:** 2026-07-27 (split out of `macos-terminal-management-audit-2026-07-27.md`, defect D6)
- **Class:** bug (P2) — guest tillandsias-headless (shared by all wire trays)
- **Status:** ready
- **Pickup role:** any host (guest-only code, `#[cfg(unix)]`); good in-forge candidate

## Defect (CONFIRMED by adversarial verifier, 2026-07-27)

`write_to_guest` loops `while written < bytes.len()` awaiting
`master.writable()` with no deadline
(`crates/tillandsias-headless/src/pty_handler.rs:284-325`) and is awaited
INLINE in the single `'connection: loop` select arm
(`crates/tillandsias-headless/src/vsock_server.rs:1079`). While it pends:

- the sole drain of the 64-cap pty outbound channel stops
  (vsock_server.rs:188, 704-710) → pump tasks block on `outbound.send()`
  (pty_handler.rs:586) → ALL ToHost output stalls;
- inbound `PtyResize` (:1095-1101), `PtyClose` (:1103-1107 — the only host
  path to SIGTERM a wedged child), and `connection_shutdown` (:699) are
  never polled.

Wedge condition is real: guest PTY is cooked (pty_handler.rs:448); a live
child holding the slave but not reading caps master→slave at ~8KB flip +
4KB canonical buffer; one max PtyData frame is 64,000 bytes
(control-wire lib.rs:62) > kernel buffering — a single large paste or
sustained input during a busy cooked phase wedges the session unkillably.
Violates the ≤250ms control-plane fairness bound
(openspec/changes/control-wire-pty-attach/specs/vsock-transport/spec.md:118,:125).

Scope caveat: today the macOS tray opens one vsock connection per attach
(action_host.rs:1174-1187), so blast radius is one session per wedge;
multi-session-per-connection (protocol-supported) gets the full stall.

## Fix shape (from verifier risk analysis — honor all constraints)

1. Per-session bounded write queue drained by a per-session writer task; the
   connection loop only enqueues (bounded, e.g. `tokio::time::timeout`
   ≤250ms on the enqueue, to keep the fairness bound honest while full).
2. Wedge deadline = queue FULL for the deadline (NOT queue-nonempty — else
   legitimate type-ahead during long cooked builds gets the forge killed).
   On trip: close the session via the existing SIGTERM+2s+SIGKILL path
   (pty_handler.rs:347-373) + emit PtyClose. Kill-not-drop: dropping frames
   recreates the UTF-8 tearing ea2fbc8d fixed.
3. Writer task cannot call `close_host_initiated` directly (needs
   `&mut PtySessionStore` owned by the loop) — signal teardown via a channel
   the loop drains.
4. Ordering note: if PtyResize stays inline while data moves to the queue,
   TIOCSWINSZ can apply ahead of earlier-arrived input bytes — route resize
   through the same per-session queue to preserve arrival order.
5. Deadline must be an event-driven timeout on the awaited send/writable —
   never a periodic queue-inspection loop (no-polling policy).

## Tests to keep green / add

- `post_store_connection_exits_share_pty_cleanup` (vsock_server.rs:1591-1610)
  — exactly one `pty_store.shutdown_all().await;`, no early `return;`.
- Struct-literal constructions of PtySessionStore (pty_handler.rs:638-641,
  670-674) break if fields change — update.
- SC-10 fairness test (vsock_server.rs:1637) must stay green; add a wedge
  test: child that never reads + >12KB input → control replies still flow,
  session killed after deadline.

## Trigger note

The 2026-07-27 checkpoint removes the common trigger (scroll→arrow-key spam
during builds: DECRST at attach + guest echo-off), but large pastes into a
busy cooked phase still reach the wedge — fix properly.
