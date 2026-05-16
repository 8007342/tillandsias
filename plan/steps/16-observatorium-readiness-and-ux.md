# Step 16: Observatorium Readiness and UX

## Objective

Make observatorium readiness mean the actual browser-visible page is available,
and surface logs or inspect data when it is not.

## Owned files or file scopes

- `crates/tillandsias-headless/src/main.rs`
- `scripts/run-observatorium.sh`
- `openspec/specs/clickable-trace-index/spec.md`
- `openspec/specs/cli-mode/spec.md`
- `plan/steps/16-observatorium-readiness-and-ux.md`

## Dependency tail

- Depends on the routing contract, port fallback chain, and tray network bootstrap.
- Should close the loop on the canonical observatorium success path.

## Current evidence

- The observatorium launcher still needs better diagnostics on readiness failure.
- The user-facing error path should be one actionable failure, not repeated churn.

## Next action

- Make readiness check the real page, not just container startup.
- Attach container logs and inspect data to failures.
- Keep the browser and tray UX aligned with the same canonical hostname.

## Checkpoint and push expectation

- Branch: `linux-next`
- Checkpoint: pending
- Push: after readiness failures are diagnosable from a single run.

## Handoff note

The next agent should preserve the canonical hostname while making failure
diagnostics useful enough to debug route versus container startup issues.

## Repeat-mode progress report shape

- Current phase: readiness and UX tightening
- Focus task: observatorium readiness probes and error reporting
- Blockers: none recorded
- Next action: validation gate updates

## Execution mode

- Use bounded repeat cycles for readiness probes.
- Refresh after each change to the failure path or browser target.
