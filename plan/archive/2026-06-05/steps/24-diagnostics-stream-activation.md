# Step 24 — Diagnostics Stream & Event-Driven Observability

Status: completed
Owner: linux-host
Depends on: [forge-diagnostics-improvement-loop]

## Goal
Fully activate the event-driven diagnostics stream in the Linux headless agent, providing real-time visibility into container lifecycles, resource exhaustion, and errors.

## Tasks
- [x] **Wiring Podman Events to Diagnostics Emitter**: Connect the `PodmanEventStream` to the `emit_diagnostic_event` wrapper when `--diagnostics` or `--debug` is active.
- [x] **Event Type Diversity**: Implement and verify `container_exit`, `container_signal`, and `resource_exhaustion` (OOM) event types in the live stream.
- [x] **Bounded Ring Buffer**: Implement the 10K-event ring buffer with backpressure logging to prevent memory exhaustion during event bursts.
- [x] **Diagnostics Handle Lifecycle**: Ensure the `DiagnosticsHandle` is properly started and stopped across all forge modes (OpenCode, Claude, etc.) and the Observatorium.
- [x] **E2E Validation**: Verify that `.stderr.log` contains the expected structured events during a full forge session.

## Exit Criteria
- `tillandsias --debug` emits ISO-8601 prefixed events for container starts, exits, and OOMs.
- `opencode-repeat` logs show the new event types in the distilled summaries.
- No memory leaks or unbounded growth in the diagnostics buffer under high event volume.

## Outcome
- Implemented `format_container_start_event` in the shared `tillandsias-podman` crate.
- Connected the `PodmanEventStream` container `Started` lifecycle action to emit `event:container_start`.
- Wired the live diagnostic-event emitter and log stream handles across all forge modes (OpenCode CLI, OpenCode Web, Claude, Codex, Maintenance/Bash) and the Observatorium.
- Verified using targeted cargo tests and the full pre-build instant litmus suite (99/99 pass rate).
