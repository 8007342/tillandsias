<!-- @trace spec:async-inference-launch -->
# async-inference-launch Specification

## Status

active
promoted-from: openspec/changes/archive/2026-04-16-async-inference-launch/
annotation-count: 9

## Purpose

Defer inference container startup to a background task, unblocking forge launch within 2-5 seconds while inference initializes asynchronously. Inference is a soft requirement — failure logs `DEGRADED` but does not block coding session start.

## Requirements

### Requirement: Detached inference startup task

The `ensure_enclave_ready()` handler MUST spawn `ensure_inference_running()` as a detached `tokio::spawn(...)` task instead of awaiting it synchronously. The spawned task MUST:

1. MUST run the same inference health check (curl to `/api/version` with exponential backoff)
2. MUST emit `info!` on success, `warn!` on failure (with `safety = "DEGRADED"`)
3. MUST drop the `JoinHandle` — the tray does not wait for or consume the result

The `BUILD_MUTEX` at `handlers.rs:54` already serializes concurrent builds, so the spawned task will queue naturally behind any in-flight podman operations.

#### Scenario: Inference launches background while forge starts

- **WHEN** `ensure_enclave_ready()` reaches the inference startup point
- **THEN** it MUST spawn the task and return immediately (no await)
- **AND** the caller MUST proceed to forge launch without waiting for inference readiness
- **AND** the readiness event MUST be logged from inside the spawned task (observable via `--log-enclave`)

#### Scenario: Inference failure does not block forge shell access

- **WHEN** the spawned inference task fails after 10 backoff attempts
- **THEN** a `warn!` line MUST be emitted with `safety = "DEGRADED: inference unavailable"`
- **AND** the coding session MUST already be running — the user has shell access regardless

### Requirement: Startup-time empirical validation

A timer log line MUST be emitted at the end of `ensure_enclave_ready()` (before inference result) to record the elapsed time from handler start to readiness. This enables measurement of the warm-launch savings empirical ly.

#### Scenario: Timer confirms sub-5-second launch when inference omitted from critical path

- **WHEN** an attach is completed with no prior inference container
- **THEN** the timer log MUST show elapsed < 5 seconds (vs. 15-55 s with synchronous inference)
- **AND** the log line MUST include annotation `@trace spec:async-inference-launch, spec:enclave-network`

### Requirement: Enclave readiness message clarity

The final readiness line emitted by `ensure_enclave_ready()` MUST distinguish between:

1. "proxy + git ready; inference launching async" (when inference is not yet ready)
2. "enclave fully ready, all services responding" (if called at a time when inference is already confirmed)

This prevents the user from being surprised that inference is not immediately available.

#### Scenario: Readiness log distinguishes async inference state

- **WHEN** `ensure_enclave_ready()` completes
- **THEN** the terminal or tray status line MUST indicate inference is launching in the background
- **AND** a separate `--log-enclave` line MUST confirm when inference comes online

## Sources of Truth

- `cheatsheets/runtime/async-patterns-rust.md` — tokio::spawn, JoinHandle dropping, fire-and-forget task lifecycle
- `cheatsheets/runtime/enclave-startup-sequencing.md` — enclave readiness state machine and timing targets
## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`
- `litmus:inference-readiness-probe-shape`

Gating points:
- Observable ephemeral guarantee: resources created during initialization are destroyed on shutdown
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked resources, persistence) are detectable
