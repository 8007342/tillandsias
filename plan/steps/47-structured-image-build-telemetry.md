# Step 47 — Structured image-build telemetry

- **Status**: pending
- **Owner host**: linux
- **Branch**: linux-next
- **Depends on**: step 45
- **Specs**: runtime-logging, observability-metrics, init-incremental-builds
- **Audit origin**: plan/issues/container-build-efficiency-telemetry-2026-06-08.md

## Goal

Emit one privacy-safe JSONL event stream for every image build decision and
outcome across `--init`, direct builds, and wrappers, then derive local metrics
that expose duplicate work, failures, cache effectiveness, duration, and size.

## Tasks

- [ ] `image-telemetry/schema-and-writer`
  - Owned files: `crates/tillandsias-logging/src/event_collector.rs`,
    `crates/tillandsias-logging/src/lib.rs`, focused logging tests.
  - Extend the existing `ImageBuildEvent` rather than adding a disconnected
    schema.
  - Add decision/start/completed/failed lifecycle events and the fields listed
    in the audit origin.
  - Implement append locking, atomic JSONL lines, redaction, rotation/retention,
    and non-fatal write failure.
- [ ] `image-telemetry/runtime-wiring`
  - Owned files: `crates/tillandsias-headless/src/main.rs`,
    `crates/tillandsias-core/src/image_builder.rs`,
    `crates/tillandsias-podman/src/client.rs`.
  - Emit from the same decision/result object used for human output.
  - Correlate events with one `build_id`.
  - Capture source digest, decision reason, Podman version, duration, image ID,
    size, cache result, and failure class.
- [ ] `image-telemetry/metrics`
  - Owned files: `crates/tillandsias-metrics/`,
    `crates/tillandsias-headless/src/metrics_server.rs`.
  - Expose low-cardinality counters/histograms for attempts, outcomes,
    duplicate builds, duration, image size, cache result, and bytes downloaded
    when trustworthy.

## Next action

Add serialization/redaction tests for one event of each lifecycle type before
wiring live build commands.

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

Existing unused schema:
`crates/tillandsias-logging/src/event_collector.rs:123-176`.
