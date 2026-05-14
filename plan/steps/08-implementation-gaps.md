# Step 08: Remaining Implementation Gaps After Spec Cleanup

## Status

pending

## Objective

Once the spec surface is clean, convert the remaining active specs into concrete implementation work.

## Deliverables

- A backlog of actual code gaps, ordered by impact and dependency.
- One actionable step per gap with a reproducible verification chain.
- No stale-spec cleanup tasks mixed into this phase.

## How to Use

- Only start this step after the distillation sweep is complete.
- Re-read `methodology.yaml` and the active spec bundle before selecting the next patch.
- Keep each hourly run bounded to one gap or one small cluster of gaps.

## Verification

- Each gap ends in a code or test change, not a spec tombstone.
- The next prompt should point to the specific gap still open.

## Granular Tasks

- `implementation-gaps/residual-backlog`

## Handoff

- Assume the next agent may be different.
- Notes should be cold-start readable and idempotent: current branch, file scope, checkpoint SHA, residual risk, dependency tail.
