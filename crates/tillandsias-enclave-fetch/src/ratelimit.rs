//! Per-client rate limits: a token bucket per client address. A refused call
//! is a tool error with the `rate-limited` audit verdict, never a silent drop.
//!
//! @trace spec:proxy-container, order:2041-9aiq

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Instant;

pub struct Limiter {
    per_minute: f64,
    burst: f64,
    buckets: Mutex<HashMap<String, (f64, Instant)>>,
}

impl Limiter {
    /// `per_minute` sustained calls with bursts of up to `burst`. Zero
    /// `per_minute` refuses everything (a closed tap, not unlimited).
    pub fn new(per_minute: u32, burst: u32) -> Self {
        Self {
            per_minute: per_minute as f64,
            burst: burst.max(1) as f64,
            buckets: Mutex::new(HashMap::new()),
        }
    }

    pub fn allow(&self, client: &str) -> bool {
        self.allow_at(client, Instant::now())
    }

    pub fn allow_at(&self, client: &str, now: Instant) -> bool {
        let Ok(mut m) = self.buckets.lock() else {
            return false;
        };
        // Bound memory: forget clients idle long enough to have refilled.
        if m.len() > 4096 {
            let full = if self.per_minute > 0.0 {
                self.burst / self.per_minute * 60.0
            } else {
                0.0
            };
            m.retain(|_, (_, t)| now.duration_since(*t).as_secs_f64() < full);
        }
        let (tokens, last) = m.entry(client.to_string()).or_insert((self.burst, now));
        let refill = now.duration_since(*last).as_secs_f64() * self.per_minute / 60.0;
        *tokens = (*tokens + refill).min(self.burst);
        *last = now;
        if self.per_minute > 0.0 && *tokens >= 1.0 {
            *tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn burst_then_refill_per_client() {
        let l = Limiter::new(60, 3);
        let t = Instant::now();
        assert!((0..3).all(|_| l.allow_at("a", t)));
        assert!(!l.allow_at("a", t));
        assert!(l.allow_at("b", t), "clients are independent");
        assert!(
            l.allow_at("a", t + Duration::from_secs(1)),
            "one per second refills"
        );
        assert!(!l.allow_at("a", t + Duration::from_secs(1)));
    }

    #[test]
    fn zero_rate_is_closed() {
        assert!(!Limiter::new(0, 5).allow("a"));
    }
}
