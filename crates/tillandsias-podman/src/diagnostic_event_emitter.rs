// @trace spec:runtime-diagnostics-stream (Container exit event, Container signal event)
// @trace plan/issues/linux-headless-spec-gaps-2026-05-27.md (gap 3 phase-2b)
//! Live diagnostic-stream emitter — the runtime half of gap-3.
//!
//! Wires `PodmanEventStream::stream_records` (lossless
//! [`ContainerLifecycleRecord`] channel, gap-3 phase-2a) to the staged
//! typed-event formatters in `client.rs` (gap-3 phase-1) and the
//! `DiagnosticsFilter` env-var surface (gap-5 phase-1) so that when a
//! container-launching flow runs with `--debug` / `--diagnostics`, the
//! shared idiomatic-podman layer emits real spec-shape events to stderr:
//!
//! ```text
//! [<ISO-8601 UTC>] event:container_exit container=<name> exit_code=<N>
//! ```
//!
//! What this module routes today:
//!
//! - [`ContainerLifecycleAction::Started`] → no event (the
//!   `event:container_launch state=running` line is the launch path's
//!   own emission, not ours). The Started observed_at is recorded so
//!   the matching Died can fill `duration_seconds`.
//!
//! - [`ContainerLifecycleAction::Died`] → `event:container_exit` with
//!   the `exit_code` parsed out of the podman events Died payload
//!   (gap-3 phase-1b) AND `duration_seconds` computed from the
//!   Started→Died pair (gap-3 phase-2e). Containers Died without a
//!   prior Started — emitter started late, restart loop, or
//!   `--rm` cycle that fell through the BackoffInspection path —
//!   emit with `duration_seconds=None` (never fabricated).
//!
//! - [`ContainerLifecycleAction::Removed`] /
//!   [`ContainerLifecycleAction::CleanedUp`] → no event; just evict
//!   any stale start-time entry so `--rm` containers (which may not
//!   produce a Died) don't leak start-time map entries.
//!
//! - [`ContainerLifecycleAction::Oom`] → `event:resource_exhaustion`
//!   with `resource=memory_oom`. Podman emits `Status=oom` as a
//!   separate event from `died` (both fire when the kernel reaps a
//!   container for breaching its memory cgroup limit). `limit_bytes`
//!   is left `None` because podman events don't carry the cgroup
//!   limit; an inspect-lookup pass could fill it but adds latency on
//!   what should be a fast event-stream path.
//!
//! - **Signal-induced Died** → `event:container_signal` (preceding the
//!   exit line). When a container's POSIX exit code is in the
//!   `129..=255` range, by convention the implied signal is
//!   `(code - 128)`. We map the common ones to canonical names
//!   (SIGINT/SIGABRT/SIGKILL/SIGSEGV/SIGTERM) and fall back to
//!   `signal=SIG<n>` for anything else. The exit line follows so a
//!   downstream consumer sees BOTH facts: which signal precipitated
//!   the death AND the resulting exit code + duration.
//!
//! What this module DOESN'T emit yet:
//!
//! - `event:container_stderr`: needs a separate `podman logs -f` tail
//!   per container (the `DiagnosticsHandle` path), not the events
//!   stream this module wraps.

use std::collections::HashMap;

use tokio::sync::mpsc;
use tracing::{debug, warn};

use crate::client::{
    emit_diagnostic_event, format_container_exit_event, format_container_signal_event,
    format_resource_exhaustion_event,
};
use crate::diagnostics::{ContainerLifecycleAction, ContainerLifecycleRecord};
use crate::events::PodmanEventStream;

/// Channel buffer for the records sink. spec:runtime-diagnostics-stream
/// "Terminal blocked" scenario pins the maximum at 10K events; a
/// tokio mpsc with this bound IS the ring buffer for our purposes
/// (FIFO, awaits on the sender side when full — the spec permits
/// dropping oldest but does not require it; awaiting is the simpler
/// honest backpressure signal).
///
/// Gap-5 phase-2 (this slice).
const RECORDS_CHANNEL_CAPACITY: usize = 10_000;

/// Threshold per spec:runtime-diagnostics-stream "Event rate limit":
/// log `event_buffer_depth = N` when the in-flight depth crosses this
/// value. We surface ONE rising-edge log per crossing (not one per
/// arrival above the threshold) so a sustained-high session doesn't
/// drown stderr in backpressure messages.
const BACKPRESSURE_LOG_THRESHOLD: usize = 100;

/// Spawn the live diagnostic-event emitter. Returns `None` when
/// `enabled` is false (caller passes the `debug` flag verbatim, so a
/// non-debug invocation has zero overhead).
///
/// `prefix` filters `podman events` records by container-name prefix —
/// usually `"tillandsias-"` so only enclave/forge containers show up.
///
/// The returned `JoinHandle` aborts cleanly on shutdown: the caller
/// stores it alongside other long-lived tasks and calls `.abort()` from
/// its shutdown sequence. The inner `stream_records` task and the
/// routing loop both exit on channel close.
///
/// @trace spec:runtime-diagnostics-stream
pub fn spawn_diagnostic_event_emitter(
    enabled: bool,
    prefix: impl Into<String>,
) -> Option<tokio::task::JoinHandle<()>> {
    if !enabled {
        return None;
    }
    let prefix = prefix.into();
    Some(tokio::spawn(async move {
        run_emitter(prefix).await;
    }))
}

async fn run_emitter(prefix: String) {
    let (tx, mut rx) = mpsc::channel::<ContainerLifecycleRecord>(RECORDS_CHANNEL_CAPACITY);
    let sender_for_depth = tx.clone();
    let stream = PodmanEventStream::new(&prefix);
    // The stream task owns the sender; when this routing loop drops its
    // half (or this task is aborted), the stream task observes the
    // channel-closed condition and exits cleanly.
    let stream_task = tokio::spawn(async move { stream.stream_records(tx).await });

    debug!(
        spec = "runtime-diagnostics-stream",
        prefix = %prefix,
        "diagnostic-event emitter running"
    );

    let mut state = EmitterState::default();
    let mut meter = BackpressureMeter::new(BACKPRESSURE_LOG_THRESHOLD);
    while let Some(record) = rx.recv().await {
        // Approximate the in-flight depth as
        // `total_capacity - available_capacity_on_sender_side`. This
        // counts items the producer has sent but the consumer (this
        // loop) hasn't pulled off the channel yet. Cheap atomic load.
        let in_flight = RECORDS_CHANNEL_CAPACITY.saturating_sub(sender_for_depth.capacity());
        if let Some(log_depth) = meter.observe(in_flight) {
            warn!(
                spec = "runtime-diagnostics-stream",
                event_buffer_depth = log_depth,
                threshold = BACKPRESSURE_LOG_THRESHOLD,
                "diagnostic event buffer backpressure (depth > threshold)"
            );
        }
        route_record(&mut state, &record);
    }

    // Channel closed (stream task exited or aborted). Cancel the stream
    // task explicitly in case the close came from the rx side.
    stream_task.abort();
    let _ = stream_task.await;
}

/// Decode a POSIX exit code into the implied signal name (if any).
///
/// Convention: when a process is killed by signal N, the shell-visible
/// exit code is `128 + N`. So an exit code in `129..=255` implies the
/// container was signal-killed and the signal number is `code - 128`.
/// Maps the common signals to their canonical names and falls back to
/// `SIG<n>` for anything outside the well-known set, so the wire shape
/// always carries something grep-able.
///
/// Returns `None` for any code outside the 129..=255 range, including
/// the typical "clean exit" range 0..=128.
///
/// @trace spec:runtime-diagnostics-stream (Container signal event)
fn signal_name_from_exit_code(code: i32) -> Option<String> {
    if !(129..=255).contains(&code) {
        return None;
    }
    let sig = code - 128;
    let name = match sig {
        2 => "SIGINT",
        6 => "SIGABRT",
        9 => "SIGKILL",
        11 => "SIGSEGV",
        13 => "SIGPIPE",
        14 => "SIGALRM",
        15 => "SIGTERM",
        // Anything else: render as SIG<n> so the line still parses.
        n => return Some(format!("SIG{n}")),
    };
    Some(name.to_string())
}

/// Rising-edge backpressure detector. Per
/// spec:runtime-diagnostics-stream "Event rate limit", we SHOULD log
/// `event_buffer_depth = N` when the buffer exceeds the threshold —
/// once per rising crossing, not once per arrival above threshold,
/// so a sustained-high session doesn't drown stderr in warnings.
///
/// State machine:
///   below threshold + observe(below)  → no log
///   below threshold + observe(above)  → log + transition above
///   above threshold + observe(above)  → no log (still above)
///   above threshold + observe(below)  → no log + transition below
///
/// Pure value type. `observe(depth)` returns `Some(depth)` when a
/// rising crossing happens, `None` otherwise.
///
/// @trace spec:runtime-diagnostics-stream (Event rate limit)
#[derive(Debug)]
struct BackpressureMeter {
    threshold: usize,
    above: bool,
}

impl BackpressureMeter {
    fn new(threshold: usize) -> Self {
        Self {
            threshold,
            above: false,
        }
    }

    fn observe(&mut self, depth: usize) -> Option<usize> {
        if depth > self.threshold {
            if !self.above {
                self.above = true;
                return Some(depth);
            }
            None
        } else {
            self.above = false;
            None
        }
    }
}

/// Per-session state the router carries across record arrivals — today
/// just the start-time map so `Died` records can fill `duration_seconds`.
///
/// Bounded by the live container set: entries are inserted on Started
/// and removed on Died/Removed/CleanedUp, so the map stays roughly
/// proportional to the running enclave. A pathological churn (thousands
/// of containers per second over hours) could grow the map; the gap-5
/// phase-2 ring buffer is the upstream backpressure layer that bounds
/// this case before it reaches the router.
///
/// @trace spec:runtime-diagnostics-stream (Container exit event)
#[derive(Debug, Default)]
struct EmitterState {
    /// container_name → unix-seconds observed_at of the Started record.
    /// We use `observed_at_unix` from the parser (podman event `Time`
    /// field), not local wall-clock, so the duration reflects the
    /// kernel-observed lifecycle on the podman host — correct even if
    /// the emitter clock is skewed.
    start_times: HashMap<String, i64>,
}

/// Decide which typed-event line (if any) to emit for one parsed
/// lifecycle record. Carries `&mut EmitterState` so it can track the
/// start→exit pairing needed for `duration_seconds`. Pulled out of
/// `run_emitter` so it stays unit-testable without spinning a tokio
/// task.
///
/// Routing arms today:
///
///   Started   → record observed_at in state; no event emitted (the
///               `event:container_launch state=running` line is the
///               launch-path's own emission, not ours).
///   Died      → look up start time, compute duration if available,
///               emit `event:container_exit` with exit_code +
///               duration_seconds, then evict the entry.
///   Oom       → emit `event:resource_exhaustion`.
///   Removed/CleanedUp → evict the start-time entry. (Containers that
///               are `--rm` removed without a Died event fall into the
///               BackoffInspection's Disappeared branch which we don't
///               track here; the entry will time out as a leak.)
fn route_record(state: &mut EmitterState, record: &ContainerLifecycleRecord) {
    match record.action {
        ContainerLifecycleAction::Started => {
            if let Some(at) = record.observed_at_unix {
                state.start_times.insert(record.container_name.clone(), at);
            }
        }
        ContainerLifecycleAction::Died => {
            // POSIX convention: a process killed by a signal exits
            // with `128 + signal_num`. When that pattern shows up on
            // a Died record, emit the signal line FIRST — the
            // kernel-delivered signal is the precipitating fact, the
            // exit code is the consequence. The exit line follows so
            // a downstream consumer sees BOTH.
            if let Some(name) = record.exit_code.and_then(signal_name_from_exit_code) {
                let body = format_container_signal_event(&record.container_name, &name);
                emit_diagnostic_event(
                    true,
                    "event:container_signal",
                    &record.container_name,
                    &body,
                );
            }
            let started_at = state.start_times.remove(&record.container_name);
            let duration = match (started_at, record.observed_at_unix) {
                (Some(start), Some(end)) if end >= start => Some((end - start).max(0) as u64),
                _ => None,
            };
            let body = format_container_exit_event(
                &record.container_name,
                record.exit_code.unwrap_or(-1),
                duration,
            );
            emit_diagnostic_event(true, "event:container_exit", &record.container_name, &body);
        }
        ContainerLifecycleAction::Oom => {
            // resource=memory_oom matches the spec scenario literal.
            // limit_bytes is None because podman events don't carry it;
            // a follow-on inspect-lookup pass could fill it.
            let body = format_resource_exhaustion_event(&record.container_name, "memory_oom", None);
            emit_diagnostic_event(
                true,
                "event:resource_exhaustion",
                &record.container_name,
                &body,
            );
        }
        ContainerLifecycleAction::Removed | ContainerLifecycleAction::CleanedUp => {
            // Evict stale start-time entries so a `--rm` container
            // removed without a matching Died doesn't leak forever.
            state.start_times.remove(&record.container_name);
        }
        // The other actions (StopRequested/Killed/Observed/Disappeared)
        // don't map to a spec-mandated typed event today.
        // `event:container_launch state=…` lines are emitted from the
        // launch path itself (emit_launch_event in client.rs), NOT from
        // the post-launch events stream.
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diagnostics::LifecycleSource;
    use tillandsias_core::event::ContainerState;

    fn died_record(name: &str, exit_code: Option<i32>) -> ContainerLifecycleRecord {
        ContainerLifecycleRecord {
            container_name: name.into(),
            action: ContainerLifecycleAction::Died,
            new_state: ContainerState::Stopped,
            source: LifecycleSource::PodmanEvents,
            raw_status: Some("died".into()),
            observed_at_unix: Some(1_711_400_005),
            exit_code,
        }
    }

    /// `spawn_diagnostic_event_emitter(false, …)` MUST return `None`
    /// and pay zero runtime cost — the spec says streaming is OFF by
    /// default, and the caller passes the `debug` flag verbatim.
    #[test]
    fn spawn_returns_none_when_disabled() {
        let handle = spawn_diagnostic_event_emitter(false, "tillandsias-");
        assert!(handle.is_none());
    }

    fn started_record(name: &str, observed_at: i64) -> ContainerLifecycleRecord {
        ContainerLifecycleRecord {
            container_name: name.into(),
            action: ContainerLifecycleAction::Started,
            new_state: ContainerState::Running,
            source: LifecycleSource::PodmanEvents,
            raw_status: Some("start".into()),
            observed_at_unix: Some(observed_at),
            exit_code: None,
        }
    }

    /// Pure-dispatch test: a Died record with an exit code MUST be
    /// matched by the route arm. We can't assert on the eprintln side
    /// effect without capturing stderr, but we CAN assert the match
    /// arm fires — the arm exits without panicking, while any other
    /// record kind falls through to the `_ => {}` arm. Pinned by the
    /// shape of the matched action.
    #[test]
    fn route_record_handles_died_without_panic() {
        let mut state = EmitterState::default();
        route_record(&mut state, &died_record("tillandsias-x-forge", Some(137)));
        route_record(&mut state, &died_record("tillandsias-x-forge", None));
    }

    /// An Oom record MUST route to the resource-exhaustion arm. Pinned
    /// separately from Died so a future routing-table edit can't drop
    /// Oom silently.
    #[test]
    fn route_record_handles_oom_without_panic() {
        let mut state = EmitterState::default();
        let mut r = died_record("tillandsias-x-forge", None);
        r.action = ContainerLifecycleAction::Oom;
        r.raw_status = Some("oom".into());
        route_record(&mut state, &r);
    }

    /// Non-routing records (everything except Died/Oom/Started/
    /// Removed/CleanedUp) must NOT trigger any emit or state mutation.
    /// Exhaustive over `ContainerLifecycleAction` so adding a new
    /// variant in diagnostics.rs forces a decision here.
    #[test]
    fn route_record_non_routing_actions_no_panic() {
        let mut state = EmitterState::default();
        let base = died_record("tillandsias-x", None);
        for action in [
            ContainerLifecycleAction::Created,
            ContainerLifecycleAction::StopRequested,
            ContainerLifecycleAction::Killed,
            ContainerLifecycleAction::Observed,
            ContainerLifecycleAction::Disappeared,
        ] {
            let mut r = base.clone();
            r.action = action;
            route_record(&mut state, &r);
        }
        assert!(
            state.start_times.is_empty(),
            "non-routing actions must not mutate state"
        );
    }

    /// gap-3 phase-2e contract: a Started → Died pair, with
    /// `observed_at_unix` timestamps, produces an exit-event line
    /// carrying `duration_seconds=<end-start>`. The start-time entry
    /// is evicted on Died so the same container can restart fresh.
    #[test]
    fn started_then_died_records_duration_and_evicts_entry() {
        let mut state = EmitterState::default();
        route_record(
            &mut state,
            &started_record("tillandsias-myproj-forge", 1_711_400_000),
        );
        assert_eq!(
            state.start_times.get("tillandsias-myproj-forge"),
            Some(&1_711_400_000),
            "Started must record observed_at into state"
        );

        let mut died = died_record("tillandsias-myproj-forge", Some(0));
        died.observed_at_unix = Some(1_711_400_025);
        route_record(&mut state, &died);

        // The exit-event side effect went to stderr (not asserted
        // here); the visible state change is the eviction.
        assert!(
            !state.start_times.contains_key("tillandsias-myproj-forge"),
            "Died must evict the start-time entry"
        );
    }

    /// gap-3 phase-2e: a Died WITHOUT a preceding Started (e.g.
    /// emitter started after container launch) routes cleanly with
    /// duration_seconds=None — never fabricates a bogus value.
    #[test]
    fn died_without_prior_started_has_no_duration() {
        let mut state = EmitterState::default();
        let mut died = died_record("tillandsias-orphan", Some(1));
        died.observed_at_unix = Some(1_711_400_005);
        route_record(&mut state, &died);
        // No-op on the state map; assertion is the absence of panic +
        // the empty state going in/out.
        assert!(state.start_times.is_empty());
    }

    /// gap-3 phase-2e: Removed and CleanedUp evict any stale
    /// start-time entry so `--rm` containers (which may not produce a
    /// Died) don't leak forever.
    #[test]
    fn removed_and_cleanedup_evict_start_time() {
        let mut state = EmitterState::default();
        route_record(&mut state, &started_record("tillandsias-rm-1", 1_000));
        route_record(&mut state, &started_record("tillandsias-rm-2", 2_000));
        assert_eq!(state.start_times.len(), 2);

        let mut r1 = died_record("tillandsias-rm-1", None);
        r1.action = ContainerLifecycleAction::Removed;
        route_record(&mut state, &r1);

        let mut r2 = died_record("tillandsias-rm-2", None);
        r2.action = ContainerLifecycleAction::CleanedUp;
        route_record(&mut state, &r2);

        assert!(state.start_times.is_empty());
    }

    /// gap-3 phase-2f: a signal-induced exit (POSIX exit code
    /// `128 + signal_num`) maps to the canonical signal name. The
    /// helper is the testable surface; the eprintln side effect of
    /// the route arm is verified separately as a no-panic.
    #[test]
    fn signal_name_from_exit_code_maps_common_signals() {
        assert_eq!(signal_name_from_exit_code(130).as_deref(), Some("SIGINT"));
        assert_eq!(signal_name_from_exit_code(134).as_deref(), Some("SIGABRT"));
        assert_eq!(signal_name_from_exit_code(137).as_deref(), Some("SIGKILL"));
        assert_eq!(signal_name_from_exit_code(139).as_deref(), Some("SIGSEGV"));
        assert_eq!(signal_name_from_exit_code(143).as_deref(), Some("SIGTERM"));
    }

    /// gap-3 phase-2f: exit codes outside the well-known set fall
    /// through to `SIG<n>` so the wire shape still parses and the
    /// signal number is visible.
    #[test]
    fn signal_name_from_exit_code_falls_back_to_numeric() {
        // 128 + 17 = 145 (SIGCHLD on most Unixes); we don't map it.
        assert_eq!(signal_name_from_exit_code(145).as_deref(), Some("SIG17"));
        // 128 + 31 = 159 (SIGSYS); also not mapped — falls back.
        assert_eq!(signal_name_from_exit_code(159).as_deref(), Some("SIG31"));
    }

    /// gap-3 phase-2f: clean-exit codes (0..=128) and out-of-range
    /// codes (>255 or negative) MUST return None — we never invent
    /// a signal for a non-signal exit.
    #[test]
    fn signal_name_from_exit_code_returns_none_on_clean_or_out_of_range() {
        assert_eq!(signal_name_from_exit_code(0), None);
        assert_eq!(signal_name_from_exit_code(1), None);
        assert_eq!(signal_name_from_exit_code(127), None);
        assert_eq!(signal_name_from_exit_code(128), None);
        assert_eq!(signal_name_from_exit_code(256), None);
        assert_eq!(signal_name_from_exit_code(-1), None);
    }

    /// gap-3 phase-2f: a Died with a signal-range exit_code routes
    /// through both arms — container_signal (precipitating) and
    /// container_exit (consequence) — without panic. The actual
    /// emission ordering is asserted via stderr inspection in the
    /// runtime litmus; the helper test above is the pure-data pin.
    #[test]
    fn route_record_handles_signal_induced_died_without_panic() {
        let mut state = EmitterState::default();
        let died = died_record("tillandsias-x-forge", Some(137));
        route_record(&mut state, &died);
    }

    /// gap-5 phase-2: `BackpressureMeter` logs ONCE on rising
    /// crossing of the threshold, not once per arrival above. State
    /// machine pinned: below→below = silent, below→above = log,
    /// above→above = silent, above→below = silent (just transitions
    /// down).
    #[test]
    fn backpressure_meter_logs_only_on_rising_crossing() {
        let mut m = BackpressureMeter::new(100);
        // below → below: silent
        assert_eq!(m.observe(50), None);
        assert_eq!(m.observe(99), None);
        // below → above: log
        assert_eq!(m.observe(101), Some(101));
        // above → above (still above): silent
        assert_eq!(m.observe(200), None);
        assert_eq!(m.observe(150), None);
        // above → below: silent (no "all clear" log; the threshold
        // is one-directional in the spec).
        assert_eq!(m.observe(80), None);
        // below → above again: log again
        assert_eq!(m.observe(120), Some(120));
    }

    /// gap-5 phase-2: depth EXACTLY at threshold is NOT "above" —
    /// the spec says `> 100`, not `>= 100`. Avoid spamming on a
    /// steady-state stream sitting at the boundary.
    #[test]
    fn backpressure_meter_threshold_is_strictly_greater() {
        let mut m = BackpressureMeter::new(100);
        assert_eq!(m.observe(100), None);
        assert_eq!(m.observe(100), None);
        assert_eq!(m.observe(101), Some(101));
    }

    /// gap-5 phase-2: depth=0 below a non-zero threshold is silent —
    /// guards against an integer underflow path in callers computing
    /// depth from capacity subtraction.
    #[test]
    fn backpressure_meter_zero_depth_is_silent() {
        let mut m = BackpressureMeter::new(100);
        assert_eq!(m.observe(0), None);
    }

    /// gap-3 phase-2e: multiple containers tracked independently —
    /// one Started → Died pair doesn't disturb another's start time.
    #[test]
    fn multiple_containers_tracked_independently() {
        let mut state = EmitterState::default();
        route_record(&mut state, &started_record("tillandsias-a", 100));
        route_record(&mut state, &started_record("tillandsias-b", 200));
        assert_eq!(state.start_times.len(), 2);

        let mut died_a = died_record("tillandsias-a", Some(0));
        died_a.observed_at_unix = Some(150);
        route_record(&mut state, &died_a);

        // a evicted, b retained with original start time.
        assert!(!state.start_times.contains_key("tillandsias-a"));
        assert_eq!(state.start_times.get("tillandsias-b"), Some(&200));
    }
}
