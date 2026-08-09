# `append-event` bypasses the folded fragment ledger

Date: 2026-08-06 (America/Los_Angeles)
Status: implementation handoff
Plan: `plan-append-event-blind-to-fragment-packets` (order 600-c266)
Release: v0.5

## Reproduced behavior

The current binary resolves a packet created only in `plan/index.d/` through
the folded read path:

```text
$ tillandsias-plan status plan-append-event-blind-to-fragment-packets
600-c266 ready plan-append-event-blind-to-fragment-packets
```

The write command rejects that same packet:

```text
$ tillandsias-plan append-event plan-append-event-blind-to-fragment-packets note probe --ts 2026-08-06T00:00:00Z
error: packet_id 'plan-append-event-blind-to-fragment-packets' not found
```

No event was written during this reproduction.

## Root cause

`crates/tillandsias-plan/src/main.rs` first resolves the reference with the
fragment-aware `Ledger::load_with_fragments` result. It then re-reads only the
base `plan/index.yaml` text and passes the resolved packet id to
`edit::append_event`. A fragment-born packet cannot occur in that base text, so
the text editor returns `packet_id ... not found`.

The same branch mutates the compacted base for base-born packets. That is also
inconsistent with `methodology/distributed-work.yaml` and
`plan/index.d/README.md`, which define events as an append-only G-Set written as
new fragments and reserve base mutation for guarded compaction.

## Implementation handoff

Replace the base-text candidate/write branch with creation of a new event-only
fragment:

- keep reference resolution against the folded ledger;
- serialize `events: [{packet_id, event: {type, ts, agent_id, host, summary}}]`;
- reuse `fragments::fragment_doc`, `fragment_dir`, and `fragment_name` plus the
  UTC helpers already used by the loop-status fragment writer;
- create the destination exclusively and retry with a fresh suffix on a name
  collision, so an existing fragment can never be overwritten;
- validate the serialized fragment and a candidate folded ledger before
  publishing it;
- leave `plan/index.yaml` and every pre-existing fragment byte-identical;
- report the created fragment path in the success output.

Do not reuse `edit::event_block` as the storage transport; its indentation is
specific to the monolithic base format. Packet 606-e2hg currently owns
`crates/tillandsias-plan/src/main.rs`, so implementation of 600-c266 must wait
until that lease releases the file or coordinate an explicit handoff.

## Regression contract

Use a temporary base plus a fragment-born packet and invoke the real
`append-event` handler by both packet id and order. Assert that:

1. both calls succeed without compaction;
2. the base and original packet fragment remain byte-identical;
3. each call creates exactly one new event fragment containing every supplied
   field;
4. a fresh `Ledger::load_with_fragments` immediately exposes each event;
5. a base-born packet follows the same append-only path; and
6. a pre-created filename is never overwritten (exclusive-create retry or a
   bounded refusal).

The existing `fragment_only_packet_accepts_lifecycle_updates_and_events` unit
test proves that hand-authored fragments fold. It does not exercise the CLI
writer and therefore did not catch this split read/write path.
