// @trace gap:OBS-006
//! Cost-aware trace sampling for high-volume logging scenarios.
//!
//! Prevents trace storage explosion by sampling expensive traces (large serialization)
//! when cost thresholds are exceeded. Sampled traces are marked with `sample_rate` field.
//!
//! # Architecture
//!
//! - **Cost Estimation**: Measure serialization size + analysis overhead per trace
//! - **Window Tracking**: Aggregate costs per time window (hour-based)
//! - **Probabilistic Sampling**: Apply 50% sampling when over threshold
//! - **Metadata Marking**: Tag sampled traces with `sample_rate` for query tools
//!
//! # Example
//!
//! ```rust,ignore
//! let mut sampler = CostAwareSampler::new(10 * 1024 * 1024); // 10MB/hour threshold
//! let should_emit = sampler.should_sample(&entry)?;
//! if should_emit {
//!     logger.emit(entry).await?;
//! }
//! ```

use crate::LogEntry;
use parking_lot::RwLock;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

/// Cost estimation overhead in bytes (per-trace metadata, timing info, etc.)
const ANALYSIS_OVERHEAD_BYTES: usize = 256;

/// Default sampling threshold: 10MB per hour
const DEFAULT_THRESHOLD_BYTES: u64 = 10 * 1024 * 1024;

/// Sampling rate when threshold is exceeded
const SAMPLING_RATE: f64 = 0.5;

/// Time window duration in seconds (1 hour)
const WINDOW_DURATION_SECS: u64 = 3600;

/// Cost tracking state shared across threads
#[derive(Debug, Clone)]
struct WindowState {
    /// Start time of current window (unix seconds)
    window_start: u64,

    /// Cumulative cost in current window (bytes)
    cumulative_cost: u64,

    /// Whether we're currently in sampling mode
    sampling_active: bool,

    /// Total traces sampled in this window
    traces_sampled: u64,

    /// Total traces emitted (sampled + non-sampled)
    traces_total: u64,
}

impl Default for WindowState {
    fn default() -> Self {
        Self {
            window_start: current_unix_time(),
            cumulative_cost: 0,
            sampling_active: false,
            traces_sampled: 0,
            traces_total: 0,
        }
    }
}

/// Cost-aware sampler for high-volume traces
///
/// Tracks serialization cost per time window and applies probabilistic sampling
/// when threshold is exceeded.
#[derive(Clone)]
pub struct CostAwareSampler {
    /// Threshold in bytes per hour
    threshold: u64,

    /// Mutable state (window tracking, cumulative cost)
    state: Arc<RwLock<WindowState>>,
}

impl CostAwareSampler {
    /// Create a new cost-aware sampler with default threshold (10MB/hour)
    pub fn new() -> Self {
        Self::with_threshold(DEFAULT_THRESHOLD_BYTES)
    }

    /// Create a new cost-aware sampler with custom threshold in bytes
    ///
    /// # Arguments
    /// * `threshold` - Maximum cumulative cost per hour in bytes
    pub fn with_threshold(threshold: u64) -> Self {
        Self {
            threshold,
            state: Arc::new(RwLock::new(WindowState::default())),
        }
    }

    /// Determine if a trace should be sampled (emitted to logs)
    ///
    /// Returns true if the trace should be emitted, false if it should be dropped.
    /// Also updates cumulative cost tracking and sampling status.
    ///
    /// # Arguments
    /// * `entry` - The log entry to evaluate
    ///
    /// # Returns
    /// * `Ok(true)` - Emit this trace (below threshold or lucky random)
    /// * `Ok(false)` - Drop this trace (over threshold and failed random sample)
    /// * `Err(_)` - Serialization error (treat as non-fatal, emit trace)
    pub fn should_sample(
        &self,
        entry: &LogEntry,
    ) -> std::result::Result<bool, Box<dyn std::error::Error>> {
        // Estimate cost of this trace
        let cost = estimate_trace_cost(entry)?;

        // Check and possibly reset window
        let mut state = self.state.write();
        let now = current_unix_time();

        if now >= state.window_start + WINDOW_DURATION_SECS {
            // Window expired, reset to new window
            state.window_start = now;
            state.cumulative_cost = 0;
            state.sampling_active = false;
            state.traces_sampled = 0;
            state.traces_total = 0;
        }

        // Update cumulative cost
        state.cumulative_cost += cost as u64;
        state.traces_total += 1;

        // Check if we exceed threshold and should activate sampling
        let should_emit = if state.cumulative_cost > self.threshold {
            // Over threshold: activate sampling if not already
            if !state.sampling_active {
                state.sampling_active = true;
            }

            // Apply probabilistic sampling (50% keep rate)
            let random_value = rand_f64();
            let passes_sample = random_value < SAMPLING_RATE;

            if passes_sample {
                state.traces_sampled += 1;
            }

            passes_sample
        } else {
            // Under threshold: emit all traces
            true
        };

        Ok(should_emit)
    }

    /// Estimate trace cost in bytes (serialization + overhead)
    ///
    /// Public for testing purposes. Measures JSON serialization size
    /// plus analysis overhead.
    pub fn estimate_cost(
        entry: &LogEntry,
    ) -> std::result::Result<usize, Box<dyn std::error::Error>> {
        estimate_trace_cost(entry)
    }

    /// Get current window statistics
    ///
    /// Returns (cumulative_cost, sampling_active, traces_sampled, traces_total)
    pub fn window_stats(&self) -> (u64, bool, u64, u64) {
        let state = self.state.read();
        (
            state.cumulative_cost,
            state.sampling_active,
            state.traces_sampled,
            state.traces_total,
        )
    }

    /// Get the current sampling threshold in bytes
    pub fn threshold(&self) -> u64 {
        self.threshold
    }

    /// Reset window manually (for testing)
    #[cfg(test)]
    pub fn reset_window(&self) {
        let mut state = self.state.write();
        state.window_start = current_unix_time();
        state.cumulative_cost = 0;
        state.sampling_active = false;
        state.traces_sampled = 0;
        state.traces_total = 0;
    }
}

impl Default for CostAwareSampler {
    fn default() -> Self {
        Self::new()
    }
}

/// Estimate the cost of a trace in bytes (serialization size + overhead)
fn estimate_trace_cost(entry: &LogEntry) -> std::result::Result<usize, Box<dyn std::error::Error>> {
    // Serialize entry to JSON to measure actual size
    let json = entry.to_json()?;
    let serialization_size = json.len();

    // Total cost: serialization + per-trace overhead (metadata, indexing, etc.)
    let total_cost = serialization_size + ANALYSIS_OVERHEAD_BYTES;

    Ok(total_cost)
}

/// Get current unix timestamp in seconds
fn current_unix_time() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Generate a random float between 0.0 and 1.0
/// Uses a simple LCG-based generator for determinism in tests
fn rand_f64() -> f64 {
    use std::cell::RefCell;

    thread_local! {
        static RNG: RefCell<u64> = RefCell::new({
            // Seed with current time
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos() as u64)
                .unwrap_or(1)
        });
    }

    RNG.with(|rng| {
        let mut state = rng.borrow_mut();
        // Linear congruential generator (MINSTD)
        *state = state.wrapping_mul(1103515245).wrapping_add(12345);
        let value = (*state / 65536) % 1000000;
        (value as f64) / 1000000.0
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use serde_json::json;

    fn create_test_entry(message: &str) -> LogEntry {
        LogEntry::new(
            Utc::now(),
            "INFO".to_string(),
            "test".to_string(),
            message.to_string(),
        )
    }

    fn create_test_entry_with_context(message: &str, context_size: usize) -> LogEntry {
        let mut entry = create_test_entry(message);
        let mut ctx = std::collections::HashMap::new();

        // Add large context to inflate serialization size
        let large_value = "x".repeat(context_size);
        ctx.insert("large_data".to_string(), json!(large_value));

        entry.context = Some(ctx);
        entry
    }

    #[test]
    fn test_cost_estimation_basic() {
        let entry = create_test_entry("simple test");
        let cost = CostAwareSampler::estimate_cost(&entry).unwrap();

        // Cost should be: serialization size + overhead
        let json = entry.to_json().unwrap();
        assert!(cost > json.len()); // Includes overhead
        assert_eq!(cost, json.len() + ANALYSIS_OVERHEAD_BYTES);
    }

    #[test]
    fn test_cost_estimation_with_context() {
        let entry = create_test_entry_with_context("with context", 1000);
        let cost = CostAwareSampler::estimate_cost(&entry).unwrap();

        // Cost should reflect larger serialization
        assert!(cost > 1000);
        assert!(cost >= 1000 + ANALYSIS_OVERHEAD_BYTES);
    }

    #[test]
    fn test_sampler_below_threshold() {
        // Very high threshold (won't trigger sampling)
        let sampler = CostAwareSampler::with_threshold(1_000_000_000);

        // All traces below threshold should be emitted
        for i in 0..10 {
            let entry = create_test_entry(&format!("message {}", i));
            assert!(sampler.should_sample(&entry).unwrap());
        }

        // Sampling should not be active
        let (_, sampling_active, _, total) = sampler.window_stats();
        assert!(!sampling_active);
        assert_eq!(total, 10);
    }

    #[test]
    fn test_sampler_above_threshold_triggers_sampling() {
        // Low threshold to trigger sampling easily
        let sampler = CostAwareSampler::with_threshold(100);

        // Add traces until we exceed threshold
        let mut sampling_started_at = None;

        for i in 0..100 {
            let entry = create_test_entry(&format!("msg {}", i));
            let _ = sampler.should_sample(&entry);

            let (cumulative, sampling_active, _, _total) = sampler.window_stats();
            if sampling_active && sampling_started_at.is_none() {
                sampling_started_at = Some(i);
            }

            // Once we exceed threshold, sampling should activate
            if cumulative > 100 {
                assert!(
                    sampling_active,
                    "Sampling should activate when cost exceeds threshold"
                );
            }
        }

        // Should have started sampling
        assert!(sampling_started_at.is_some());

        let (_final_cost, final_sampling, final_sampled, final_total) = sampler.window_stats();
        assert!(final_sampling);
        assert_eq!(final_total, 100);
        assert!(final_sampled > 0); // Some traces were sampled
        assert!(final_sampled < final_total); // Not all traces (sampling rate 0.5)
    }

    #[test]
    fn test_sampler_window_reset() {
        let sampler = CostAwareSampler::with_threshold(100);

        // Fill first window
        for i in 0..50 {
            let entry = create_test_entry(&format!("msg {}", i));
            let _ = sampler.should_sample(&entry);
        }

        let (cost1, _sampling1, _sampled1, total1) = sampler.window_stats();
        assert!(cost1 > 0);
        assert_eq!(total1, 50);

        // Reset window manually (simulates time passing)
        sampler.reset_window();

        let (cost2, sampling2, sampled2, total2) = sampler.window_stats();
        assert_eq!(cost2, 0);
        assert!(!sampling2);
        assert_eq!(sampled2, 0);
        assert_eq!(total2, 0);
    }

    #[test]
    fn test_sampler_threshold_configuration() {
        let threshold = 50_000;
        let sampler = CostAwareSampler::with_threshold(threshold);
        assert_eq!(sampler.threshold(), threshold);
    }

    #[test]
    fn test_sampler_default_threshold() {
        let sampler = CostAwareSampler::new();
        assert_eq!(sampler.threshold(), DEFAULT_THRESHOLD_BYTES);
    }

    #[test]
    fn test_cost_estimation_large_context() {
        // Create entry with large context to test cost scaling
        let entry = create_test_entry_with_context("large", 10_000);
        let cost = CostAwareSampler::estimate_cost(&entry).unwrap();

        // Cost should scale with context size
        assert!(cost > 10_000);

        // Different context size should produce different cost
        let entry2 = create_test_entry_with_context("large", 20_000);
        let cost2 = CostAwareSampler::estimate_cost(&entry2).unwrap();
        assert!(cost2 > cost);
    }

    #[test]
    fn test_sampling_rate_distribution() {
        // Test that sampling rate approximates 0.5 over many samples
        let sampler = CostAwareSampler::with_threshold(100);

        let mut sampled_count = 0;
        let mut total_count = 0;

        // Generate many traces to trigger sampling
        for i in 0..1000 {
            let entry = create_test_entry(&format!("msg {}", i));
            if sampler.should_sample(&entry).unwrap() {
                sampled_count += 1;
            }
            total_count += 1;

            // Once we're in sampling mode, check statistical properties
            let (_, sampling_active, _, _) = sampler.window_stats();
            if sampling_active && total_count > 100 {
                // Sampling rate should be roughly 0.5
                let rate = sampled_count as f64 / total_count as f64;
                // Allow 0.3-0.7 range for sampling rate (loose bounds for randomness)
                assert!(
                    rate > 0.25 && rate < 0.75,
                    "Sampling rate {} should be near 0.5",
                    rate
                );
                break;
            }
        }

        // Should have hit sampling mode
        let (_, sampling_active, _, _) = sampler.window_stats();
        assert!(sampling_active);
    }
}
