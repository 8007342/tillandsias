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

- Step 16 slice 1 shipped at `3d75eeef`: `wait_for_observatorium_http_ready`
  polls the real HTTPS page and accepts 2xx/3xx/4xx readiness responses.
- On readiness failure, the launcher reports one actionable error with
  observatorium container log tail through the shared Podman client.
- **Step 16 slice 2 completed**: Aligned OpenCode-web (`wait_for_opencode_web_route` and `wait_for_authenticated_opencode_web`) with the same robust HTTP readiness-check and log-tailing pattern.
- Successfully verified that all 661+ unit and integration tests and 16 litmus checks pass cleanly with 100% success.

## Next action

- None. Step 16 is fully completed and verified!

## Checkpoint and push expectation

- Branch: `linux-next`
- Checkpoint: Step 16 is fully completed and verified.
- Push: Completed as part of coordination cycle 2026-05-29T07:05:00Z.

## Handoff note

- Step 16 is complete. Sibling hosts can pull/merge these robust readiness changes.

## Repeat-mode progress report shape

- Current phase: completed
- Focus task: none
- Blockers: none
- Next action: none

## Execution mode

- Step 16 closed.
