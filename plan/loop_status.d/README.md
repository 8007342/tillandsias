# Loop-status fragments (`plan/loop_status.d/`)

Append-only, immutable additions to `plan/loop_status.md`. This directory is
what lets several hosts record their cycle status at the same time without a
human resolving a merge — the same fix as `plan/index.d/`, applied to the one
narrative file every host rewrites.

## Why this exists

`plan/loop_status.md` is prose, not keyed records, so the index overlay's
packet_id key does not exist here. The CRDT is therefore chosen per section
(packet `loop-status-crdt-fragments`, 582-nqw5):

| section                                  | CRDT                                |
|------------------------------------------|-------------------------------------|
| `## Cycle <ts> (<host> — …)` entries     | **G-SET keyed by the heading line** — an entry is an immutable dated, host-scoped fact; the heading embeds timestamp+host, so it is the stable identity. Union of two hosts' appends keeps BOTH narratives. |
| `## Direction`                           | **LWW-REGISTER, operator-writes-only** — agents may never write it. |
| `## ACTIVE RELEASE`                      | **LWW-REGISTER, operator/coordinator-writes-only**. |
| everything else (`## This Loop`, `## WINDOWS LANE`, …) | **base-only** — fragments never carry it. |

The rendered `loop_status.md` is a **fold**: the base text plus every
fragment's `## Cycle` sections, inserted newest-first right after the title.

## How to add a cycle entry

```bash
tillandsias-plan loop-status-append --ts <ISO> --host <host> <<'EOF'
## Cycle 2026-08-03T01:10Z (linux_mutable — what happened)

- **Host**: ...
- **Packet X DONE** (...): ...
EOF
```

or write a NEW file by hand — never edit an existing one:

```
plan/loop_status.d/<utc>-<suffix>-<host>.md
```

A fragment may carry a leading `#`-comment header (same convention as
`plan/index.d/`) and any number of `## Cycle` sections — and NOTHING else. A
fragment naming `## Direction`, `## ACTIVE RELEASE`, or any other heading is
**refused**: it cannot be appended, and if it is written by hand it is treated
as malformed and never folded in.

Each host writes its own path, so two hosts appending status concurrently
produce two files and no git conflict — the concurrent write that used to
collide on the shared base no longer touches the same path.

## Rules

- **Never edit a fragment after writing it.** Immutability is what makes the
  fold order-independent. To change something, write another fragment.
- **UTC first in the filename.** The fold sorts lexically, which is only
  chronological because of that ordering.
- **Cycle entries are a set, not a register.** Two hosts recording the same
  moment keep both narratives. Only the operator-owned sections are
  single-valued, and they are not yours to write.
- **`## Direction` and `## ACTIVE RELEASE` are operator-owned.** An agent
  write that tries to reach them is refused at append time and skipped as
  malformed at fold time; compaction additionally verifies they are
  byte-identical between base and candidate.

## Reading and compaction

- `tillandsias-plan loop-status` — the folded view. The only correct way to
  read loop_status: a reader that forgets fragments reports a stale status
  with total confidence.
- `tillandsias-plan loop-status-fragments` — drift report (compaction
  eligibility).
- `tillandsias-plan loop-status-compact` — folds fragments into the base and
  deletes exactly the ones it folded — never a glob, because a fragment
  written mid-compaction has not been folded. Refuses unless nothing is
  dropped, nothing is lost, the operator-owned sections are byte-identical,
  and the fold is idempotent.

Full reference: `cheatsheets/concurrent-git/crdt-ledger-fragments.md`
