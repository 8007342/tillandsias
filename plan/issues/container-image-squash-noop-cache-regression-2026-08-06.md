# Squashed final images lose incremental build cache on Podman 5.8.4

Date: 2026-08-06 (America/Los_Angeles)
Status: ready
Plan: `container-image-squash-noop-cache-regression` (order 617-mxqn)
Release: v0.5

## Finding

The isolated order 608-ijbt A/B proved that unconditional `podman build
--squash` collapses each final image to its inherited base plus one layer, but
on Podman/Buildah 5.8.4 it also prevents ordinary step-cache reuse in the next
unchanged build. Three no-op repetitions reproduced this across Alpine git,
Alpine router and Fedora chromium-framework.

Median no-op regressions were 11.75x, 47.60x and 31.78x respectively. Logs
show layered builds resolving every instruction with `Using cache`, while the
squashed builds re-execute package-manager and copy steps. Explicit
`--no-cache` controls take nearly the same time as squashed no-ops. Forge is
less dramatic (1.12x) only because its 71 mostly local COPY/metadata steps are
relatively cheap.

The trade does not pay for itself in the measured distribution path: total
compressed archive bytes fell 0.099%, clean loaded-store apparent bytes fell
0.0372%, and startup medians ranged from 12.97% faster to 4.52% slower. The
whole controlled build matrix rose from 817.72s to 1,503.37s (+83.85%).

## Required change

Preserve the base-plus-one runtime layer goal without forcing every incremental
developer build to discard its useful step cache. First reproduce the
interaction in a minimal fixture with explicit `--layers`, environment defaults
and current Buildah behavior; `--layers` already reported default true in the
failed configuration, so merely spelling that flag is not proof of a fix.

Evaluate the smallest maintainable alternatives, such as a separately retained
cacheable build artifact followed by final-image materialization, or scoping
squashing to release/transport construction while keeping local iterative
builds layered. Do not choose a mechanism until the three real builders and
content-identity semantics can express the same policy.

## Exit contract

- Three unchanged rebuilds for git, router, chromium-framework and forge use
  cached package/COPY steps; median time is no more than 2x the paired layered
  control unless an explicit operator-approved budget replaces that bound.
- A late terminal-file change does not rerun unaffected package-manager steps.
- Runtime images still retain the exact direct-base layer prefix and add no
  more than one final layer when the squashed policy is selected.
- Compiled init, compiled on-demand construction, shell developer builds and
  content-hash identity agree on the revised policy.
- A repeat isolated A/B records build, archive, clean loaded-store, load and
  15-sample ready latency, and never mutates the default Podman store.
- No user-visible UX surface changes.

Primary evidence:

- `plan/issues/optimization/container-image-squash-isolated-ab-benchmark-2026-08-05.md`
- `plan/issues/container-image-final-layer-squashing-2026-08-05.md`
