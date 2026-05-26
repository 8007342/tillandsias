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

- Completed on `linux-next` through `35c45822`.
- `run_opencode_mode`, `run_observatorium_mode`, and tray-driven Forge
  launches now run the same critical order: enclave network, stale container
  cleanup, router readiness, project containers, then Caddy reload.
- `openspec/litmus-tests/litmus-tray-network-bootstrap.yaml` asserts
  `ensure_router_running` appears before the first project container spawn in
  all three paths.

## Next action

- Move to Step 16: observatorium readiness should prove the real
  browser-visible page and attach logs/inspect data when it fails.
- Follow-up for the litmus harness: register the tray-network-bootstrap litmus
  in `openspec/litmus-bindings.yaml` once the generator/update path is clear.

## Checkpoint and push expectation

- Branch: `linux-next`
- Checkpoint: complete (`cf74e176`, `4337f917`, `14a8bd77`; coordination tip
  `35c45822`)
- Push: complete

## Handoff note

Step 15 is complete. The next agent should keep the bootstrap path thin while
making Step 16 failures diagnosable from one observatorium launch attempt.

## Repeat-mode progress report shape

- Current phase: tray bootstrap hardening
- Focus task: completed; next focus is observatorium readiness probes
- Blockers: none recorded
- Next action: observatorium readiness and UX

## Execution mode

- Use bounded repeat cycles if the network bootstrap still cascades.
- Refresh after each tracer or Podman bootstrap change.
