---
tags: [crdt, concurrency, ledger, append-only, compaction, merge, distributed]
languages: [yaml, rust, bash]
since: 2026-08-01
last_verified: 2026-08-03
sources:
  - methodology/distributed-work.yaml
  - https://inria.hal.science/inria-00555588/document
  - https://jzhao.xyz/thoughts/crdt
  - plan/issues/work-order-id-collision-free-design-2026-08-01.md
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---
# Concurrent Git — CRDT Ledger Fragments

@trace methodology/distributed-work.yaml
@cheatsheet concurrent-git/plan-discipline.md

**Use when**: several hosts or agents must write to the same ledger
(`plan/index.yaml`, `plan/loop_status.md`) concurrently, and you want their
writes to merge without a human adjudicating a conflict.

## Provenance

- `methodology/distributed-work.yaml` → `crdt_principles` — the doctrine this
  implements. It already required append-only history and a keyed fold; the
  monolithic index file was simply never built that way.
- Shapiro, Preguiça, Baquero, Zawirski, *A Comprehensive Study of Convergent and
  Commutative Replicated Data Types* (INRIA RR-7506) — the canonical taxonomy.
- **Last updated:** 2026-08-03

## Why this class of problem is already solved

Two hosts editing one YAML file conflict because a text merge cannot know that
"append packet A" and "append packet B" are independent. The fix is not a better
merge tool — it is choosing a data type whose operations *commute*, so there is
nothing to adjudicate. That is what a CRDT is: a structure whose concurrent
updates converge to the same state regardless of the order they arrive in.

Do not invent a scheme. Pick the right primitive per field.

## The three primitives you actually need

| What you are writing | CRDT | Why it converges |
|---|---|---|
| A new work packet | **G-Set** (grow-only set), keyed by `packet_id` | Union is commutative, associative, idempotent. Two hosts adding different packets → both present. Adding the same packet twice → present once. |
| An event on an existing packet | **G-Set of events**, keyed by `(packet_id, event identity)` | Same. Events are immutable facts; you never edit one, you add another. |
| A status / progress field | **LWW-Register** (last-writer-wins) | Only one value can survive, so pick deterministically: highest `(timestamp, host)` wins. |

Deletion is the trap. A grow-only set has no remove, and "just delete it" breaks
convergence — a host that never saw the delete will re-add the element on its next
merge. Use a **tombstone**: an entry that says "this id is retired", which is
itself an addition and therefore commutes.

## The shape that makes it work in git

```
plan/
  index.yaml            # the COMPACTED base — rewritten only by compaction
  index.d/              # fragments — append-only, immutable once written
    20260801T0342Z-h99t-linux-mutable.yaml
    20260801T0344Z-jf7g-osx.yaml
  loop_status.md        # the COMPACTED status base — rewritten only by compaction
  loop_status.d/        # status fragments — one file per host per cycle
    20260803T011000Z-aa11-linux-mutable.md
    20260803T011100Z-bb22-windows-mutable.md
```

Two properties do all the work:

1. **One writer per file.** A host writes a NEW file with a name it alone could
   have produced (timestamp + random suffix + host). Git never conflicts, because
   two hosts never touch the same path.
2. **Fragments are immutable.** Nobody edits a fragment after writing it. That is
   what makes the fold order-independent, and it is the property to protect when
   someone later proposes "just tweak that entry".

Reading is `base ⊕ fold(fragments)`. Callers should never know fragments exist.

## Rules that keep the fold deterministic

- **Sort fragments by `(timestamp, filename)` before folding.** Directory order is
  filesystem-dependent; two hosts must fold identically.
- **The fold must be idempotent.** Folding a fragment already merged into the base
  must be a no-op — otherwise a partially-completed compaction duplicates events.
  Give every event a stable identity (content hash, or `(packet_id, ts, agent,
  type)`) and dedup on it.
- **Timestamps are for tie-breaking, not truth.** Host clocks disagree and git
  history is a partial order until branches merge. A timestamp-major, host-minor
  ordering is deterministic — that is all it needs to be. Never build anything
  requiring a strict global total order on top of it.

## Compaction is garbage collection, and it races

Fragments accumulate; periodically fold them into the base and delete them.
Triggers are a matter of taste (file count, total bytes, age) — the correctness
rules are not:

- **Delete exactly the fragments you folded, by name.** Never `rm index.d/*`. A
  fragment written by another host while you were compacting has not been folded,
  and globbing it away silently loses work. This is the classic GC-versus-writer
  race and it is the single most likely way to lose data here.
- **Compaction must be a pure function.** Any host compacting the same inputs must
  produce the same base, or hosts will fight over the result.
- **Compaction is optional.** If it never runs, the ledger is slower but still
  correct. Never let compaction be on the critical path of filing work.
- **Validate before replacing the base.** A compaction that emits a malformed base
  is worse than no compaction; parse and integrity-check the candidate first.

## Failure modes worth naming

- **A reader that forgets fragments** reports a stale ledger with total confidence.
  Every read path — CLI, MCP server, expert retrieval — must go through the same
  overlay, or they will disagree with each other.
- **Sorting by filesystem order** makes two hosts compute different states from
  identical inputs, which looks like data corruption.
- **Last-writer-wins on a field that is not a register.** Applying LWW to a *list*
  silently discards the loser's entries. Lists want G-Sets.
- **Editing a fragment** breaks immutability and therefore convergence, usually
  long after the edit, in a way that is very hard to trace.

## Prose: the same overlay on `plan/loop_status.md`

`loop_status.md` conflicts under concurrency for the same reason `index.yaml`
did, but it is PROSE, not keyed records — there is no `packet_id` to key a
G-Set on. Do not force the index design onto it unexamined; choose the CRDT per
section (packet `loop-status-crdt-fragments`, 582-nqw5):

| section                                   | CRDT |
|-------------------------------------------|------|
| `## Cycle <ts> (<host> — …)`              | **G-Set keyed by the heading line** — the heading embeds timestamp+host, so it *is* the stable identity. Union keeps both hosts' narratives. |
| `## Direction`                            | **LWW-Register, operator-writes-only.** An agent fragment that names it is refused. |
| `## ACTIVE RELEASE`                       | **LWW-Register, operator/coordinator-writes-only.** Same refusal. |
| everything else (`## This Loop`, `## WINDOWS LANE`, …) | **base-only** — fragments never carry it. |

The rendered file is a fold: base text plus every fragment's `## Cycle`
sections, inserted newest-first right after the title, deduplicated by heading
(G-Set). An agent writes status by appending its own
`plan/loop_status.d/<utc>-<suffix>-<host>.md` via `loop-status-append`, so two
hosts recording a cycle never touch the same path. Reading is
`tillandsias-plan loop-status` (the fold view — never read `loop_status.md`
directly), compaction is `loop-status-compact`, gated on: nothing dropped,
nothing lost, the operator-owned sections byte-identical, and the fold
idempotent.

## See also

- `concurrent-git/plan-discipline.md` — the three iron rules for writing under `plan/`
- `concurrent-git/agent-handoff.md` — claiming and leases (a lease is a TTL, not a lock)
