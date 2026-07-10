//! Push-subscription health as a `tokio::sync::watch` signal (SC-16).
//!
//! Both native trays gate their fallback request-polls on "is the dedicated
//! push subscription delivering?" (SC-07). The first implementations carried
//! that signal in a `static AtomicBool` the tick loop re-read after each 30s
//! sleep — exactly the `AtomicBool` + `sleep` signaling primitive SC-16
//! forbids (observable-streams-contract-2026-06-30.md): a listener can only
//! notice a transition by polling, so a subscription drop went unnoticed for
//! up to a full poll period (300s for the 10-tick login/cloud cadence).
//!
//! [`SubscriptionHealth`] wraps a `watch` channel instead. Producers
//! ([`SubscriptionHealth::set`]) mark the stream up/down; consumers either
//! read the current value ([`SubscriptionHealth::is_healthy`], for the SC-07
//! poll-suppression gate) or hold a [`tokio::sync::watch::Receiver`]
//! ([`SubscriptionHealth::subscribe`]) and `select!` on `.changed()` to react
//! to a transition the moment it happens — no polling, no sleep.
//!
//! Shared here so the macOS (order 155) and Windows (order 154) trays keep
//! structurally identical stream architectures.
//!
//! @trace spec:host-shell-architecture

use tokio::sync::watch;

/// Watch-backed health flag for a tray's push subscription. Starts
/// unhealthy: a subscription is only healthy once `SubscribeAck` lands.
#[derive(Debug)]
pub struct SubscriptionHealth {
    tx: watch::Sender<bool>,
}

impl Default for SubscriptionHealth {
    fn default() -> Self {
        Self::new()
    }
}

impl SubscriptionHealth {
    pub fn new() -> Self {
        let (tx, _rx) = watch::channel(false);
        Self { tx }
    }

    /// Mark the subscription up/down. Change-gated: setting the current
    /// value again does not wake `.changed()` waiters, so reconnect loops
    /// may call `set(false)` at the top of every attempt without spurious
    /// wakeups.
    pub fn set(&self, healthy: bool) {
        self.tx.send_if_modified(|current| {
            if *current == healthy {
                false
            } else {
                *current = healthy;
                true
            }
        });
    }

    /// Current value, for the SC-07 gate at a poll decision point.
    pub fn is_healthy(&self) -> bool {
        *self.tx.borrow()
    }

    /// A receiver for transition-driven consumers (`.changed().await`).
    pub fn subscribe(&self) -> watch::Receiver<bool> {
        self.tx.subscribe()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starts_unhealthy() {
        let health = SubscriptionHealth::new();
        assert!(!health.is_healthy());
    }

    #[test]
    fn set_is_visible_to_is_healthy_and_subscribers() {
        let health = SubscriptionHealth::new();
        let mut rx = health.subscribe();
        // Drain the initial value so has_changed reflects only new sets.
        rx.borrow_and_update();
        health.set(true);
        assert!(health.is_healthy());
        assert!(rx.has_changed().unwrap());
        assert!(*rx.borrow_and_update());
    }

    #[test]
    fn redundant_set_does_not_wake_waiters() {
        let health = SubscriptionHealth::new();
        let mut rx = health.subscribe();
        rx.borrow_and_update();
        // Already false — the reconnect loop's per-attempt set(false).
        health.set(false);
        assert!(
            !rx.has_changed().unwrap(),
            "change-gate regressed: redundant set(false) woke the watch — \
             every reconnect attempt would now trigger a fallback poll round"
        );
    }

    #[tokio::test]
    async fn transition_wakes_changed_waiter() {
        let health = SubscriptionHealth::new();
        let mut rx = health.subscribe();
        rx.borrow_and_update();
        health.set(true);
        health.set(false);
        // Both transitions happened; changed() resolves immediately and the
        // borrowed value is the latest.
        rx.changed().await.unwrap();
        assert!(!*rx.borrow_and_update());
    }
}
