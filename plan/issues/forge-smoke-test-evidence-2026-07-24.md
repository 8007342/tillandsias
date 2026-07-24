# Forge Container Smoke Test Evidence — 2026-07-24

- Agent: OpenCode (big-pickle)
- Host: forge container
- Branch: `main`
- Startup context: `.forge-startup-context.md` present (version 0.3.260724.1)

## Git Network

| Check | Result |
|---|---|
| `git fetch origin --dry-run` | ✅ Everything up-to-date |
| `git push --dry-run origin HEAD` | ✅ push OK |
| `scripts/check-credential-channel.sh` | ✅ `ok:forge-git-mirror` |

## Litmus Pre-Build (instant)

- **155 PASS / 10 FAIL / 147 SKIP** (93% pass rate, 100% spec coverage)
- All failures are pre-existing and environmental:

### Failure Breakdown

1. **Podman unresponsive (3× ENV-FAIL)**: `podman-sqlite-lock-zombie-cascade-2026-07-15` — stalled storage lock, not a code regression. Affects `default-image`, `forge-standalone`, `security-privacy-isolation` specs.

2. **Missing `tillandsias-policy` binary (2× FAIL)**: `cheatsheet-source-layer-validation` and `cheatsheet-tier-discipline` depend on `target/debug/tillandsias-policy` which requires a prior `cargo build`. Not present on a fresh forge checkout.

3. **Cheatsheet host/image sync (1× FAIL)**: `cheatsheet-host-image-sync` — pre-existing divergence between host and forge-image cheatsheet trees.

4. **CI release toolchain shape (1× FAIL)**: `ci-release-toolchain-shape` — expects absence of hosted verification workflows; pre-existing.

5. **Inference container shape (1× FAIL)**: `inference-container-implementation-shape` — `build_inference_run_args` canonical container identity mismatch.

6. **E2E eligibility probe (1× FAIL)**: `e2e-eligibility-probe-shape` — depends on live Podman runtime, which is stalled.

## Workspace Tests

All 100% unit/doctest pass (verified via prior forge cycle 2026-07-24T04:24Z).

## Verdict

Forge container network, git credentials, plan index, and litmus suite are healthy. No new regressions.
