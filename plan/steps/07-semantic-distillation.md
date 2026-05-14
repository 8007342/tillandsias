# Step 07: Semantic Distillation and Tombstone Sweep

## Status

pending

## Objective

Finish the compaction pass: every stale spec is either tombstoned, obsolete, deprecated, or explicitly parked with a live owner.

## Inputs

- `plan/index.yaml`
- `methodology.yaml`
- `openspec/litmus-bindings.yaml`
- active specs with empty or weak bindings
- specs whose purpose is retrospective only

## Deliverables

- Updated statuses for stale specs.
- Replacement references for tombstones.
- A reduced frontier with no fake active coverage.

## Verification

- Repo-wide check for active specs without an intentional binding.
- Frontier scan after any tombstone wave.
- No resurrection of retired behavior.

## Handoff Rules

- If a spec is live but incomplete, keep it active and move it to the implementation backlog instead of calling it obsolete.

## Granular Tasks

- `distillation/spec-empty-bindings`
- `distillation/history-only-specs`
- `distillation/event-register`
- `distillation/frontier-prune`

## Handoff

- Assume the next agent may be different.
- The handoff should identify the current branch, file scope, checkpoint SHA, residual risk, and the dependency tail that remains.
- Repeating the same tombstone update should be idempotent.
