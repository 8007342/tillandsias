# Step 47 — Structured image-build telemetry

- **Status**: completed
- **Owner host**: linux
- **Branch**: linux-next
- **Depends on**: step 45
- **Specs**: runtime-logging, observability-metrics, init-incremental-builds
- **Audit origin**: plan/issues/container-build-efficiency-telemetry-2026-06-08.md
- **Lease**: `lease-linux-image-telemetry-20260608T184647Z`
- **Agent**: `linux-macuahuitl-codex-20260608T184647Z`

## Goal

Emit one privacy-safe JSONL event stream for every image build decision and
outcome across `--init`, direct builds, and wrappers, then derive local metrics
that expose duplicate work, failures, cache effectiveness, duration, and size.

## Tasks

- [x] `image-telemetry/schema-and-writer`
  - Owned files: `crates/tillandsias-logging/src/event_collector.rs`,
    `crates/tillandsias-logging/src/lib.rs`, focused logging tests.
  - Extend the existing `ImageBuildEvent` rather than adding a disconnected
    schema.
  - Add decision/start/completed/failed lifecycle events and the fields listed
    in the audit origin.
  - Implement append locking, atomic JSONL lines, redaction, rotation/retention,
    and non-fatal write failure.
- [x] `image-telemetry/runtime-wiring`
  - Owned files: `crates/tillandsias-headless/src/main.rs`,
    `crates/tillandsias-core/src/image_builder.rs`,
    `crates/tillandsias-podman/src/client.rs`.
  - Emit from the same decision/result object used for human output.
  - Correlate events with one `build_id`.
  - Capture source digest, decision reason, Podman version, duration, image ID,
    size, cache result, and failure class.
- [x] `image-telemetry/metrics`
  - Owned files: `crates/tillandsias-metrics/`,
    `crates/tillandsias-headless/src/metrics_server.rs`.
  - Expose low-cardinality counters/histograms for attempts, outcomes,
    duplicate builds, duration, image size, cache result, and bytes downloaded
    when trustworthy.

## Acceptance evidence

- A skip, retag, successful build, forced build, and failed build each emit a
  valid correlated event sequence.
- Concurrent emitters do not corrupt JSONL.
- No token, secret environment value, or URL query string appears in fixtures
  or live events.
- Telemetry failure does not fail the build and produces a visible warning.
- Prometheus output uses bounded labels and stable units.
- Existing logging event-coverage tests plus targeted metrics/headless tests
  and `./build.sh --check` pass.

## Dependency contract

Consumes step 45's `ImageBuildDecision` and result fields. It must not parse
human-readable shell output to reconstruct decisions.

## Fallback when blocked

If Prometheus wiring collides with active metrics work, complete schema, writer,
and runtime JSONL wiring first; split metrics projection into a follow-up only
after recording the collision in this step.

## Evidence / handoff

- Implementation: `ec5cf96c` (`feat(images): emit structured build telemetry`).
- Retention follow-up: `1c316e5c` (`fix(images): bound telemetry event retention`).
- `cargo test -p tillandsias-logging image_build --lib`: 12 passed.
- `cargo test -p tillandsias-headless image_build_metrics_use_bounded_labels_and_stable_units`:
  1 passed.
- `cargo clippy -p tillandsias-logging --lib -- -D warnings`: passed.
- `cargo check -p tillandsias-headless`: passed.
- `./build.sh --check`: passed; optional development proxy startup was
  unavailable and remained non-fatal.
