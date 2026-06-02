# Linux headless spec gaps — prioritized backlog — 2026-05-27

trace: methodology/multi-host-development.yaml, openspec/specs/{runtime-diagnostics-stream,observability-metrics,headless-mode,vsock-transport}/spec.md

Host: linux-tlatoani-fedora · branch: linux-next. Produced by a wave of read-only
audit agents (Explore subagents) for the linux WORK loop (cron `e3a4f695`) to pull
bounded slices from. Each item is sized for one loop iteration. NOT for siblings.

## Diagnostics / observability (USER PRIORITY — `--diagnostics` + logging layer)

### Work Packet: spec-gap/external-logs-layer-binding-hygiene

- id: `spec-gap/external-logs-layer-binding-hygiene`
- owner_host: linux
- capability_tags: [specs, litmus, docs, testing]
- status: done
- lease:
  - lease_id: `f6f17a60a253`
  - agent_id: `linux-macuahuitl-codex-2026-06-02T182536Z`
  - host: linux
  - acquired_at: `2026-06-02T18:25:36Z`
  - expires_at: `2026-06-02T22:25:36Z`
- owned_files:
  - `openspec/specs/external-logs-layer/spec.md`
  - `openspec/litmus-bindings.yaml`
  - `openspec/litmus-tests/litmus-external-logs-producer-manifests-shape.yaml`
  - `plan/issues/linux-headless-spec-gaps-2026-05-27.md`
  - `plan/issues/linux-next-work-queue-2026-05-25.md`
- expected_evidence:
  - `litmus:external-logs-layer-shape` still passes.
  - `litmus:external-logs-manifest-shape` still passes.
  - `external-logs-layer` metadata reflects the already-bound manifest litmus and no longer advertises stale 67% coverage.
- next_action: >
    Align the external-logs-layer spec and litmus binding metadata with the
    existing `litmus:external-logs-manifest-shape` test, then run the target
    litmus chain.
- events:
  - type: claim
    ts: `2026-06-02T18:25:36Z`
    agent_id: `linux-macuahuitl-codex-2026-06-02T182536Z`
    host: linux
    lease_id: `f6f17a60a253`
    expires_at: `2026-06-02T22:25:36Z`
  - type: completed
    ts: `2026-06-02T18:28:02Z`
    agent_id: `linux-macuahuitl-codex-2026-06-02T182536Z`
    host: linux
    lease_id: `f6f17a60a253`
    evidence_refs:
      - `./scripts/run-litmus-test.sh external-logs-layer --size instant` — 3/3 PASS, including new `litmus:external-logs-producer-manifests-shape`
      - `./build.sh --check` — PASS
      - `cargo fmt --all -- --check` — FAILED on pre-existing Rust formatting drift in `crates/tillandsias-headless/src/main.rs` and `crates/tillandsias-headless/src/vault_bootstrap.rs`; this packet did not touch Rust files and did not apply unrelated formatting.

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
  e2e litmus gained three structural assertions: ≥1 `state=running`
  line, zero `state=failed` lines, AND `stage=forge state=running`
  specifically (the agent JSON would otherwise be untrustworthy if no
  forge container was actually launched). This fulfills "leverage
  `tillandsias ... --diagnostics` to extract meaningful structured
  results" — both the JSON capability report AND the launch-event
  stream now ride one forge launch per cycle.
- **USER PRIORITY (a) AMPLIFIED**: `scripts/distill-forge-diagnostics.sh`
  now reads the stderr companion and adds a "Container-Start Stream"
  section to each `plan/diagnostics/<basename>-summary.md` with total
  launch events, count by state (running/failed), distinct stage→state
  pairings, and any failed-launch lines verbatim. Three integration
  tests run against fixtures (healthy / failed / empty stderr) all
  produce the expected sections. The orchestrator now sees
  container-start health forensics in the same durable record as the
  capability report.
- **GAP 3 PHASE-1 PINNING**: new instant-phase litmus
  `litmus-runtime-diagnostics-typed-events-shape` greps for the four
  staged formatter functions + their wire-shape literals + the
  `DiagnosticsFilter::global()` gate + the four unit-test names. The
  formatters are still `#[allow(dead_code)]` ahead of the gap-2/3
  phase-2 wiring slice; this litmus surfaces any rename or accidental
  deletion before the wiring lands. Six grep-based steps, all green
  on linux-next HEAD.
- **GAP 5 PHASE-1 PINNING**: companion litmus
  `litmus-diagnostics-filter-env-shape` greps the
  `DiagnosticsFilter` env-var contract (`TILLANDSIAS_DEBUG_FILTER`/
  `_CONTAINER`/`_LEVEL`), the `"verbose"` keyword + `event:internal_*`
  prefix, the public API (`pass_through`/`new`/`from_env`/`global`/
  `allows`), the eight spec-scenario unit tests, and the `OnceLock`
  cache. Catches env-var renames that would silently break user-
  visible filter behaviour without breaking any constructor-based
  unit test. Seven grep-based steps, all green on linux-next HEAD.
- **GAP 3 PHASE-2A** (records-sink surface): `PodmanEventStream`
  gained a `stream_records(tx: mpsc::Sender<ContainerLifecycleRecord>)`
  public method — lossless sibling of the existing
  `stream(tx: mpsc::Sender<PodmanEvent>)`. Internal `stream_events` /
  `stream_events_wsl` / `backoff_inspect` generalised on
  `T: From<ContainerLifecycleRecord> + Send + 'static` so both public
  entry points share the same retry/backoff/fall-back machinery.
  Reflexive `T: From<T>` makes the records case a free no-op conversion;
  PodmanEvent path is unchanged. A compile-pinning unit test asserts
  the records-sink signature stays compatible. This is the channel
  surface the gap-3 phase-2 diagnostics-stream emitter slice will
  consume (records → `format_container_exit_event`/etc. →
  `emit_diagnostic_event`).
- **GAP 3 PHASE-2B** (routing helper): new module
  `crates/tillandsias-podman/src/diagnostic_event_emitter.rs` glues
  the records-sink (phase-2a) to the staged formatters (phase-1) and
  the global filter (gap-5 phase-1). Public:
  `spawn_diagnostic_event_emitter(enabled: bool, prefix: &str)` —
  returns `Some(JoinHandle)` when `enabled` so the caller (next
  slice: `run_opencode_mode`) can abort on shutdown; `None` and zero
  cost when disabled. Today routes `ContainerLifecycleAction::Died →
  format_container_exit_event` (with `exit_code` from the podman
  events payload; `duration_seconds=None` until start→exit pairing
  state lands). Signal/resource/stderr arms documented as deferred
  (signal: podman's `Status=kill` records the request, not the
  delivered signal; resource: needs `Status=oom` parse extension;
  stderr: belongs on the per-container `podman logs -f` tail path,
  not the events stream). Three unit tests cover disabled-path,
  Died-with-and-without-exit-code routing, and exhaustive lifecycle-
  action coverage so future variants must be considered.
- **GAP 3 PHASE-2C** (live wiring): `run_opencode_mode` now spawns
  `spawn_diagnostic_event_emitter(debug, "tillandsias-")` at the top
  of its podman-runtime block and aborts the handle after the
  foreground forge exits. The next `--diagnostics` capture should
  carry real `event:container_exit container=tillandsias-…
  exit_code=…` lines in the `.stderr.log` companion — surfaced in
  the distill "Container-Start Stream" section that the orchestrator
  reads from `plan/diagnostics/`.
  ALSO (later slice): `run_observatorium_mode` got the same phase-2c
  + phase-2g wiring inside its `rt.block_on` — spawning
  `spawn_diagnostic_event_emitter` and a typed-stderr
  `DiagnosticsHandle` on `[tillandsias-router, observatorium_name]`.
  Caveat: the block_on closes BEFORE the synchronous
  `wait_for_observatorium_http_ready` and `launch_observatorium_
  browser` calls, so chromium-core / chromium-framework container
  events are NOT captured by this slice. A follow-on slice could
  raise the emitter to a higher scope. Litmus
  `litmus-runtime-diagnostics-emitter-shape` extended with a step
  that asserts both forge-launching modes wire both helpers (counts
  must be ≥ 2 each).
- **GAP 3 PHASE-2D** (OOM event): added
  `ContainerLifecycleAction::Oom` to the parser action table and the
  `Display` impl; `parse_podman_lifecycle_record` now maps
  `Status=oom` → `(Oom, ContainerState::Stopped)`. The diagnostic
  event emitter routes Oom → `format_resource_exhaustion_event` with
  `resource=memory_oom`, `limit_bytes=None` (podman events don't
  carry the cgroup limit; a follow-on inspect-lookup could fill it).
  Two new unit tests: parser maps `Status=oom` correctly, and the
  emitter routes Oom without panicking. The non-routing exhaustive
  test was updated to reflect that Died+Oom both now route.
- **GAP 3 PHASE-2E** (duration_seconds): start→exit pairing landed.
  `EmitterState` carries a `HashMap<container_name, observed_at>`
  populated by Started records and consumed by Died records to
  compute `duration_seconds=(end-start)`. Entries are evicted on
  Died, Removed, or CleanedUp so `--rm` containers don't leak.
  Died without a prior Started cleanly emits `duration_seconds=None`
  — never fabricated. Five new unit tests cover the pairing
  contract: Started records observed_at; Died computes duration +
  evicts; Died-without-Started reports None; Removed/CleanedUp
  evict; multiple containers tracked independently.
- **GAP 3 PHASE-2F** (signal extraction): signal-induced Died routes
  through `event:container_signal` BEFORE `event:container_exit`.
  POSIX convention: exit code `128 + signal_num` → the signal was
  delivered. New `signal_name_from_exit_code(code) -> Option<String>`
  maps the common signals (SIGINT/SIGABRT/SIGKILL/SIGSEGV/SIGPIPE/
  SIGALRM/SIGTERM) to canonical names and falls back to `SIG<n>` for
  anything outside the well-known set; clean-exit codes (0..=128)
  and out-of-range codes return None. The exit line still follows
  with the original exit_code + duration_seconds, so a downstream
  consumer sees BOTH facts: which signal precipitated the death AND
  the resulting exit code + duration. Four new unit tests pin the
  mapping (common signals, numeric fallback, clean-exit None,
  out-of-range None) plus a no-panic test for the routed path.
- **GAP 3 PHASE-2G** (container_stderr): new
  `DiagnosticsHandle::start_typed_event_stream(container_names) ->
  Self` in `diagnostics_stream.rs` — sibling of the existing
  human-format `start()`. Each accepted container gets a
  `podman logs -f` follow task forwarding lines through
  `format_container_stderr_event` + `emit_diagnostic_event`, so
  every observed log line lands on stderr as
  `[<ISO-8601>] event:container_stderr container=<name>
  line="<escaped>"` and rides the DiagnosticsFilter env-var gates
  (gap-5 phase-1). Wired into `run_opencode_mode` immediately after
  the inference container launches, on the SUPPORT containers
  (router/proxy/git/inference). The foreground forge is excluded
  because it's served attached to the user's terminal by
  `run_container_attached_observed` and tailing it here would
  double-print. `DiagnosticsHandle::Drop` aborts every spawned tail
  on closure exit (no explicit abort needed). Compile-pinning unit
  test asserts the signature stays compatible.
WITH this, the 6-arm gap-3 typed-event chain is COMPLETE:
  1. container_launch (emit_launch_event, gap-3 phase-1)
  2. container_exit (Died → format_container_exit_event, phases
     1b + 2c + 2e)
  3. container_signal (signal-range exit_code, phase-2f)
  4. resource_exhaustion (Oom → format_resource_exhaustion_event,
     phase-2d)
  5. container_stderr (DiagnosticsHandle typed tail, phase-2g)
  6. internal_* (verbose level via DiagnosticsFilter, gap-5 phase-1)
- **GAP 7 GRACEFUL SHUTDOWN** (implementation + verification):
Implementation of the `graceful-shutdown` spec in `tillandsias-headless`.
- Wire `graceful_shutdown_async` into the tray's `run_tray_mode_with_debug` exit path.
- Update `MenuCommand::Quit` (id 31) in `tray/mod.rs` to flip the shutdown atomic instead of `std::process::exit(0)`.
- Implement container stop-and-wait in `graceful_shutdown_async` using `PodmanClient`.
- Implement verification phase polling `podman ps --filter name=tillandsias-` with 30s timeout and SIGKILL fallback.
- Closes the 67→100 gap for `app-lifecycle` and `graceful-shutdown` specs on Linux.
- Status: claimed.
- Events:
  - type: claim
    ts: "2026-06-02T19:15:00Z"
    agent_id: "linux-tillandsia-gemini-cli-20260602T1912"
    host: "linux"
    lease_id: "lease-linux-graceful-shutdown-implementation-20260602T1912"
    expires_at: "2026-06-02T23:15:00Z"

## Lease note
  `litmus-runtime-diagnostics-emitter-shape` greps the
  emitter-layer surfaces (`spawn_diagnostic_event_emitter`,
  `EmitterState { start_times: HashMap<String, i64> }`,
  `signal_name_from_exit_code` + the canonical signal names,
  the five routing arms by `ContainerLifecycleAction::*` literal,
  `start_typed_event_stream` + its `format_container_stderr_event`
  bridge + the `event:container_stderr` literal, and the
  `run_opencode_mode` wiring calls). Seven grep steps catch a
  formatter rename, a routing-arm deletion, or a missing wiring
  call that the formatter-shape litmus would miss. Companion to
  the existing `litmus-runtime-diagnostics-typed-events-shape`
  (formatter layer) and `litmus-diagnostics-filter-env-shape`
  (env-var layer).
- **GAP 5 PHASE-2** (ring buffer + backpressure log): the records
  channel in `run_emitter` is now sized at 10 000 per
  spec:runtime-diagnostics-stream "Terminal blocked" max. A new
  `BackpressureMeter { threshold, above: bool }` watches the in-
  flight depth (`capacity - sender.capacity()`) on every recv;
  when the depth crosses 100 (rising edge only, per spec "Event
  rate limit") it emits a single `warn` line with
  `event_buffer_depth = N`. State machine pinned by three unit
  tests: rising-crossing logs once, sustained-high stays quiet,
  drop-then-rise logs again; `depth = threshold` is NOT "above"
  (strict `> 100`); depth=0 is silent (guards integer
  underflow). spec permits dropping oldest on overflow but does
  not require it — tokio mpsc's await-on-full is the simpler
  honest backpressure signal.
- **PRODUCTION VALIDATION 2026-05-28T19:02Z**: the local annex
  capture at `target/forge-diagnostics/diagnostics_20260528T190248Z.
  stderr.log` confirms gap-3 phase-2g `event:container_stderr` is
  shipping real spec-shape lines under `--diagnostics`:
  `[<ISO-8601>] event:container_stderr container=tillandsias-proxy
  line="…"`. 115 stderr lines across two support containers
  (`tillandsias-proxy` × 107, `tillandsias-git-…` × 8). No exits/
  signals/oom because the support set is long-running. The earlier
  18:42Z capture has zero typed-event-2g lines (pre-deployment),
  so the binary cutover happened between those two runs.
  Companion slice: `scripts/distill-forge-diagnostics.sh` now
  surfaces ALL 5 typed-event arms in a "Typed-event arms" table
  with sample lines for exit/signal/resource and a top-5
  noisiest-by-container table for stderr — so the orchestrator
  reads these from the durable `plan/diagnostics/` summaries
  instead of having to chase the raw `target/forge-diagnostics/`
  logs that don't propagate across hosts. Also fixed a
  pre-existing `set -euo pipefail` abort in distill when the raw
  log is empty (grep no-match on `^TIMESTAMP=` would crash before
  any summary was written).
  (Next diagnostics gap: GAP 2 / GAP 3 PHASE-2 — wire the live podman
  events parser to emit_diagnostic_event when `debug` is on.)

## Lease note
The forge-diagnostics PACKET (annex/prompt/distill) is leased by `pickie`; items
1–5 above are headless/podman-crate diagnostics IMPLEMENTATION (different files),
not that packet. Items here are linux-host owned.
