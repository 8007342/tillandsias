# Step 12: Plan Ledger Refresh

## Objective

Make the plan system the durable execution ledger for the tray/router wave.
The bootstrap path should read `plan.yaml`, `plan/index.yaml`, `plan/steps/`,
and `plan/issues/` first so future agents can resume without chat history.

## Owned files or file scopes

- `methodology.yaml`
- `plan.yaml`
- `plan/index.yaml`
- `plan/steps/README.md`
- `plan/steps/12-plan-ledger-refresh.md`

## Dependency tail

- `plan/issues/` remains the blocker queue for ambiguities and residual drift.
- The tray/router wave depends on this file being cold-start readable.

## Current evidence

- `methodology.yaml` already names the plan root and step notes.
- `plan.yaml` still pointed at the older doc-debt continuation before this wave.
- `plan/index.yaml` did not yet have a dedicated tray/router step split.

## Next action

- Keep the plan ledger aligned with the new wave naming.
- Preserve idempotent step updates.
- Make sure the next agent can discover the routing work from the plan graph alone.

## Checkpoint and push expectation

- Branch: `linux-next`
- Checkpoint: pending
- Push: checkpoint and push after the ledger refresh batch is coherent.

## Handoff note

The next agent should treat the plan files as source material, not commentary.
The immediate goal is to keep routing and tray work discoverable from the graph
without needing a stale conversation context.

## Repeat-mode progress report shape

- Current phase: ledger refresh
- Focus task: plan/index and methodology alignment
- Blockers: none recorded
- Next action: route split step file updates

## Execution mode

- Use bounded repeat cycles if the ledger still drifts after the next patch.
- Refresh the same task note after each meaningful substep.
