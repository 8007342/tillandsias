# Step 45 — Canonical image digest and alias engine

- **Status**: claimed
- **Owner host**: linux
- **Branch**: linux-next
- **Depends on**: none
- **Specs**: default-image, init-incremental-builds, forge-staleness,
  user-runtime-lifecycle
- **Audit origin**: plan/issues/container-build-efficiency-telemetry-2026-06-08.md
- **Lease**: `lease-linux-image-identity-20260608T183115Z`
- **Agent**: `linux-macuahuitl-codex-20260608T183115Z`

## Goal

Create one deterministic image source digest and build-decision contract used by
`tillandsias --init`, direct image builds, and wrappers. The canonical digest
tag and OCI label become the durable cache identity; version and latest tags are
aliases only.

## Tasks

- [x] `image-identity/spec-and-digest`
  - Owned files: `crates/tillandsias-headless/src/runtime_assets.rs`,
    `crates/tillandsias-core/src/image_builder.rs`, a narrowly scoped new shared
    module if required, and focused unit tests.
  - Define `ImageBuildSpec` and `ImageBuildDecision` data types.
  - Hash exact build-context bytes after generated inputs exist.
  - Include path, mode, symlink target, content, build args, architecture/base
    inputs, and dependency image digest.
  - Return canonical digest tag plus version/latest aliases.
- [ ] `image-identity/oci-validation`
  - Inspect the canonical tag and
    `io.tillandsias.image.source-digest` label before deciding to build.
  - Skip from OCI state even if local JSON/hash state is absent.
  - Retag aliases without building.
  - Treat label mismatch/image absence/source change/force as distinct reasons.
- [ ] `image-identity/init-state-migration`
  - Update init state schema without destroying older state.
  - Stop treating a version-only cache mismatch as rebuild-all.
  - Persist digest, image ID, aliases, and last decision atomically.

## Next action

Write table-driven tests for context hashing before wiring Podman:

```text
same bytes/order -> same digest
same source in different checkout roots -> same digest
file content/mode/path/symlink change -> different digest
generated input staged before hash -> digest changes
gitignored router sidecar change -> router digest changes
chromium-core digest/build arg change -> framework digest changes
VERSION-only change -> same canonical digest, aliases change
```

## Acceptance evidence

- Unit tests prove deterministic digest behavior and dependency inclusion.
- A missing state file plus an existing correctly labeled digest image yields
  `skip`, not `build`.
- A VERSION-only change yields `retag`, not `build`.
- A source change yields exactly one build and new canonical tag.
- Chromium framework identity changes when its core image digest changes.
- State writes are atomic and backward-compatible.
- `cargo test` for touched crates and `./build.sh --check` pass.

## Dependency contract

Step 46 and step 47 consume the public decision/result shape from this step.
Checkpoint it before either downstream packet edits shared call sites.

## Fallback when blocked

If sharing the engine with Bash requires a larger CLI refactor, land the Rust
digest/decision library and fixtures first. Export deterministic JSON fixtures
that the shell-convergence packet can consume; do not duplicate hashing logic.

## Evidence / handoff

The current split-brain paths and exact failure modes are documented in the
audit origin.

Checkpoint 2026-06-08T18:35:23Z:

- `ImageBuildSpec`, `ImageBuildIdentity`, `ImageBuildDecision`, and OCI-state
  observation/reason types now live in `tillandsias-core`.
- Digest tests cover checkout-root independence, content/path/mode/symlink
  changes, generated inputs, build args, dependency digests, and VERSION-only
  alias changes.
- The headless runtime asset digest now consumes the shared core engine.
- Remaining work is live Podman label/alias observation plus backward-compatible
  init-state migration.
