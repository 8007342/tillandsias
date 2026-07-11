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

use std::time::Duration;
use tokio::sync::watch;

/// What ended one tick-loop wait (SC-16).
///
/// Hoisted from the trays (macOS order 155 slice 3 introduced it in
/// `action_host.rs`; windows order 154 slice 4 adopted the shared copy) so
/// the wait semantics cannot drift between the two tick loops.
#[derive(Debug, PartialEq, Eq)]
pub enum TickWake {
    /// The poll period elapsed normally.
    Timer,
    /// The push subscription dropped mid-wait — the fallback polls own
    /// freshness again and should run a full round now, not up to a full
    /// slow-cadence period later.
    SubscriptionDropped,
}

/// Wait out one poll period, waking early only on a healthy→down transition
/// of the push subscription. Up-transitions don't end the wait (pushes own
/// freshness again; there is nothing to poll), and a closed channel (listener
/// task gone) degrades to the plain timer instead of spinning.
pub async fn wait_tick_or_subscription_drop(
    period: Duration,
    health: &mut watch::Receiver<bool>,
) -> TickWake {
    let sleep = tokio::time::sleep(period);
    tokio::pin!(sleep);
    loop {
        tokio::select! {
            _ = &mut sleep => return TickWake::Timer,
            changed = health.changed() => {
                if changed.is_err() {
                    sleep.as_mut().await;
                    return TickWake::Timer;
                }
                if !*health.borrow_and_update() {
                    return TickWake::SubscriptionDropped;
                }
            }
        }
    }
}

/// Next tick counter after a wake. A subscription drop rewinds to tick 0 so
/// the next iteration replays the first-tick full round instead of waiting
/// out the slow-cadence period.
pub fn tick_after_wake(tick: u32, wake: &TickWake) -> u32 {
    match wake {
        TickWake::Timer => tick.wrapping_add(1),
        TickWake::SubscriptionDropped => 0,
    }
}

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

    /// SC-16 pin (shared copy of the macOS slice-3 pin): a healthy→down
    /// transition ends the tick wait immediately (no sleep-out), an
    /// up-transition does NOT end it, and a closed health channel degrades
    /// to the plain timer instead of spinning or panicking.
    #[tokio::test(start_paused = true)]
    async fn tick_wait_wakes_early_only_on_subscription_drop() {
        // Down-transition wakes early.
        let health = SubscriptionHealth::new();
        health.set(true);
        let mut rx = health.subscribe();
        rx.borrow_and_update();
        let wait = wait_tick_or_subscription_drop(Duration::from_secs(30), &mut rx);
        tokio::pin!(wait);
        tokio::select! {
            biased;
            _ = &mut wait => panic!("wait ended with no transition and no timer"),
            _ = tokio::task::yield_now() => {}
        }
        health.set(false);
        assert_eq!(wait.await, TickWake::SubscriptionDropped);

        // Up-transition keeps waiting; the timer ends the wait.
        let health = SubscriptionHealth::new();
        let mut rx = health.subscribe();
        rx.borrow_and_update();
        let started = tokio::time::Instant::now();
        let wait = wait_tick_or_subscription_drop(Duration::from_secs(30), &mut rx);
        tokio::pin!(wait);
        tokio::select! {
            biased;
            _ = &mut wait => panic!("wait ended before any event"),
            _ = tokio::task::yield_now() => {}
        }
        health.set(true);
        assert_eq!(wait.await, TickWake::Timer);
        assert!(
            started.elapsed() >= Duration::from_secs(30),
            "up-transition must not shorten the poll period"
        );

        // Closed channel: sender dropped mid-wait → plain timer, no spin.
        let health = SubscriptionHealth::new();
        let mut rx = health.subscribe();
        rx.borrow_and_update();
        drop(health);
        assert_eq!(
            wait_tick_or_subscription_drop(Duration::from_secs(30), &mut rx).await,
            TickWake::Timer
        );
    }

    /// SC-16 pin: a subscription drop rewinds the cadence to tick 0 so the
    /// next iteration replays the first-tick full round; a timer wake
    /// advances normally (with wraparound).
    #[test]
    fn tick_after_wake_rewinds_on_drop_and_advances_on_timer() {
        assert_eq!(tick_after_wake(4, &TickWake::Timer), 5);
        assert_eq!(tick_after_wake(u32::MAX, &TickWake::Timer), 0);
        assert_eq!(tick_after_wake(7, &TickWake::SubscriptionDropped), 0);
    }
}
