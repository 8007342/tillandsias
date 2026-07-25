# Post-build full meta-orchestration is handed a deterministically dirty checkout

- **Date**: 2026-07-25
- **Classification**: enhancement
- **Status**: ready
- **Desired release**: v0.4
- **Order**: 489
- **Discovered by**: `/build-install-and-smoke-test-e2e (linux)`

## Reproduction

Run `./build.sh --ci-full --install` from a clean `linux-next`. The build's
`_prepare_ci_full_install_inputs` bumps VERSION/Cargo versions and local CI
regenerates the CentiColon dashboard. Its post-build
`litmus:opencode-prompt-e2e-shape` then launches full `/meta-orchestration` in
the same checkout.

The in-forge cycle correctly reports `blocked: dirty-start-worktree`, preserving
these tracked paths byte-identically, and exits 0. The litmus records mode
`full`, so its next step waits 120 seconds for a commit that cannot legally
exist and fails `HEAD unchanged`.

Evidence: `/tmp/opencode-e2e-forge.log:50-103` and
`target/build-install-smoke-e2e/20260725T045500Z/01-build-install.log` under
`litmus:opencode-prompt-e2e-shape`.

## Constraint

Do not weaken meta-orchestration's dirty-start refusal. Give the post-build
agent a clean checkout/worktree boundary, or make local-build version/dashboard
inputs ephemeral so the shared checkout stays clean. The freshly installed
binary must remain the runtime under test, and full mode must still prove a
plan commit reaches both local and remote `linux-next`.
