# Local-build smoke findings - 2026-08-02

- **Host**: `linux_mutable` (`macuahuitl`)
- **Commit tested**: `37722dba`
- **Preflight version**: `0.4.260802.1`
- **Evidence**: `target/build-install-smoke-e2e/20260802T052351Z/`
- **Result**: FAIL at gate 1; destructive reset was not reached
- **Discovered by**: `/build-install-and-smoke-test-e2e (linux)`

`./build.sh --ci-full --install` exited 1 after the pre-build litmus phase
reported 229 PASS, 3 FAIL, and 114 SKIP. The smoke stopped before installation
and before `podman system reset --force`, as required.

Failures:

- `litmus:build-trace-index-dispatch-coverage` step 4 observed CI gates before
  trace regeneration. This is already tracked by packet
  `build-trace-regeneration-before-gate-regression` (`584-2qq2`).
- `litmus:ci-release-toolchain-shape` step 3 tried to read the removed
  `.github/workflows/ci.yml`, contradicting the ratified one-workflow GitHub
  Actions budget that the adjacent `litmus:github-actions-budget` passed.
- `litmus:nix-cache-size-signal` step 1 tried to read the removed
  `.github/workflows/nix-cache-warm.yml` and therefore no longer tests an active
  surface.

The two stale workflow assumptions are shaped together as packet
`retire-stale-removed-workflow-litmus-assumptions` (`592-5zmn`). The build's
automatic failed-attempt VERSION bump was returned to the preflight value and
was not treated as a release artifact.
