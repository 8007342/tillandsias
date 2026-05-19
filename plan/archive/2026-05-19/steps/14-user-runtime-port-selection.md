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

- The headless launcher implements the 80 -> 8080 -> `--port` candidate chain.
- Existing router publishes are reused before probing new ports, so a running
  router does not trip the availability check.
- Observatorium still needs a user-visible escape hatch as part of the
  observatorium readiness wave.

## Completion evidence

- `cargo test -p tillandsias-headless --bin tillandsias opencode_web -- --nocapture`
  passed after the reconciliation edits.
- The remaining observatorium-specific port UX is tracked by Step 16, not this
  completed router host-port selection step.

## Checkpoint and push expectation

- Branch: `linux-next`
- Checkpoint: pending
- Push: after the reconciliation batch is coherent.

## Handoff note

The fallback chain is implemented in the runtime. Future work should keep the
diagnostic text user-visible when both preferred ports are occupied.

## Repeat-mode progress report shape

- Current phase: host-port fallback implementation
- Focus task: router and observatorium port selection
- Blockers: none recorded
- Next action: tray network bootstrap

## Execution mode

- Use bounded repeat cycles when probing host-port availability.
- Refresh the step note after the probe logic or CLI help changes.
