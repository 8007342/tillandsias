# The compaction "zero removed lines" invariant is a proxy, and it fails on a correct fold

- **Measured:** yolanda, 2026-08-26, folding 79 fragments
- **Filed here rather than as a packet:** this is a wording correction to a skill
  section that is otherwise right, and the cheapest fix is a text change by
  whoever owns `skills/meta-orchestration/SKILL.md`.
- **Originally appended to `582-4wdi`, which is ARCHIVED** (`plan/archive/packets-2026-08.yaml:3132`),
  so the event orphaned. See the last section — that is its own finding.

## What the skill says

> the `plan/index.yaml` diff was 1021 added lines and **zero removed lines**.
> That zero is the property to protect — existing base bytes are untouched by
> construction.

and, on seeing it violated:

> If compaction ever regresses to round-tripping YAML, restore the refusal
> rather than accepting a lossy fold.

## What actually happened

```
tillandsias-plan compact   ->  ok: compacted 79 fragment(s) (79 removed)
git diff --numstat plan/index.yaml   ->  added=2851  removed=2
```

**`removed=2`, against an invariant that says zero.** Followed literally, the
instruction is to treat this as a lossy-round-trip regression and restore a
refusal that blocked compaction for months.

It is not a regression. The two lines were:

```
-      status: ready        (635-bhkb)
+      status: done
-      status: ready        (804-ckst)
+      status: done
```

Two `set-field` transitions being **materialized into the base** — which is
exactly what folding a field update must do. A status change necessarily
replaces a line.

**The 2026-08-03 run got zero because it folded append-only events**, which add
lines and replace none. That zero was circumstance, not construction — and the
skill states it as construction.

## The invariants that actually distinguish a correct fold from a lossy one

Verified on this fold instead of the line count:

| property | before | after | why it matters |
| --- | --- | --- | --- |
| comment lines | 38 | **40** | the `serde_yaml` round-trip drops comments — this is the real thing the refusal protected |
| `packet_id` count | 542 | **561** | 19 folded in, none lost |
| four-space item prefix | — | intact on all 561 | `append-event` locates packets by it; a re-indent to column 0 silently breaks future appends |
| non-status removed lines | — | **0** | the only replacements were field updates |

`tillandsias-plan check` after: `ok: 633 packets, ids unique, live references sound`.

**Suggested wording change:** keep the 2026-08-03 numbers as an illustration of
that run, and make the *test* the three properties above. A line-delta count
cannot tell "a status was folded" from "the base was re-serialized", and it fails
in the direction that blocks correct work.

## A second finding, hit while filing the first

The note above was originally appended to `582-4wdi`. That packet has been
**archived**, so `append-event` accepted the reference, wrote a fragment, and
produced an event attached to nothing. The gate caught it:

```
blocked:fragment-events-land:1 event(s) attached to no packet
  an event for `format-preserving-ledger-compaction` — NO SUCH PACKET
```

**This is a live instance of `896-f8ti`** (*append-event accepts a ref that
resolves to no packet*), which is currently one of two stranded `in_progress`
rows. Worth noting for whoever picks it up: the failure is not only a typo'd id,
as that packet's title suggests. **An id that was valid when the author last read
the ledger, and archived since, produces the identical outcome** — and that is
the more likely path, because the archiver runs on a schedule and moved 801
packets in this cycle alone. A host citing a packet it worked with days ago is
the expected caller, not a careless one.

The gate caught it before it could be pushed, which is the guard working. But
`append-event` accepted it at write time, and the author's only signal was a red
gate several steps later.
