# Low-end tier has no drain path: its only linux row is dep-blocked on general-queue work

- **Date**: 2026-09-13
- **Order**: (observation, no new packet)
- **Host**: forge (forge-tillandsias, 4c/4t)
- **Classification**: research
- **Reference**: `1005-5yvy` (spec-index-delta-reuses-nothing-and-starves-the-floor)

## Observation

This forge reports 4 physical cores, so the tier gate (847-wgy4,
`scripts/select-work-batch.sh`) routes it to `low-end`-tagged work only and
refused the general queue loudly:

```
refused:no-tier-work:this is a low-end host (tier gate, 847-wgy4) and no ready
packet tagged [low-end] is claimable by role linux — the mandate forbids the
general queue; file or free tier work rather than draining generally
```

The refusal is CORRECT rather than a probe misread (`nproc` = 4, 1 thread/core).
But it exposes a structural gap in the tier pool:

- The ONLY ready `low-end`-tagged packet claimable by role `linux` is
  **1005-5yvy** (`spec-index-delta-reuses-nothing-and-starves-the-floor`).
- 1005-5yvy `depends_on: [local-expert-system-in-toolboxes-on-accelerated-hosts]`
  = **917-6iwv**, which is `ready`, pickup_role `linux`, priority p1 — but with
  capability_tags `experts/rag/gpu/npu/toolbox/convergence` (NO `low-end` tag).
- `select-rows --status ready --claimable-by linux --tag low-end` therefore
  returns ZERO rows: 1005-5yvy is filtered out by the unsatisfied dependency.

So the low-end tier's drain pool is empty by construction: the tier's only linux
work is gated behind a general-queue packet that a low-end host is forbidden to
claim, and the general queue is exactly what this forge was told not to touch.
The one other low-end row (`1004-4xie`) is pickup_role `windows`, so it never
serves a linux low-end host.

## Consequence

A 4-core forge/host running `/meta-orchestration` (or `/advance-work-from-plan`)
has no claimable work and must spend its whole cycle on maintenance/reduction
duties — which is what this cycle did (ledger compaction of 320 fragments +
freshness audit). That is a legitimate outcome, but it is SILENT: nothing in the
selector output told a reader that the tier pool is structurally empty, only
that it is currently empty.

## Suggested follow-up (Tlatoāni / coordinator decision, NOT a bar-raise)

Three ways to give the floor tier a drain path, in rough order of preference:

1. Make the spec-index slice independently schedulable: split 1005-5yvy so the
   measured-index-on-a-floor-host rung does not depend on 917-6iwv.
2. Tag 917-6iwv (or the slice of it that is pure tooling, not accelerator-bound)
   `low-end`, so a floor host can claim it directly.
3. Accept the empty tier explicitly and say so in the selector refusal text
   (mention "tier pool is empty AND its only linux row is dep-blocked on
   <order>"), so the next low-end cycle is not surprised.

Recorded as an event on 1005-5yvy. No new packet filed: promotion of a pattern
needs more than one observation, and this is a coordination gap, not a defect
in an owned file.