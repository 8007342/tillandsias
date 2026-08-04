# Fragment overlay loses LWW status updates and event appends on NEW packets

- **Classified**: `bug` (correctness — ledger bookkeeping silently lost)
- **Date**: 2026-08-01
- **Filed by**: forge-opencode-metaorch-20260801 (forge host)
- **Order**: 585-v2fa (minted via `tillandsias-plan next-order`, never picked)
- **Reproduction**: fully verified below; synthetic ledger + real CLI, not prose.

## Summary

`crates/tillandsias-plan/src/fragments.rs::fold()` applies the LWW `status:`
register and `events:` appends to the MERGED DOCUMENT BEFORE it appends the
fragment-only packets, so **no packet that exists only in a fragment can ever
have its status changed or receive an appended event**. Since the CRDT filing
model makes EVERY newly-filed packet fragment-only (that is the whole point of
the overlay), this means: file a packet today → its status is frozen at whatever
the filing fragment declared → `ready` can never become `claimed`,
`in_progress`, or `completed` through the overlay.

Discovered while closing packet 583-2bpw (its completion fragment was written
and verified absent). This is the ledger's core bookkeeping path, so it blocks
the reduction loop's own record-keeping, not just one packet.

## Root cause (fold order in `fold()`)

```rust
apply_to_packets(&mut merged, &new_events, &lww); // walks `merged` == base only
append_packets(&mut merged, new_packets);         // fragment-only packets added AFTER
```

`apply_to_packets` (line 266) walks `merged`, which at that point is the base
clone plus nothing. `append_packets` (line 267) then extends the packet
sequence with the G-Set adds. A fragment-only packet therefore never passes
through the LWW/event application pass, and its inline `status: ready` (from the
filing fragment) is baked in. The module doc (line 35) declares `status:` an
LWW-Register "applied to ANY packet" — the implementation only reaches base
packets.

The existing tests never caught it because every LWW/event test operates on the
base packet `alpha`; no test folds a status/event update onto a fragment-only
packet.

## Reproduction (run with the compiled CLI)

Fixture:

```
base:      packets: alpha (ready)
fragment1: packets: gamma (ready)          <- fragment-only packet
fragment2: status: gamma -> completed
fragment3: status: alpha -> claimed; events: note on alpha AND on gamma
```

Results:

| packet | declared status via LWW | observed `status` | correct? |
|---|---|---|---|
| `alpha` (base) | claimed | `claimed` | yes |
| `gamma` (fragment-only) | completed | `ready` | **no — LWW silently dropped** |

The event appended to `gamma` is dropped by the same pass; the event on `alpha`
survives. `check` reports `ok: 2 packets` because the ledger is structurally
sound — the loss is semantic, invisible to validation, which is the dangerous
shape.

## Why this is worse than a missing feature

- A newly filed packet cannot be marked `done` or `blocked`, so `ready [role]`
  queues keep serving completed work and `burndown` mis-counts.
- The failure is SILENT: reads are consistent, nothing fails, no validator
  complains — the same "verified where written ≠ where read" shape order 569
  exists to kill.
- Any host that "hygiene-edits" a fragment packet's status to completed would
  appear to succeed while the ledger state never changes.

## Suggested fix direction (NOT implemented this cycle — one-packet rule)

Swap the last two statements of `fold()`:

```rust
append_packets(&mut merged, new_packets);  // fragment-only packets present FIRST
apply_to_packets(&mut merged, &new_events, &lww); // then LWW/events reach them
```

The LWW winner is chosen by `(ts, host)` over ALL fragments, so the inline
`status: ready` on the G-Set add loses to a later `completed` deterministically
and order-independently; idempotency holds because the LWW comparison is a pure
function of the fragment set. Must be pinned by a unit test that folds a
`status:` update + an event onto a fragment-only packet (mirroring this
reproduction) before the swap is trusted. Also update the doc line asserting the
property, and consider a variant of the swap for the compaction path (which
must fold the same way a read does).

## Smallest next action

Take order 585-v2fa from this issue, apply the swap, add the failing-test-first
unit test in `fragments.rs`, run `cargo test -p tillandsias-plan` with a
writable TMPDIR, and verify with the CLI against a synthetic fixture like the
one above. Closing 583-2bpw (and every future fragment packet) depends on this.
