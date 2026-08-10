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
    field: status              # ANY field — the channel is misnamed, see below
    value: completed
    ts: "2026-08-01T05:00:00Z"
    host: linux-mutable
```

## Changing a field: use the tool, do not hand-author

```bash
tillandsias-plan set-field <id|order> <field> <value> --reason "why"
```

Hand-authoring the `status:` channel is possible and it is how three hosts got
it wrong on 2026-08-09, independently, within hours of each other:

| host | what it wrote | what happened |
|---|---|---|
| linux | re-declared the packet under `packets:` with a new status | G-Set no-op. **11 of 21 completions silently discarded**, some for two days (635-i6vm) |
| macOS | `type: completed` under `events:`, no `status:` block | packet passed 5/5 with an evidence file and stayed claimable |
| windows | filed 642-fedr | the channel is *named* `status:` but corrects **any** field, so nobody looks here when changing `pickup_role` |

Every one of those parses, validates, passes `tillandsias-plan check`, and reads
correctly in review. The fold discards the change and nothing reports that it
did. That is why the tool exists (636-9m79): it removes the choice rather than
policing it.

`set-field` also resolves against the **folded** ledger, so it reaches
fragment-only packets. `append-event` cannot — it locates packets by their item
prefix in `plan/index.yaml` and is blind to anything that lives only in a
fragment (600-c266). That blindness is why agents started hand-authoring these
fragments in the first place.

Only you could have produced that filename, so git has nothing to merge. The
packet is queryable immediately — reads fold fragments in automatically.

## Rules

- **Never edit a fragment after writing it.** Immutability is what makes the fold
  order-independent. To change something, write another fragment.
- **UTC first in the filename.** The fold sorts lexically, which is only
  chronological because of that ordering.
- **Events are a set, not a register.** Two hosts commenting on one packet keep
  both comments. Only `status` fields are last-writer-wins.
- **Never hand-author the `status:` channel.** Use `tillandsias-plan set-field`.
  Re-declaring a packet under `packets:` to change it is a G-Set no-op that looks
  exactly like success — see the table above.
- **The `status:` channel is field-generic despite its name.** It corrects
  `pickup_role`, `priority`, `desired_release` — anything. Renaming it is tracked
  by 642-fedr.

## Compaction

`tillandsias-plan fragments` reports drift; `tillandsias-plan compact` folds
fragments into the base and deletes exactly the ones it folded — never a glob,
because a fragment written mid-compaction has not been folded.

Compaction is TEXT-LEVEL and format-preserving (packet
`format-preserving-ledger-compaction`): the base is never re-serialized, so its
~120 comment lines and the item indentation `append-event` locates survive BY
CONSTRUCTION, and the candidate is gated with parse + integrity before it may
replace the base.

Full reference: `cheatsheets/concurrent-git/crdt-ledger-fragments.md`
