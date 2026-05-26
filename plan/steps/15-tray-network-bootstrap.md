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

- Router-before-container ordering completed on `linux-next` through `35c45822`.
- `run_opencode_mode`, `run_observatorium_mode`, and tray-driven Forge
  launches now run the same critical order: enclave network, stale container
  cleanup, router readiness, project containers, then Caddy reload.
- `openspec/litmus-tests/litmus-tray-network-bootstrap.yaml` asserts
  `ensure_router_running` appears before the first project container spawn in
  all three paths.
- The 2026-05-26T14:14Z dynamic-loop status reopened one residual UX slice:
  collapse exit-125 project-container cascades into one typed, actionable
  diagnostic before treating Step 15 as fully closed.

## Next action

- Collapse the exit-125 project-container spawn cascade into one typed error
  and user-readable diagnostic.
- Then move to Step 16: observatorium/OpenCode-web readiness should prove the
  real browser-visible page and attach logs/inspect data when it fails.
- Follow-up for the litmus harness: register the tray-network-bootstrap litmus
  in `openspec/litmus-bindings.yaml` once the generator/update path is clear.

## Checkpoint and push expectation

- Branch: `linux-next`
- Checkpoint: router-ordering slices complete (`cf74e176`, `4337f917`,
  `14a8bd77`; coordination tips `35c45822` and `aa8fc2b9`)
- Push: after the exit-125 cascade UX slice

## Handoff note

Step 15 is almost closed. The next agent should keep the bootstrap path thin,
collapse exit-125 cascades into one actionable diagnostic, then make Step 16
failures diagnosable from one observatorium or OpenCode-web launch attempt.

## Repeat-mode progress report shape

- Current phase: tray bootstrap hardening
- Focus task: exit-125 cascade UX residual, then observatorium readiness probes
- Blockers: none recorded
- Next action: single diagnostic for project-container spawn failure

## Execution mode

- Use bounded repeat cycles if the network bootstrap still cascades.
- Refresh after each tracer or Podman bootstrap change.
