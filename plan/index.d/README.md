# Ledger fragments (`plan/index.d/`)

Append-only, immutable additions to `plan/index.yaml`. This directory is what
lets several hosts file work at the same time without a human resolving a merge.

## Why this exists

`methodology/distributed-work.yaml` → `crdt_principles.append_only_history` has
always required an append-only ledger folded by stable ID. The implementation was
one monolithic `plan/index.yaml` that every host edited in place — the exact
write-write conflict that rule forbids. Three concurrent filings collided in a
single session before this directory existed.

## How to add work

```bash
tillandsias-plan next-order      # mint a collision-free order token
```

Then write a NEW file — never edit an existing one:

```
plan/index.d/<utc>-<suffix>-<host>.yaml
```

```yaml
packets:                      # G-Set, keyed by packet_id
  - packet_id: my-new-packet
    order: 582-k3f9
    status: ready
    # ... the usual packet fields

events:                       # G-Set, keyed by (packet_id, event identity)
  - packet_id: some-existing-packet
    event:
      type: note
      ts: "2026-08-01T05:00:00Z"
      agent_id: my-agent-id
      summary: what happened

status:                       # LWW-Register, resolved by (ts, host)
  - packet_id: some-existing-packet
    field: status
    value: completed
    ts: "2026-08-01T05:00:00Z"
    host: linux-mutable
```

Only you could have produced that filename, so git has nothing to merge. The
packet is queryable immediately — reads fold fragments in automatically.

## Rules

- **Never edit a fragment after writing it.** Immutability is what makes the fold
  order-independent. To change something, write another fragment.
- **UTC first in the filename.** The fold sorts lexically, which is only
  chronological because of that ordering.
- **Events are a set, not a register.** Two hosts commenting on one packet keep
  both comments. Only `status` fields are last-writer-wins.

## Compaction

`tillandsias-plan fragments` reports drift; `tillandsias-plan compact` folds
fragments into the base and deletes exactly the ones it folded — never a glob,
because a fragment written mid-compaction has not been folded.

Compaction currently **refuses** on the real ledger, deliberately: `serde_yaml`
drops the ~120 comments in `plan/index.yaml` (including recorded operator
decisions) and re-indents items so `append-event` stops finding packets. An
uncompacted ledger is slower to read, never wrong, so nothing is blocked by the
refusal. See packet `format-preserving-ledger-compaction`.

Full reference: `cheatsheets/concurrent-git/crdt-ledger-fragments.md`
