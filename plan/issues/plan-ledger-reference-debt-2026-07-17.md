# Plan ledger reference + status debt (surfaced by the compiled engine, 2026-07-17)

- **Type**: optimization (ledger hygiene; found the moment the compiled
  engine first ran the invariant core over the real ledger)
- **Filed by**: linux-tlatoani-claude-20260717T0355Z
- **Owner**: any (ledger hygiene) — safe, mechanical, non-churning

## What the engine found

`tillandsias-plan check` (order 398) separates a hard-gating INVARIANT
CORE from advisory debt. The core (id uniqueness + live references
resolving against active∪archive) PASSES on the live ledger — good. The
advisory buckets it surfaced, for deliberate cleanup (never auto-churn):

### Reference warnings (organic annotation debt)
- Several `split_into` values are PROSE, not ids
  (e.g. `"227 — container-dependency-graph-satisfier-typestate (slice
  3: …)"`). They predate the id-grammar discipline. Cleanup: replace
  with the real child packet_ids (or drop split_into where the children
  already carry the parent as depends_on).
- A handful of retired (done/failed) packets carry depends_on pointing
  at packets that were neither archived nor renamed — historical, inert.

### Schema drift (advisory — the schema is evolving DATA)
- `git-mirror-pre-reconcile-research`: status `completed` → should be
  `done` (canonical).
- `windows-inforge-meta-orchestration-transparent-push`: status
  `in_progress` → not a canonical status; likely `claimed` or `ready`.

## Why this is not a blocker

Referential SOUNDNESS holds (archived-dependency resolution added this
session — a depends_on on completed+archived research is a satisfied
dependency, not a dangling ref). The above are naming/annotation drift
that the tool now makes VISIBLE every run. They convert to zero the day
order 398's slice-2 edit surface lands (validated status flips + a
split_into normalizer), or via a one-pass hygiene sweep before then.

## Verifiable closure
- `tillandsias-plan check` emits zero `warning:`/`advisory:` lines.
- The plan-engine litmus's warning-count assertion (once slice 2 can
  normalize) flips to expecting zero.
