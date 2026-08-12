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
    /// A user action asked for a confirming round (the fast-poll burst).
    /// Delivered as a signal rather than noticed at the next tick, which is
    /// what lets the timer be suppressed entirely while the stream is
    /// healthy — see [`wait_tick_drop_or_request`].
    PollRequested,
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

/// Wait for the next reason to run a fallback round, with the poll timer
/// OPTIONAL (order 154, tick-retirement slice).
///
/// `wait_tick_or_subscription_drop` always wakes at the end of the period.
/// While the subscription is healthy every fallback gate is closed, so that
/// wake does no work — it just costs a timer and a scheduler round trip
/// forever, which is what SC-11 (idle CPU < 0.1%) is measuring. Passing
/// `suppress_timer: true` drops the timer for exactly that state: the wait
/// then ends only on a healthy→down transition or an explicit `request`
/// signal, both of which are real reasons to poll.
///
/// A closed health channel ALWAYS degrades to the plain timer, even with
/// `suppress_timer` set. Without that the listener task dying would leave a
/// timer-less waiter with nothing left to wake it, and the fallback polls —
/// the very thing that covers a dead listener — would never run again.
///
/// The `request` signal is edge-triggered with a stored permit
/// (`Notify::notify_one`), so a request raised while the caller was between
/// waits is delivered to the next wait rather than lost.
pub async fn wait_tick_drop_or_request(
    period: Duration,
    suppress_timer: bool,
    health: &mut watch::Receiver<bool>,
    request: &tokio::sync::Notify,
) -> TickWake {
    let sleep = tokio::time::sleep(period);
    tokio::pin!(sleep);
    let requested = request.notified();
    tokio::pin!(requested);
    loop {
        tokio::select! {
            _ = &mut sleep, if !suppress_timer => return TickWake::Timer,
            _ = &mut requested => return TickWake::PollRequested,
            changed = health.changed() => {
                if changed.is_err() {
                    // Listener gone: the timer is the only remaining wake
                    // source, so honour it regardless of `suppress_timer`.
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
/// out the slow-cadence period. A user-requested round rewinds for the same
/// reason: the point of the request is a confirming round NOW.
pub fn tick_after_wake(tick: u32, wake: &TickWake) -> u32 {
    match wake {
        TickWake::Timer => tick.wrapping_add(1),
        TickWake::SubscriptionDropped | TickWake::PollRequested => 0,
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
        assert_eq!(tick_after_wake(7, &TickWake::PollRequested), 0);
    }

    /// Order 154 tick retirement: with the timer suppressed the wait must
    /// outlive many poll periods and end ONLY on a real reason to poll.
    ///
    /// The negative control is the whole point of the test — asserting that a
    /// drop wakes the wait proves nothing on its own, because the un-suppressed
    /// timer would have woken it too. Advancing well past the period FIRST is
    /// what distinguishes "the timer was suppressed" from "the timer fired".
    #[tokio::test(start_paused = true)]
    async fn suppressed_timer_waits_only_for_a_real_poll_reason() {
        let health = SubscriptionHealth::new();
        health.set(true);
        let mut rx = health.subscribe();
        rx.borrow_and_update();
        let request = tokio::sync::Notify::new();

        let wait = wait_tick_drop_or_request(Duration::from_secs(30), true, &mut rx, &request);
        tokio::pin!(wait);
        // Ten full poll periods with the timer suppressed: nothing may wake.
        for _ in 0..10 {
            tokio::time::advance(Duration::from_secs(30)).await;
            tokio::select! {
                biased;
                _ = &mut wait => panic!("suppressed timer still woke the wait"),
                _ = tokio::task::yield_now() => {}
            }
        }
        health.set(false);
        assert_eq!(wait.await, TickWake::SubscriptionDropped);
    }

    /// Negative control for the pin above: the SAME elapsed time with
    /// `suppress_timer: false` DOES end the wait. Without this, a helper that
    /// simply never woke on the timer would pass the suppression test.
    #[tokio::test(start_paused = true)]
    async fn unsuppressed_timer_still_ends_the_wait_after_one_period() {
        let health = SubscriptionHealth::new();
        health.set(true);
        let mut rx = health.subscribe();
        rx.borrow_and_update();
        let request = tokio::sync::Notify::new();
        assert_eq!(
            wait_tick_drop_or_request(Duration::from_secs(30), false, &mut rx, &request).await,
            TickWake::Timer
        );
    }

    /// A user action raises the request while the timer is suppressed — the
    /// confirming round must start on the signal, not at some later tick.
    /// Also pins the stored-permit behaviour: a request raised BEFORE the
    /// wait begins is delivered to that wait rather than lost.
    #[tokio::test(start_paused = true)]
    async fn poll_request_wakes_a_timer_suppressed_wait() {
        let health = SubscriptionHealth::new();
        health.set(true);
        let mut rx = health.subscribe();
        rx.borrow_and_update();
        let request = tokio::sync::Notify::new();

        // Raised before the wait exists: the permit must survive.
        request.notify_one();
        assert_eq!(
            wait_tick_drop_or_request(Duration::from_secs(30), true, &mut rx, &request).await,
            TickWake::PollRequested
        );

        // And raised mid-wait.
        let wait = wait_tick_drop_or_request(Duration::from_secs(30), true, &mut rx, &request);
        tokio::pin!(wait);
        tokio::select! {
            biased;
            _ = &mut wait => panic!("wait ended with no request and no transition"),
            _ = tokio::task::yield_now() => {}
        }
        request.notify_one();
        assert_eq!(wait.await, TickWake::PollRequested);
    }

    /// If the listener task dies the health channel closes, and the fallback
    /// polls are exactly what has to take over. A timer-suppressed wait must
    /// therefore RE-ARM the timer on channel close rather than parking
    /// forever with no wake source left.
    #[tokio::test(start_paused = true)]
    async fn closed_health_channel_restores_the_timer_even_when_suppressed() {
        let health = SubscriptionHealth::new();
        health.set(true);
        let mut rx = health.subscribe();
        rx.borrow_and_update();
        let request = tokio::sync::Notify::new();
        drop(health);
        assert_eq!(
            wait_tick_drop_or_request(Duration::from_secs(30), true, &mut rx, &request).await,
            TickWake::Timer
        );
    }
}
