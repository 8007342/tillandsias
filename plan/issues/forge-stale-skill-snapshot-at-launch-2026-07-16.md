# Forge sessions run on skill/runbook text baked before the start-of-cycle sync

- Date: 2026-07-16
- Class: enhancement
- Found on: forge (chaparrita), meta-orchestration cycle 2026-07-16T17:26Z
- Status: open

## Observation

A forge launched from a provisioned image starts with a checkout that can be
days stale. The harness loads skill text (`/meta-orchestration`,
`/advance-work-from-plan`) at invocation — BEFORE the skill's own step 4
fast-forwards the checkout. This cycle the baked tree was 516 commits behind:
the loaded meta-orchestration text still carried the greedy forge drain note
("drain as many ready forge tasks as possible"), which order 264
(`methodology/distributed-work.yaml` -> `forge_cycle_budget`, 2026-07-10) had
superseded five days earlier, and which the post-sync canonical SKILL.md had
already corrected. An agent trusting its loaded skill text would have violated
the one-packet forge budget for the whole cycle.

## Mitigation that worked (and should be codified)

After the start-of-cycle fetch/fast-forward, re-read the canonical
methodology/skill files from the UPDATED tree before making budget/priority
decisions; on conflict, methodology.yaml wins (its authority rule already says
so). This cycle caught the drift by consulting
`methodology/distributed-work.yaml` post-sync.

## Smallest Next Action

Add one line to skills/meta-orchestration/SKILL.md "Start Of Cycle" (and
mirror it in advance-work-from-plan §1): "If the fast-forward moved HEAD,
re-read this skill and its cited methodology sections from the updated tree
before continuing; the loaded snapshot may predate the sync."

## Verifiable Closure

- The Start Of Cycle section contains the re-read instruction (grep-pinnable:
  `re-read this skill` in skills/meta-orchestration/SKILL.md).
- Optional deeper fix (bar-raise candidate, Tlatoāni-gated): the launcher
  refreshes the checkout before the first skill load, making the snapshot
  race structurally impossible.
