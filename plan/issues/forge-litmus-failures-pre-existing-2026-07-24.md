# Pre-Existing Litmus Failures — Forge Container 2026-07-24

Observed during forge smoke test 2026-07-24. All failures are environmental or
pre-existing; none are new regressions from code changes.

## Podman Stalled Storage Lock (3× ENV-FAIL)

**Affected specs**: `default-image`, `forge-standalone`, `security-privacy-isolation`
**Root cause**: Podman unresponsive (>5s) — stalled storage lock or dead runtime.
**Tracked**: `plan/issues/podman-sqlite-lock-zombie-cascade-2026-07-15.md`
**Impact**: Blocks any litmus step that shells out to `podman`. The forge's Podman
runtime appears to have a stale SQLite lock from a prior process.
**Smallest next action**: `podman system reset --force` on the host, or restart the
Podman user session. The e2e gates already treat this as expected setup.

## Missing `tillandsias-policy` Binary (2× FAIL)

**Affected specs**: `cheatsheet-source-layer`, `cheatsheets-license-tiered`
**Root cause**: Litmus steps call `scripts/check-cheatsheet-sources.sh` which
invokes `target/debug/tillandsias-policy`. This binary is not present on a fresh
forge checkout without a prior `cargo build -p tillandsias-policy`.
**Impact**: Cheatsheet validation litmus cannot run on un-built forges.
**Smallest next action**: Either build `tillandsias-policy` before running litmus,
or gate the validation litmus on binary presence (skip:binary-not-found instead
of FAIL).

## Cheatsheet Host/Image Sync Drift (1× FAIL)

**Affected spec**: `cheatsheet-tooling`
**Root cause**: `litmus:cheatsheet-host-image-sync` detects divergence between the
host cheatsheet tree and the forge-image cheatsheet tree. The forge image ships a
snapshot; the host tree may have been updated without rebuilding the image.
**Impact**: Cosmetic — cheatsheets are documentation, not runtime code.
**Smallest next action**: Rebuild the forge image after cheatsheet edits, or add a
diff-base tolerance for known divergence windows.

## CI Release Toolchain Shape (1× FAIL)

**Affected spec**: `ci-release`
**Root cause**: `litmus:ci-release-toolchain-shape` step 3 expects hosted
verification workflows to be absent; they may have been added.
**Impact**: CI release workflow shape drift from spec.
**Smallest next action**: Audit `.github/workflows/` against the spec's expected
set and update the litmus or the workflow.

## Inference Container Shape (1× FAIL)

**Affected spec**: `inference-container`
**Root cause**: `litmus:inference-container-implementation-shape` step 2 checks
that `build_inference_run_args` sets the canonical container identity; the
 assertion does not match current code.
**Smallest next action**: Audit the inference container identity in
`build_inference_run_args` and update the litmus step or the code.

## E2E Eligibility Probe (1× FAIL)

**Affected spec**: `meta-orchestration`
**Root cause**: `litmus:e2e-eligibility-probe-shape` step 6 expects
`skip:live-runtime-present` when a live stack is running; the probe returns a
different verdict in this environment.
**Impact**: E2E gate skip logic may need updating for forge containers.
**Smallest next action**: Run `scripts/e2e-preflight.sh eligibility` directly to
see the actual verdict, then reconcile the litmus step.
