# plan/index.yaml: depends_on uses bare order number instead of packet_id

**Filed**: 2026-07-23T02:10Z
**Host**: forge (TILLANDSIAS_HOST_KIND=forge)
**Classification**: enhancement
**Status**: fixed (same commit)
**Order**: n/a (routine finding)

## Symptom

`cargo test -p tillandsias-plan --lib` fails:

```
a well-formed append must pass the flush guard:
["authenticated-forge-write-transport-impl: depends_on -> unresolved reference '322'"]
```

Two tests fail: `append_event_inserts_and_flush_guard_accepts` and
`live_ledger_reference_integrity_holds`.

## Root cause

`authenticated-forge-write-transport-impl` (order 451) declares
`depends_on: ["322"]`. The plan validator's `reference_resolves` function only
checks `by_id` (packet_id map), not `by_order` (order number map). The string
`"322"` doesn't match any packet_id — the actual packet is
`mirror-authenticated-push-transport` (order 322).

The `resolve()` function CAN resolve by order number, but `reference_resolves()`
doesn't use it — it only checks `by_id.contains_key()`.

## Fix

Changed `depends_on: ["322"]` to `depends_on: [mirror-authenticated-push-transport]`
in `plan/index.yaml` line 20061.

## Verification

- `cargo test -p tillandsias-plan --lib` → 8/8 pass
- `cargo test --workspace` → all pass
- `./build.sh --check` → clean
