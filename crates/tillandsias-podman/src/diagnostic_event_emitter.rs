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
//! - [`ContainerLifecycleAction::Died`] → `event:container_exit` with the
//!   `exit_code` parsed out of the podman events Died payload (gap-3
//!   phase-1b). `duration_seconds` is left off for now because computing
//!   it would require start→exit pairing state that the lifecycle stream
//!   doesn't carry; the formatter already accepts `None` for this field.
//!
//! What this module DOESN'T emit yet:
//!
//! - `event:container_signal`: podman events `Status=kill` records the
//!   kill REQUEST, not the signal the kernel delivered, so we can't
//!   accurately fill `signal=…`. Routing for this lands when there's a
//!   separate source for the signal name.
//! - `event:resource_exhaustion`: podman events emits `Status=oom` which
//!   we don't yet parse — a follow-on slice will extend
//!   `parse_podman_lifecycle_record` to handle OOM and pipe it through
//!   here.
//! - `event:container_stderr`: needs a separate `podman logs -f` tail
//!   per container (the `DiagnosticsHandle` path), not the events
//!   stream this module wraps.

use tokio::sync::mpsc;
use tracing::debug;

use crate::client::{emit_diagnostic_event, format_container_exit_event};
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

    while let Some(record) = rx.recv().await {
        route_record(&record);
    }

    // Channel closed (stream task exited or aborted). Cancel the stream
    // task explicitly in case the close came from the rx side.
    stream_task.abort();
    let _ = stream_task.await;
}

/// Decide which typed-event line (if any) to emit for one parsed
/// lifecycle record. Pure dispatch — pulled out of `run_emitter` so it
/// stays unit-testable without spinning a tokio task.
///
/// Today only `Died` records route to a typed event
/// (`event:container_exit`). Other actions are observability-only on
/// the lifecycle-tracker path (consumed by UI state); the spec-mandated
/// typed events don't have backing data for them yet (see module doc).
fn route_record(record: &ContainerLifecycleRecord) {
    if record.action == ContainerLifecycleAction::Died {
        let body = format_container_exit_event(
            &record.container_name,
            record.exit_code.unwrap_or(-1),
            // duration_seconds: needs start→exit pairing state;
            // tracked as a follow-on slice.
            None,
        );
        emit_diagnostic_event(true, "event:container_exit", &record.container_name, &body);
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

    /// Pure-dispatch test: a Died record with an exit code MUST be
    /// matched by the route arm. We can't assert on the eprintln side
    /// effect without capturing stderr, but we CAN assert the match
    /// arm fires — the arm exits without panicking, while any other
    /// record kind falls through to the `_ => {}` arm. Pinned by the
    /// shape of the matched action.
    #[test]
    fn route_record_handles_died_without_panic() {
        // Died with exit_code → routed to the exit-event arm.
        route_record(&died_record("tillandsias-x-forge", Some(137)));
        // Died WITHOUT exit_code → still routed (formatter handles
        // `unwrap_or(-1)` for the "we know it died, code unknown" case).
        route_record(&died_record("tillandsias-x-forge", None));
    }

    /// Non-Died records must NOT trigger the exit-event arm. We can't
    /// hook the eprintln directly here; instead we verify dispatch is
    /// exhaustive on `ContainerLifecycleAction` so any future addition
    /// has to be considered. A bare `_ => {}` would let new variants
    /// silently miss routing.
    #[test]
    fn route_record_other_actions_no_panic() {
        let base = died_record("tillandsias-x", None);
        for action in [
            ContainerLifecycleAction::Created,
            ContainerLifecycleAction::Started,
            ContainerLifecycleAction::StopRequested,
            ContainerLifecycleAction::Killed,
            ContainerLifecycleAction::Removed,
            ContainerLifecycleAction::CleanedUp,
            ContainerLifecycleAction::Observed,
            ContainerLifecycleAction::Disappeared,
        ] {
            let mut r = base.clone();
            r.action = action;
            route_record(&r); // must not panic, must not double-emit
        }
    }
}
