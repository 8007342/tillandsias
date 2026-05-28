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
4. **[DONE] Metrics HTTP endpoint.** Implemented hand-rolled HTTP/1.1
   handler in `crates/tillandsias-headless/src/metrics_server.rs`:
   `GET /metrics` → `format_prometheus_metrics` body with
   `Content-Type: text/plain; version=0.0.4`; `POST /metrics` → 405; wrong
   path → 404; bad request → 400; collection failure → 500 with error body
   (NOT a fabricated 200 — explicit per spec:observability-metrics).
   Connection-per-scrape (no keep-alive), 5s read timeout + 8KB request
   cap to bound slow-loris. Wired into `run_headless_async` via
   `spawn_metrics_http_server` paired with the sampler abort. Default bind
   `127.0.0.1:9090`; override with `TILLANDSIAS_METRICS_ADDR`. Bind failure
   logs + continues (headless MUST NOT refuse to start because the
   diagnostic surface is unavailable). Two end-to-end tests over real
   TCP loopback + a routing matrix unit test pin behaviour.
5. **[MED] Diagnostics event filtering + bounded ring buffer.**
   PHASE-1 DONE: filtering side. `crates/tillandsias-podman/src/
   diagnostics_filter.rs` implements `DiagnosticsFilter` reading
   `TILLANDSIAS_DEBUG_FILTER` (comma-list of event types),
   `TILLANDSIAS_DEBUG_CONTAINER` (glob with `*` wildcards), and
   `TILLANDSIAS_DEBUG_LEVEL` (`normal`/`verbose`; verbose unlocks
   `event:internal_*`). Consulted by `emit_launch_event` and the (staged)
   `emit_diagnostic_event`; cached in a process-wide `OnceLock`. Eight
   unit tests pin behaviour for every spec scenario. PHASE-2 PENDING:
   bounded ring buffer in diagnostics_stream.rs (≤10K events,
   backpressure log at depth>100, drop-oldest). Needs the runtime wiring
   (gap-2/3 phase-2) to land first because the channel today is in the
   not-yet-active DiagnosticsHandle path.

## Control-wire / VM lifecycle

6. **[DONE] VmStatusRequest phase lifecycle (linux-owned phases).**
   `VmStateHandle::new()` now defaults to `Starting` (not `Ready` —
   listener-bound ≠ podman-reachable). Added two async helpers in
   `crates/tillandsias-headless/src/vsock_server.rs`:
   `advance_to_ready_when_podman_up(timeout, poll_interval)` polls
   `podman_ready` and flips `Starting → Ready` or `Starting → Failed`
   on timeout; `watch_shutdown_and_mark_stopping(shutdown)` waits for
   the SIGTERM/SIGINT atomic and flips `* → Stopping` (preserving a
   terminal `Failed`). Both spawned alongside `run_vsock_listener` from
   `maybe_spawn_vsock_listener` in main.rs — `graceful_shutdown_async`
   needs no signature change; phase transitions ride the same shared
   shutdown atomic the listener already uses. Five new tokio tests pin
   every transition (`Starting → Ready` on socket appear,
   `Starting → Failed` on timeout, respect concurrent transitions,
   shutdown flips to Stopping, Stopping does NOT clobber Failed).
   NOTE: `Provisioning` belongs to sibling provisioning paths (wsl/vz)
   — not linux. Unix-socket transport correctly returns Unsupported
   for VmStatusRequest (host-only channel) — left as-is.

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
- **GAP 4 DONE**: metrics HTTP endpoint completed + wired into
  `run_headless_async`. See gap-4 description above for the full
  shape; spawn helper is `spawn_metrics_http_server` in
  `crates/tillandsias-headless/src/main.rs`.
- **GAP 5 PHASE-1 DONE**: `DiagnosticsFilter` (event-type allowlist +
  container glob + debug level). `crates/tillandsias-podman/src/
  diagnostics_filter.rs` + integration in `emit_launch_event` /
  `emit_diagnostic_event`. See gap-5 description above for env-var
  surface. Ring-buffer half is PHASE-2.
- **GAP 6 DONE** (linux-owned phases): VmStateHandle defaults to
  `Starting`; phase-advancer + shutdown-watcher tasks spawned by
  `maybe_spawn_vsock_listener` carry the lifecycle without threading
  state through `graceful_shutdown_async`. `Provisioning` belongs to
  sibling provisioning paths.
- **GAP 3 PHASE-1B DONE** (parser → typed-record exit_code):
  `ContainerLifecycleRecord` gained an `exit_code: Option<i32>` field;
  `parse_podman_lifecycle_record` now extracts `ContainerExitCode`
  from podman events Died payloads (modern top-level + legacy
  `Actor.Attributes.containerExitCode` shape, stringified or integer).
  Non-Died statuses get `None`. Five new unit tests pin both shapes
  + the "Died without exit code reports None" honesty case.
- **USER PRIORITY (b) DONE**: forge-diagnostics annex now captures
  stderr to a `.stderr.log` companion next to the stdout JSON. The
  idiomatic-layer `event:container_launch` stream — previously
  discarded by `2>/dev/null` — is now available to litmus assertions
  via `target/forge-diagnostics/diagnostics_<UTC>.stderr.log`. Empty
  stderr is recorded as a FINDING (non-blocking). The forge-diagnostics-
  e2e litmus gained two structural assertions: ≥1 `state=running`
  line + zero `state=failed` lines from the same capture cycle. This
  fulfills "leverage `tillandsias ... --diagnostics` to extract
  meaningful structured results" — both the JSON capability report
  AND the launch-event stream now ride one forge launch per cycle.
  (Next diagnostics gap: GAP 2 / GAP 3 PHASE-2 — wire the live podman
  events parser to emit_diagnostic_event when `debug` is on.)

## Lease note
The forge-diagnostics PACKET (annex/prompt/distill) is leased by `pickie`; items
1–5 above are headless/podman-crate diagnostics IMPLEMENTATION (different files),
not that packet. Items here are linux-host owned.
