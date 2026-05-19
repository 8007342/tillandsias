# Step 16a: Methodology Reconciliation

## Status

completed

## Objective

Close the audit gap between the working OpenCode Web launch path and the
durable methodology state.

## Evidence landed

- OpenCode Web now applies the OpenCode config/TUI overlay in web mode.
- The web entrypoint fronts `opencode serve` with `sse-keepalive-proxy.js` so
  dark-theme bootstrap and SSE keepalive behavior are active on port 4096.
- The launcher sets `TILLANDSIAS_PROJECT=<project>` and mounts the project at
  `/home/forge/src/<project>`.
- The browser launch path now requires a `401` no-cookie route probe and a
  `2xx/3xx` registered-cookie probe before opening Chromium.
- Runtime CA generation and build-time dev-proxy CA generation now serialize
  and publish cert/key files atomically.
- Active specs were updated for browser isolation, OTP readiness,
  OpenCode onboarding, and reverse-proxy CA behavior.
- Ghost trace debt was reconciled into active specs or retargeted to current
  owner specs; fixture traces in dead-trace detector tests no longer pollute
  repository trace scans.
- `TRACES.md` and per-spec trace indexes were regenerated.
- Broken cheatsheet references were repaired, and
  `cheatsheets/runtime/opencode-web-launch.md` was added.

## Verification

```bash
cargo test -p tillandsias-headless --bin tillandsias opencode_web -- --nocapture
bash -n build.sh images/default/entrypoint-forge-opencode-web.sh
scripts/validate-traces.sh
scripts/check-cheatsheet-refs.sh
bash scripts/validate-spec-cheatsheet-binding-fast.sh
```

## Residual work

- `scripts/validate-traces.sh` still reports warnings for active in-flight
  OpenSpec changes; it reports 0 ghost-trace errors.
- Observatorium readiness remains a separate Step 16 task.
- Legacy shell Podman migration remains under Step 15.5.
