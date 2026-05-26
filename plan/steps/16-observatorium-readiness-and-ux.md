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
- Remaining UX work should align OpenCode-web with the same readiness pattern
  and add any still-missing inspect data to failure output.

## Next action

- Extend the readiness/log-capture pattern to OpenCode-web.
- Add inspect data if log tail alone is not enough to distinguish route versus
  container startup failures.
- Keep the browser and tray UX aligned with the same canonical hostname.

## Checkpoint and push expectation

- Branch: `linux-next`
- Checkpoint: slice 1 pushed at `3d75eeef`; current coordination head
  `72aa7917`.
- Push: after OpenCode-web readiness parity or the next diagnostics slice.

## Handoff note

The next agent should preserve the canonical hostname, reuse the Podman client
for diagnostics, and avoid direct `podman` shellouts in readiness paths.

## Repeat-mode progress report shape

- Current phase: readiness and UX tightening
- Focus task: OpenCode-web readiness parity and remaining diagnostics
- Blockers: none recorded
- Next action: extend the real-page readiness pattern beyond observatorium

## Execution mode

- Use bounded repeat cycles for readiness probes.
- Refresh after each change to the failure path or browser target.
