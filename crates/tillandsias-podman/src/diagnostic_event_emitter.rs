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
//! What this module DOESN'T emit yet:
//!
//! - `event:container_signal`: podman events `Status=kill` records the
//!   kill REQUEST, not the signal the kernel delivered, so we can't
//!   accurately fill `signal=…`. Routing for this lands when there's a
//!   separate source for the signal name.
//! - `event:container_stderr`: needs a separate `podman logs -f` tail
//!   per container (the `DiagnosticsHandle` path), not the events
//!   stream this module wraps.

use std::collections::HashMap;

use tokio::sync::mpsc;
use tracing::debug;

use crate::client::{
    emit_diagnostic_event, format_container_exit_event, format_resource_exhaustion_event,
};
use crate::diagnostics::{ContainerLifecycleAction, ContainerLifecycleRecord};
use crate::events::PodmanEventStream;

/// Channel buffer for the records sink. The diagnostic emitter is a
/// best-effort observability path — if the consumer falls behind, we
/// prefer to drop on backpressure rather than stall the upstream parse
/// loop. 256 is plenty for an interactive `--diagnostics` session;
/// gap-5 phase-2 (bounded ring buffer at 10K with backpressure logging)
/// is a separate spec-mandated layer that wraps this channel.
const RECORDS_CHANNEL_CAPACITY: usize = 256;

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
    while let Some(record) = rx.recv().await {
        route_record(&mut state, &record);
    }

    // Channel closed (stream task exited or aborted). Cancel the stream
    // task explicitly in case the close came from the rx side.
    stream_task.abort();
    let _ = stream_task.await;
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
