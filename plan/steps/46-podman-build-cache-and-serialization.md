# Step 46 — Podman build cache reuse and serialization

- **Status**: claimed
- **Owner host**: linux
- **Branch**: linux-next
- **Depends on**: step 45
- **Specs**: init-incremental-builds, dev-build, user-runtime-lifecycle
- **Audit origin**: plan/issues/container-build-efficiency-telemetry-2026-06-08.md
- **Lease**: `lease-linux-image-cache-20260608T184315Z`
- **Agent**: `linux-macuahuitl-codex-20260608T184315Z`

## Goal

Stop throwing away Podman layers and package downloads on every legitimate
rebuild, while protecting rootless Podman storage from unsafe concurrent build
mutations.

## Tasks

- [ ] `image-cache/layer-policy`
  - Owned files: `scripts/build-image.sh`,
    `crates/tillandsias-podman/src/client.rs`, image Containerfiles only for
    cache-mount directives.
  - Remove unconditional `--no-cache`.
  - Make normal layer reuse explicit and reserve no-cache behavior for a named
    diagnostic flag.
  - Add scoped `RUN --mount=type=cache` mounts for remaining network-heavy
    package managers where Podman supports them.
  - Stop deleting `$HOME/.cache/tillandsias/packages` before every build.
  - Keep cache IDs partitioned by package manager, architecture, and base image.
- [ ] `image-cache/storage-lock`
  - Owned files: `scripts/build-image.sh`, `build-all-images.sh`, shared shell
    helper if needed.
  - Add a cross-process build lock or a proven bounded scheduler.
  - Make `--parallel` either dependency-aware and storage-safe or retire it with
    a clear replacement.
- [ ] `image-cache/containerfile-order`
  - Audit stable expensive layers versus frequently changed COPY layers.
  - Move cheatsheets/config/entrypoints after toolchain layers where behavior
    permits.

## Next action

Capture a baseline with one cold build, one unchanged invocation, and one
late-context-only change. Record Podman version, elapsed time, network bytes if
available, and layer reuse evidence before editing.

## Acceptance evidence

- Unchanged source digest does not invoke `podman build`.
- A late COPY-only change reuses OS/toolchain layers.
- A forced no-cache diagnostic is explicit and observable.
- Package downloads are reused without sharing incompatible cache state.
- Two concurrent wrapper invocations serialize or schedule safely and produce
  valid images.
- `build-all-images.sh` propagates individual failures correctly.
- Targeted shell tests/litmus and `./build.sh --check` pass.

## Dependency contract

Requires step 45's canonical `ImageBuildSpec` and decision reasons. Cache policy
must not become a second source of image freshness.

## Fallback when blocked

If cache mounts prove incompatible with Fedora Minimal/microdnf in the current
Podman version, still land layer reuse plus build serialization and document
the exact cache-mount failure. Do not restore unconditional `--no-cache`.

## Evidence / handoff

Baseline defects: `scripts/build-image.sh:340-346` and `435-456`;
`build-all-images.sh:35-41`.
