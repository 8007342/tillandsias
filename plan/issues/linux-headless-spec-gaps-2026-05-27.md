# Linux headless spec gaps — prioritized backlog — 2026-05-27

trace: methodology/multi-host-development.yaml, openspec/specs/{runtime-diagnostics-stream,observability-metrics,headless-mode,vsock-transport}/spec.md

Host: linux-tlatoani-fedora · branch: linux-next. Produced by a wave of read-only
audit agents (Explore subagents) for the linux WORK loop (cron `e3a4f695`) to pull
bounded slices from. Each item is sized for one loop iteration. NOT for siblings.

## Diagnostics / observability (USER PRIORITY — `--diagnostics` + logging layer)

0. **[RESOLVED] `--opencode --diagnostics` nested-runtime panic.**
   Was: runtime-litmus failed at `vault_bootstrap.rs:205` "Cannot start a
   runtime from within a runtime" — mint_approle_token_for_container built a
   fresh runtime + block_on from inside the multi-thread podman_runtime
   (`run_opencode_mode` → `podman_runtime().block_on(async { … mint … })`).
   FIXED on origin/linux-next: `mint_approle_token_for_container` is now
   `pub async fn` and `.await`s `issue_approle_token` directly (no runtime
   nesting). Verified: builds + vault tests green. (A parallel block_in_place
   helper fix was drafted on this host but dropped in favor of the cleaner
   async approach already on origin.) **END-TO-END VERIFIED** at 2026-05-28T~03:20Z
   (sibling commit `6e79297d`): manual litmus `tillandsias . --opencode
   --diagnostics` ran cleanly and exited 0. Two secondary blockers also cleared
   en route — OCI hostname length (`sanitize_hostname`) and `--print` TUI flag
   in `images/default/entrypoint-forge-opencode.sh`. The raw diagnostics log
   from that manual run wasn't committed to `plan/diagnostics/`, so the
   `curated-toolchain-backlog` triage waits for the NEXT litmus run that
   produces a committed non-empty distilled summary.
1. **[HIGH] ISO 8601 timestamp prefix on launch events.** `format_launch_event`
   (crates/tillandsias-podman/src/client.rs:~1596) emits no timestamp; spec
   runtime-diagnostics-stream requires `[<UTC>] ` prefix. Add `chrono::Utc::now()`
   prefix; update the `launch_event_line_shape_is_stable` unit test +
   litmus-container-start-health grep. Bounded, unit-verifiable.
2. **[HIGH, re-scoped 2026-05-28] `--debug` → diagnostics stream activation.**
   AUDIT CORRECTION: the `debug` → `emit_launch_event` half is ALREADY correct —
   every `run_container_observed(...)` call in the container-launch paths
   (run_opencode_mode L4053-4088, run_observatorium_mode, ensure_enclave_for_project,
   main.rs ~1741/2932/...) passes the real `debug` flag, so `event:container_launch`
   lines (now ISO-8601-prefixed, gap 1) DO emit under `--debug`/`--diagnostics`.
   REMAINING (the real, meatier slice): `DiagnosticsHandle`
   (podman/src/diagnostics_stream.rs) is exported but NEVER instantiated — it's
   the live `podman logs` tail stream the spec wants. Wiring point: in
   run_opencode_mode / run_observatorium_mode, AFTER the enclave containers
   launch + when `debug`, `DiagnosticsHandle::start(<container names>)` and let
   it forward records to stderr for the session lifetime; abort on teardown.
   Needs a live-container run (or the runtime-litmus) to verify — not a
   unit-only slice. Best sequenced after the runtime-litmus is green
   (gap-0 just fixed) so it's validated end-to-end.
3. **[CRITICAL] Event-type diversity.** Only `event:container_launch` exists; spec
   wants container_exit / container_signal / resource_exhaustion / container_stderr.
   Hook podman events (podman/src/events.rs:~105) → typed events. Larger; split.
4. **[CRITICAL] Metrics HTTP endpoint is stubbed.** metrics_server.rs:~89 has
   `TODO: Implement HTTP connection handling`; `start_metrics_server` never called
   from `run_headless_async`. Complete GET /metrics → format_prometheus_metrics;
   spawn from headless. Pair with metrics-collection-failure honesty (no fake zeros).
5. **[MED] Diagnostics event filtering + bounded ring buffer.** No
   `--debug-filter`/`--debug-container`/`TILLANDSIAS_DEBUG_LEVEL`;
   diagnostics_stream.rs:170 uses an unbounded channel (spec wants ≤10K ring +
   backpressure logging at depth>100). 

## Control-wire / VM lifecycle

6. **[MED] VmStatusRequest phase lifecycle.** vsock handler IS real (reads
   VmStateHandle, vsock_server.rs:271) but most phases are dead: only `Ready`
   (hardcoded init, line ~73) + `Draining` (line ~329) are ever set.
   `Starting`/`Stopping`/`Failed`/`Provisioning` never set. Bounded linux slice:
   gate `Starting→Ready` on `podman_ready()` transition; set `Stopping` on
   `graceful_shutdown_async` entry (thread VmStateHandle in). NOTE:
   `Provisioning` belongs to sibling provisioning paths (wsl/vz lifecycle) — not
   linux. Unix-socket transport correctly returns Unsupported for VmStatusRequest
   (host-only channel) — keep.

## Done this session (for context)
- CloudRefreshRequest: real (gh repo list) — `e1a190d4`.
- container-start-health litmus + format_launch_event extraction — `b9a36388`.
- clever-prompt actionable analysis (missing_tools/proposed_enhancements) — `1f89f4bd`.
- **GAP 1 DONE**: ISO-8601 UTC timestamp prefix on launch-event stream — `3f1cc8e8`.
- **GAP 3 PHASE-1 DONE (data shape)**: typed event formatters
  `format_container_exit_event` / `format_container_signal_event` /
  `format_resource_exhaustion_event` / `format_container_stderr_event` +
  `emit_diagnostic_event` wrapper (all in `crates/tillandsias-podman/src/
  client.rs`), with unit tests pinning every wire shape verbatim from
  spec:runtime-diagnostics-stream. STAGED via `#[allow(dead_code)]` — the
  PodmanEventStream → emitter wiring is the live-runtime PHASE-2 slice
  (paired with the gap-2 DiagnosticsHandle::start activation). Pinning the
  shape now means PHASE-2 can't drift on field order or escaping.
  (Next diagnostics gap: GAP 2 / GAP 3 PHASE-2 — wire the live podman
  events parser to emit_diagnostic_event when `debug` is on.)

## Lease note
The forge-diagnostics PACKET (annex/prompt/distill) is leased by `pickie`; items
1–5 above are headless/podman-crate diagnostics IMPLEMENTATION (different files),
not that packet. Items here are linux-host owned.
