# Step 14: User Runtime Port Selection

## Objective

Implement the user-runtime host port policy: try `80`, then `8080`, then an
explicit `--port` escape hatch if both are unavailable.

## Owned files or file scopes

- `crates/tillandsias-headless/src/main.rs`
- `scripts/run-observatorium.sh`
- `plan/steps/14-user-runtime-port-selection.md`

## Dependency tail

- Depends on the router/observatorium routing contract being named clearly.
- The tray and observatorium launch paths should share the same fallback story.

## Current evidence

- The headless launcher still has fixed-port assumptions in the router path.
- The observatorium launcher still needs a user-visible escape hatch.

## Next action

- Keep the policy explicit in help text and diagnostics.
- Make the host-port probes deterministic.
- Avoid publishing application ports directly on the host.

## Checkpoint and push expectation

- Branch: `linux-next`
- Checkpoint: pending
- Push: after the port selection flow is implemented and verified.

## Handoff note

The next agent should keep the fallback chain user-visible. If both preferred
ports are occupied, the user should see a direct instruction to supply `--port`.

## Repeat-mode progress report shape

- Current phase: host-port fallback implementation
- Focus task: router and observatorium port selection
- Blockers: none recorded
- Next action: tray network bootstrap

## Execution mode

- Use bounded repeat cycles when probing host-port availability.
- Refresh the step note after the probe logic or CLI help changes.
