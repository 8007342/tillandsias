# Step 15: Tray Network Bootstrap

## Objective

Make `tillandsias --tray` guarantee enclave network readiness before it launches
any project containers, so network bootstrap errors do not cascade into repeated
container failures.

## Owned files or file scopes

- `crates/tillandsias-headless/src/main.rs`
- `crates/tillandsias-podman/src/client.rs`
- `plan/steps/15-tray-network-bootstrap.md`

## Dependency tail

- Depends on the router and port-selection work so the tray can rely on the
  same runtime contract.
- Should reduce `network not found` and `125` cascades before launch.

## Current evidence

- Tray startup still needs a single place to prove the enclave network exists.
- The router should be ready before the first project container is spawned.

## Next action

- Create or reuse the enclave network through the idiomatic Podman layer.
- Wait for router readiness before project launch.
- Fail once with an actionable error instead of multiple downstream retries.

## Checkpoint and push expectation

- Branch: `linux-next`
- Checkpoint: pending
- Push: after the bootstrap path is stable and idempotent.

## Handoff note

The next agent should keep the tray bootstrap path thin and deterministic.
Avoid hiding network failures behind repeated container restarts.

## Repeat-mode progress report shape

- Current phase: tray bootstrap hardening
- Focus task: enclave network creation and router readiness gating
- Blockers: none recorded
- Next action: observatorium readiness and UX

## Execution mode

- Use bounded repeat cycles if the network bootstrap still cascades.
- Refresh after each tracer or Podman bootstrap change.
