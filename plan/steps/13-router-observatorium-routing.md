# Step 13: Router and Observatorium Routing

## Objective

Make `https://observatorium.tillandsias.localhost` the canonical browser-facing
observatorium hostname and align the router, launcher, and safe-browser
allowlist with that contract.

## Owned files or file scopes

- `crates/tillandsias-browser-mcp/src/allowlist.rs`
- `crates/tillandsias-headless/src/main.rs`
- `scripts/run-observatorium.sh`
- `openspec/specs/host-browser-mcp/spec.md`
- `openspec/specs/cli-mode/spec.md`
- `openspec/specs/subdomain-routing-via-reverse-proxy/spec.md`

## Dependency tail

- Depends on `plan-ledger-refresh` being complete enough to keep the wave readable.
- Downstream tray bootstrap and readiness work should treat this hostname as the
  canonical success path.

## Current evidence

- The launcher still had fixed port assumptions before this wave.
- The browser allowlist still expected the older service-port shape.
- The observatorium script still used a localhost-only browser target.

## Next action

- Keep the route canonical and explicit.
- Preserve the existing service-route behavior while adding observatorium support.
- Update the relevant specs and tests alongside the code.

## Checkpoint and push expectation

- Branch: `linux-next`
- Checkpoint: pending
- Push: checkpoint once the routing contract and tests are coherent.

## Handoff note

The next agent should not reintroduce host-port assumptions into the browser
allowlist. The observatorium URL is a browser contract, not a fallback alias.

## Repeat-mode progress report shape

- Current phase: routing contract alignment
- Focus task: allowlist + launcher + spec updates
- Blockers: none recorded
- Next action: port fallback chain

## Execution mode

- Use bounded repeat cycles if a spec or test mismatch appears.
- Refresh after each significant routing or spec edit.
