//! Flow-state event channel and propagation primitives.
//!
//! Provides a first-class message channel mechanism so flow and dependency
//! transitions are observable events across the control-wire backbone.
//!
//! @trace plan/issues/research-flow-state-event-channel-2026-07-23.md
//! @trace plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::broadcast;

use crate::{ControlMessage, FlowSource};

/// Default bounded broadcast capacity for flow-state transition pushes.
///
/// Flow transitions occur at discrete, low-to-moderate frequencies (login steps
/// take seconds; node state transitions occur on container/service lifecycles).
/// Capacity of 64 accommodates bursts from graph evaluation storms (e.g.
/// 7-15 nodes checking simultaneously) with generous headroom for slow
/// subscribers before lag-skip activates.
pub const FLOW_STATE_PUSH_CAPACITY: usize = 64;

/// In-process broadcast channel for emitting and subscribing to [`ControlMessage::FlowStatePush`] events.
///
/// Implements monotonic sequence stamping and bounded fan-out with lag-skip semantics,
/// matching the existing vsock broadcast channels (`VmStatusPush`, `LoginStatePush`, `CloudProjectsPush`).
#[derive(Debug, Clone)]
pub struct FlowEventChannel {
    sender: broadcast::Sender<ControlMessage>,
    seq: Arc<AtomicU64>,
}

impl FlowEventChannel {
    /// Construct a new channel with the specified bounded buffer capacity.
    pub fn new(capacity: usize) -> Self {
        let (sender, _) = broadcast::channel(capacity);
        Self {
            sender,
            seq: Arc::new(AtomicU64::new(1)),
        }
    }

    /// Construct a channel with the canonical default capacity (`FLOW_STATE_PUSH_CAPACITY` = 64).
    pub fn with_default_capacity() -> Self {
        Self::new(FLOW_STATE_PUSH_CAPACITY)
    }

    /// Subscribe to the flow state event stream.
    ///
    /// Each subscriber receives an independent broadcast receiver. Slow consumers
    /// that lag beyond the channel buffer receive [`broadcast::error::RecvError::Lagged`]
    /// and skip to the newest available transition without wedging publishers or other consumers.
    pub fn subscribe(&self) -> broadcast::Receiver<ControlMessage> {
        self.sender.subscribe()
    }

    /// Returns the number of active subscribers.
    pub fn receiver_count(&self) -> usize {
        self.sender.receiver_count()
    }

    /// Emit a state transition event onto the broadcast channel.
    ///
    /// Allocates a monotonic sequence number, creates a [`ControlMessage::FlowStatePush`],
    /// and broadcasts it to all active subscribers. Returns the emitted message.
    pub fn emit(
        &self,
        source: FlowSource,
        from_state: impl Into<String>,
        to_state: impl Into<String>,
        reason: Option<impl Into<String>>,
        ts_unix: u64,
    ) -> ControlMessage {
        let seq = self.seq.fetch_add(1, Ordering::SeqCst);
        let msg = ControlMessage::FlowStatePush {
            seq,
            source,
            from_state: from_state.into(),
            to_state: to_state.into(),
            reason: reason.map(Into::into),
            ts_unix,
        };
        // broadcast::send returns Err when there are 0 active receivers; this is
        // normal and non-fatal for change-gated push notifications.
        let _ = self.sender.send(msg.clone());
        msg
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::FlowSource;

    #[tokio::test]
    async fn incident_observable_collected_but_not_persisted() {
        // Reproduce the motivating incident:
        // A user pastes their PAT during login. The token is collected, but before Vault
        // write can succeed, a pre-requisite fails (e.g. CA bundle or proxy egress down).
        // Under the prior snapshot model, nothing was emitted and the tray hung on "Logging In".
        // With FlowStatePush, the transition to "blocked" is an observable event.

        let channel = FlowEventChannel::with_default_capacity();
        let mut subscriber = channel.subscribe();

        // 1. Initial transition: operator provided token
        let _msg1 = channel.emit(
            FlowSource::Login {
                provider: "github".into(),
            },
            "auth.github.awaiting-operator",
            "auth.github.token-collected",
            None::<&str>,
            1721779200,
        );

        // 2. Incident failure: Vault persist fails due to ca_bundle
        let _msg2 = channel.emit(
            FlowSource::Login {
                provider: "github".into(),
            },
            "auth.github.token-collected",
            "auth.github.blocked",
            Some("persist(ca_bundle)"),
            1721779201,
        );

        // Subscriber observes the first event
        let recv1 = subscriber.recv().await.expect("receive event 1");
        match recv1 {
            ControlMessage::FlowStatePush {
                seq,
                source,
                from_state,
                to_state,
                reason,
                ts_unix,
            } => {
                assert_eq!(seq, 1);
                assert_eq!(
                    source,
                    FlowSource::Login {
                        provider: "github".into()
                    }
                );
                assert_eq!(from_state, "auth.github.awaiting-operator");
                assert_eq!(to_state, "auth.github.token-collected");
                assert_eq!(reason, None);
                assert_eq!(ts_unix, 1721779200);
            }
            other => panic!("expected FlowStatePush, got {other:?}"),
        }

        // Subscriber observes the blocked event with the exact failing stage + reason
        let recv2 = subscriber.recv().await.expect("receive event 2");
        match recv2 {
            ControlMessage::FlowStatePush {
                seq,
                source,
                from_state,
                to_state,
                reason,
                ts_unix,
            } => {
                assert_eq!(seq, 2);
                assert_eq!(
                    source,
                    FlowSource::Login {
                        provider: "github".into()
                    }
                );
                assert_eq!(from_state, "auth.github.token-collected");
                assert_eq!(to_state, "auth.github.blocked");
                assert_eq!(reason, Some("persist(ca_bundle)".into()));
                assert_eq!(ts_unix, 1721779201);
            }
            other => panic!("expected FlowStatePush, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn dependency_node_state_transitions() {
        // Sibling ii: Unified runtime + data dependency graph node transitions.
        let channel = FlowEventChannel::with_default_capacity();
        let mut subscriber = channel.subscribe();

        channel.emit(
            FlowSource::DependencyNode {
                node: "ca_bundle".into(),
            },
            "node.absent",
            "node.satisfying",
            None::<&str>,
            1721779210,
        );

        channel.emit(
            FlowSource::DependencyNode {
                node: "ca_bundle".into(),
            },
            "node.satisfying",
            "node.present",
            None::<&str>,
            1721779215,
        );

        let event1 = subscriber.recv().await.expect("event 1");
        if let ControlMessage::FlowStatePush {
            source,
            from_state,
            to_state,
            ..
        } = event1
        {
            assert_eq!(
                source,
                FlowSource::DependencyNode {
                    node: "ca_bundle".into()
                }
            );
            assert_eq!(from_state, "node.absent");
            assert_eq!(to_state, "node.satisfying");
        } else {
            panic!("unexpected variant");
        }

        let event2 = subscriber.recv().await.expect("event 2");
        if let ControlMessage::FlowStatePush {
            source,
            from_state,
            to_state,
            ..
        } = event2
        {
            assert_eq!(
                source,
                FlowSource::DependencyNode {
                    node: "ca_bundle".into()
                }
            );
            assert_eq!(from_state, "node.satisfying");
            assert_eq!(to_state, "node.present");
        } else {
            panic!("unexpected variant");
        }
    }

    #[tokio::test]
    async fn bounded_capacity_lag_skip_contract() {
        // Bounded capacity ensures that slow/unresponsive subscribers drop older frames
        // without wedging the publisher or other consumers.
        let small_channel = FlowEventChannel::new(4);
        let mut slow_subscriber = small_channel.subscribe();

        // Emit 10 events into a buffer of size 4
        for i in 1..=10 {
            small_channel.emit(
                FlowSource::Login {
                    provider: "github".into(),
                },
                format!("state.{i}"),
                format!("state.{}", i + 1),
                None::<&str>,
                1000 + i,
            );
        }

        // Slow subscriber attempts to read: should receive Lagged error, then newest frames
        match slow_subscriber.recv().await {
            Err(broadcast::error::RecvError::Lagged(skipped)) => {
                assert!(
                    skipped >= 6,
                    "expected at least 6 skipped frames, got {skipped}"
                );
            }
            other => panic!("expected Lagged error, got {other:?}"),
        }

        // After acknowledging lag, subscriber receives current frames
        let next = slow_subscriber.recv().await.expect("newest frame");
        if let ControlMessage::FlowStatePush { seq, .. } = next {
            assert!(seq >= 7, "expected recent seq, got {seq}");
        } else {
            panic!("expected FlowStatePush");
        }
    }
}
