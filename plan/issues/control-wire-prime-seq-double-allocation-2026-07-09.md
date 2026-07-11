# optimization: push-listener initial-sync primes allocate two seqs per request

- classification: optimization (cosmetic wire hygiene, no functional impact today)
- discovered_by: meta-orchestration (macos), order 155 slice 2 implementation
- date: 2026-07-09
- scope: `crates/tillandsias-macos-tray/src/action_host.rs` `run_push_listener`
  (pattern inherited from order 155 slice 1, now repeated ×3 for the
  VmStatus/Login/Cloud primes); check windows-tray's slice 1
  (`run_vm_status_push_listener`, b6ca3290) for the same shape.

## Observation

Each initial-sync prime builds its envelope as:

```rust
let seq = client.allocate_seq();
let prime = ControlEnvelope {
    wire_version: WIRE_VERSION,
    seq: client.allocate_seq(),   // second allocation — envelope seq != body seq
    body: ControlMessage::VmStatusRequest { seq },
};
```

so the envelope `seq` and the body `seq` are different values and one number
is skipped per prime. Nothing matches on these seqs today (the reader loop
accepts replies alongside pushes without correlation), so this is harmless —
but it is a fragile assumption: any future reply-to-request correlation on the
push connection would silently mismatch.

## Smallest closing slice

Allocate once and reuse (`let seq = client.allocate_seq(); ... seq, body: ...
{ seq }`) in all three primes on both trays, pinned by whatever seq-equality
assertion the control-wire crate can host (or a simple source pin if not).
One-line-per-site mechanical change; suitable for any host touching these
files next.
