# The Start-Of-Day gate told me to publish a capability row, and `./build.sh --check` then refused it

Classification: **enhancement/**
Filed: 2026-09-02 · Host: lenovinha (linux_immutable, linux-next)
Found during: the daily maintenance gate, order 793-qr4t cycle

## What happened

`scripts/check-capability-row.sh` reported `stale:capability-row-drifted`, so I
published a fresh row exactly as the meta-orchestration skill instructs, with
the generator it names:

```
bash scripts/host-capability-probe.sh --fragment > plan/index.d/<ts>-capability-row-<host>.yaml
```

The local gate then failed:

```
plan/index.d/20260902t210230z-capability-row-lenovinha.yaml
  top-level key 'capabilities' is NOT read by the fold — this fragment's
  contents will be silently discarded at the next compaction.
violation:fragment-keys:1 unread key(s)
```

Order 850-bif2 requires a host to publish its row **before it drains work**, so
this sits directly across the joining path: every host that follows the
instruction hits the refusal, and the row and the guard both shipped believing
they were right.

## Why both guards were right about the world and wrong about each other

`check-fragment-keys-are-read.sh` (944-vim8) refuses a fragment whose top-level
key the fold does not read, because four packets filed under `steps:` were
folded away silently — they passed YAML validation, passed `plan check`, read
correctly to a human, and vanished.

But `capabilities:` is not that. Compaction refuses to fold it **deliberately**
(843-624y), because the channel has no base representation yet (846-idhn tracks
giving it one), and the generator's own header comment says so. The row has a
consumer: `check-capability-row.sh` and the fleet matrix read it straight out of
the fragment.

So the two guards were not disagreeing about a fact. They were using one test —
"does the fold read this key" — to answer two different questions: *will the
fold look at it* and *will anything look at it*. Those coincide for `steps:` and
come apart here.

## What I did

Added `NON_FOLD_CHANNELS=" capabilities "` to the guard, separate from
`READ_KEYS` rather than merged into it — `litmus:fragment-keys-are-read` asserts
`READ_KEYS` matches the channels named in `crates/tillandsias-plan/src/fragments.rs`,
and widening it would have made that assertion false to buy silence. Adding to
the new list is a claim someone can check: name the consumer.

## Residual

When 846-idhn gives capability rows a base representation, `capabilities` moves
out of `NON_FOLD_CHANNELS` and into `READ_KEYS`, and this file can be deleted
along with the special case.

The broader question is worth someone's judgement and I did not settle it: the
guard's message asserts contents "will be silently discarded", which is now
false for one of the keys it inspects. A guard whose explanation is wrong for a
case it permits is a smaller version of the same problem, and the honest fix may
be for the fold to own the list of channels-with-consumers rather than for a
shell script to keep a second one.
