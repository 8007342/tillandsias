# Step 24 — Diagnostics Stream & Event-Driven Observability

Status: ready
Owner: linux-host
Depends on: [forge-diagnostics-improvement-loop]

## Goal
Fully activate the event-driven diagnostics stream in the Linux headless agent, providing real-time visibility into container lifecycles, resource exhaustion, and errors.

## Tasks
- [ ] **Wiring Podman Events to Diagnostics Emitter**: Connect the `PodmanEventStream` to the `emit_diagnostic_event` wrapper when `--diagnostics` or `--debug` is active.
- [ ] **Event Type Diversity**: Implement and verify `container_exit`, `container_signal`, and `resource_exhaustion` (OOM) event types in the live stream.
- [ ] **Bounded Ring Buffer**: Implement the 10K-event ring buffer with backpressure logging to prevent memory exhaustion during event bursts.
- [ ] **Diagnostics Handle Lifecycle**: Ensure the `DiagnosticsHandle` is properly started and stopped across all forge modes (OpenCode, Claude, etc.) and the Observatorium.
- [ ] **E2E Validation**: Verify that `.stderr.log` contains the expected structured events during a full forge session.

## Exit Criteria
- `tillandsias --debug` emits ISO-8601 prefixed events for container starts, exits, and OOMs.
- `opencode-repeat` logs show the new event types in the distilled summaries.
- No memory leaks or unbounded growth in the diagnostics buffer under high event volume.
