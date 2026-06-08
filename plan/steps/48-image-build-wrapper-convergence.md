# Step 48 — Image-build wrapper convergence and end-to-end proof

- **Status**: claimed
- **Owner host**: linux
- **Branch**: linux-next
- **Depends on**: steps 44, 45, 46, 47
- **Specs**: default-image, init-command, init-incremental-builds,
  forge-staleness, litmus-framework
- **Audit origin**: plan/issues/container-build-efficiency-telemetry-2026-06-08.md
- **Lease**: `lease-linux-image-wrapper-convergence-20260608T190843Z`
- **Agent**: `linux-macuahuitl-codex-20260608T190843Z`

## Goal

Remove placeholder and fallback build paths, make every wrapper call the same
canonical build engine, and prove the version-tag-plus-latest contract rebuilds
only when the source digest changes.

## Tasks

- [ ] `image-build-convergence/entrypoint`
  - Owned files: `crates/tillandsias-core/src/bin/build-image.rs`,
    `crates/tillandsias-core/src/image_builder.rs`, top-level `build-*.sh`,
    `scripts/build-image.sh`.
  - Replace the placeholder binary and Toolbox round-trip.
  - Keep thin compatibility wrappers only where they add user-facing flags.
  - Route forge, proxy, git, inference, router, chromium-core,
    chromium-framework, vault, and web through one engine.
- [ ] `image-build-convergence/e2e-litmus`
  - Owned files: `openspec/litmus-tests/`,
    `openspec/litmus-bindings.yaml`, focused shell/Rust tests.
  - Assert the exact sequence:
    1. first source digest builds once
    2. second invocation skips
    3. VERSION-only change retags
    4. context change builds once
    5. missing alias retags
    6. missing canonical image rebuilds
    7. force rebuild is explicit
  - Assert no network installer piping, no floating latest source, and no
    duplicate build for one digest.
- [ ] `image-build-convergence/docs-and-state`
  - Reconcile active spec language that still names the wrong forge path or
    outdated build behavior.
  - Document telemetry location and diagnostic commands.

## Next action

Inventory every public build entrypoint and map it to the canonical engine.
Fail the packet if any path still constructs its own freshness decision.

## Acceptance evidence

- All public build scripts and `tillandsias --init` emit the same canonical
  digest, labels, aliases, decision reason, and telemetry schema.
- No wrapper invokes Toolbox or checks for
  `ImageBuilder trait not yet integrated`.
- End-to-end litmus proves unchanged digest means zero `podman build`
  invocations.
- Full image matrix respects dependency ordering.
- Focused crate tests, shell tests, instant litmus, `./build.sh --check`, and one
  real Podman smoke pass.

## Dependency contract

- Step 44 supplies deterministic package/download inputs.
- Step 45 supplies canonical identity and decisions.
- Step 46 supplies cache/serialization policy.
- Step 47 supplies event emission and metrics.

## Fallback when blocked

If one image has an independent upstream failure, complete convergence for the
remaining matrix and record the failed image as a named retryable child packet.
Do not weaken the digest/alias assertions for all images.

## Evidence / handoff

Current placeholders:
`crates/tillandsias-core/src/bin/build-image.rs:19-85` and
`crates/tillandsias-core/src/image_builder.rs:308-385`.
