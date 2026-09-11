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

fields:                       # LWW-Register, resolved by (ts, host)
  - packet_id: some-existing-packet
    field: status              # ANY field name goes here — see below
    value: completed
    ts: "2026-08-01T05:00:00Z"
    host: linux-mutable

  # A NON-STATUS correction, which is the case the old wording denied existed:
  - packet_id: some-existing-packet
    field: pickup_role         # not a status field, and equally correctable
    value: windows
    ts: "2026-08-01T05:01:00Z"
    host: linux-mutable
```

`status:` is an accepted ALIAS for `fields:` and folds identically (642-fedr).
Every fragment already on disk keeps working; `set-field` still emits `status:`
today, and the writer flips only once every host carries a reader that accepts
both. A writer that moved first would leave an older host silently not seeing
corrections.

**Two different keys are spelled `status`, at different indents, and conflating
them is the trap:**

```yaml
status:                  # column 0 — the LWW CHANNEL (alias of fields:)
  - packet_id: p
    field: status        # the NAME of the field being corrected
    value: ready

packets:
  - packet_id: p
    status: ready        # 4 spaces — a packet DECLARATION field
```

Any reader that greps `status:` unanchored will conflate the channel with the
declaration. Anchor to the indent.

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

## Repairing a fragment: write a correction, never edit it

A fragment is append-only and **immutable once written**. That applies to
repairing one too, and this is the case that actually goes wrong, because a
fragment *looks* editable in a way the base does not — it is small, you probably
wrote it, and the repair is usually one missing key.

**A fragment repair is a NEW correction fragment** declaring the same
`packet_id` with the corrected field. Never an amendment to the fragment already
written, and never by a second party under any circumstances.

```yaml
# plan/index.d/<utc>-<suffix>-<host>.yaml   <- a NEW file
packets:
  - packet_id: the-packet-being-repaired   # same id; that is what folds them
    order: 1071-adhj
    unscoreable: |
      The field that was missing, supplied here rather than added in place.
```

Corrections compose under the G-Set union. Two in-place amendments of an
append-only file do not.

### The collision that made this a rule

On 2026-09-05 the coordinator amended two fragments on trunk to add missing
scorable blocks. Another host amended the same two files locally, having checked
`origin/linux-next` first and found the repair absent. The next merge combined
both edits **additively**, so each file ended with two `unscoreable:` keys — a
duplicate mapping key, which is not valid YAML:

```
blocked:all-fragments-intact:2 damaged
blocked:fragment-events-land:3 event(s) attached to no packet
```

The second was a consequence of the first: an unparseable fragment contributes
no packet, so its own events orphan.

**Neither host was careless, which is why this is a rule and not advice.** Both
checked before editing. What failed was the safeguard: both consulted trunk to
see whether the other's repair had landed, and trunk is hours stale for a
platform host — measured relay gaps of 19 minutes to 2 hours 2 minutes
(`1034-whsp`). A check that cannot see in-flight work is not a check, so an
in-place amendment by a second party is a race neither party can observe.

`check-all-fragments-intact` already states the consequence in its own refusal:
damage here is *not a merge to resolve but a file to restore from its authoring
commit*.

### If a gate tells you to edit in place, the gate is wrong

`check-scorable-obligation-added.sh` used to judge one fragment's bytes alone, so
a declaration whose obligation arrived in a correction fragment was still
refused — and the only way through was the in-place edit this section forbids.
The two rules contradicted each other. It now asks whether the packet **as
folded** carries an obligation (`1071-adhj`).

Say so rather than editing. Canonical rule:
`methodology/distributed-work.yaml` →
`distributed_work.crdt_principles.invariants.append_only_history.implementation.fragment_repair_is_a_correction_fragment`.

## Rules

- **Never edit a fragment after writing it.** Immutability is what makes the fold
  order-independent. To change something, write another fragment.
- **UTC first in the filename.** The fold sorts lexically, which is only
  chronological because of that ordering.
- **The `fields:` channel is last-writer-wins per `(packet_id, field)`; events
  are a set.** Two hosts commenting on one packet keep both comments. Two hosts
  correcting the SAME field of the same packet resolve to one value by
  `(ts, host)`. This applies to ANY field — `pickup_role`, `priority`,
  `depends_on`, `title` — not only `status`.

  This sentence used to read "Only `status` fields are last-writer-wins", which
  reads as *only the status field*. Combined with the never-edit-the-base rule
  below, that said a mis-filed `pickup_role` or `depends_on` could never be
  corrected at all — and a cycle came one step from filing that as a structural
  defect of the ledger (642-fedr). The register was always field-generic; only
  the prose and the channel name were wrong.
- **Never hand-author the `fields:`/`status:` channel.** Use `tillandsias-plan set-field`.
  Re-declaring a packet under `packets:` to change it is a G-Set no-op that looks
  exactly like success — see the table above.
- **`status:` is an accepted alias for `fields:`.** Both fold identically —
  same LWW key `(packet_id, field)`, same closure lattice, same order
  independence — so no fragment needs rewriting and none ever will (642-fedr).
- **Never edit `plan/index.yaml` directly.** The base is a concurrency block
  with exactly one writer: compaction (627-c9c2, canonical statement in
  `methodology/distributed-work.yaml` → `concurrency_block`). A direct edit is
  a write-write conflict with every concurrent host, and a commit touching the
  base cannot pass the enclave mirror's YAML gate at all (next rule).
- **Quote every timestamp-shaped scalar** (`ts: "2026-…Z"`, and any value that
  starts like a date). The enclave mirror's pre-receive hook validates YAML with
  ruby + Psych 5 safe_load (YAML 1.1): a bare timestamp builds a `Time` object
  and the push is refused with `Psych::DisallowedClass` (627-c9c2, learned from
  a twice-rejected forge push 2026-08-09). `tillandsias-plan`'s writers quote
  these for you — one more reason not to hand-author.

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
