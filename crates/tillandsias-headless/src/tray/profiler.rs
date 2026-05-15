// @trace gap:TR-008
//! Performance profiling for tray menu operations.
//!
//! This module tracks latencies for critical tray operations (menu open, switch, select)
//! to identify hotspots and regressions. Uses minimal overhead timing with statistical
//! aggregation for analysis.
//!
//! # Example
//!
//! ```no_run
//! use tillandsias_headless::tray::profiler::{TrayProfiler, OperationKind};
//!
//! let profiler = TrayProfiler::new();
//!
//! // Record an operation
//! let timer = profiler.start(OperationKind::MenuOpen);
//! // ... do work ...
//! drop(timer);
//!
//! // Export metrics
//! let metrics = profiler.export_metrics();
//! println!("Menu open avg latency: {:?}", metrics.operation_latencies["MenuOpen"].avg_ms);
//! ```

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use serde::{Deserialize, Serialize};

/// Kinds of tray operations to profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum OperationKind {
    /// Time to open the tray menu (initial render).
    MenuOpen,
    /// Time to switch between menu sections (projects, agents, etc).
    MenuSwitch,
    /// Time to execute a menu item selection.
    MenuSelect,
    /// Time to rebuild the menu after state change.
    MenuRebuild,
    /// Time to update icon/status display.
    IconUpdate,
}

impl OperationKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::MenuOpen => "MenuOpen",
            Self::MenuSwitch => "MenuSwitch",
            Self::MenuSelect => "MenuSelect",
            Self::MenuRebuild => "MenuRebuild",
            Self::IconUpdate => "IconUpdate",
        }
    }
}

/// Latency statistics for a single operation kind.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LatencyStats {
    /// Number of samples collected.
    pub count: u64,
    /// Minimum latency in milliseconds.
    pub min_ms: f64,
    /// Maximum latency in milliseconds.
    pub max_ms: f64,
    /// Average latency in milliseconds.
    pub avg_ms: f64,
    /// 95th percentile latency in milliseconds.
    pub p95_ms: f64,
    /// 99th percentile latency in milliseconds.
    pub p99_ms: f64,
}

impl LatencyStats {
    /// Create stats from a sorted slice of measurements (in milliseconds).
    fn from_measurements(measurements: &[f64]) -> Option<Self> {
        if measurements.is_empty() {
            return None;
        }

        let count = measurements.len() as u64;
        let min_ms = measurements.iter().cloned().fold(f64::INFINITY, f64::min);
        let max_ms = measurements.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        let avg_ms = measurements.iter().sum::<f64>() / measurements.len() as f64;

        // Percentiles from sorted array
        let p95_idx = (count as f64 * 0.95).ceil() as usize - 1;
        let p99_idx = (count as f64 * 0.99).ceil() as usize - 1;
        let p95_ms = measurements.get(p95_idx.min(measurements.len() - 1)).cloned().unwrap_or(max_ms);
        let p99_ms = measurements.get(p99_idx.min(measurements.len() - 1)).cloned().unwrap_or(max_ms);

        Some(Self {
            count,
            min_ms,
            max_ms,
            avg_ms,
            p95_ms,
            p99_ms,
        })
    }

    /// Identify if this operation is a hotspot (avg > 50ms or p99 > 100ms).
    pub fn is_hotspot(&self) -> bool {
        self.avg_ms > 50.0 || self.p99_ms > 100.0
    }
}

/// Exported performance metrics snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PerfMetrics {
    /// Map of operation kind to latency statistics.
    pub operation_latencies: HashMap<String, LatencyStats>,
    /// Total operations recorded across all kinds.
    pub total_ops: u64,
    /// List of detected hotspots (operation kinds with high latency).
    pub hotspots: Vec<String>,
}

impl PerfMetrics {
    /// Identify hotspots and return the metrics.
    fn with_hotspots(mut self) -> Self {
        self.hotspots = self
            .operation_latencies
            .iter()
            .filter_map(|(op, stats)| {
                if stats.is_hotspot() {
                    Some(op.clone())
                } else {
                    None
                }
            })
            .collect();
        self
    }
}

/// Active timer guard for an operation.
pub struct OperationTimer {
    kind: OperationKind,
    start: Instant,
    sink: Arc<Mutex<TrayProfilerInner>>,
}

impl Drop for OperationTimer {
    fn drop(&mut self) {
        let elapsed_ms = self.start.elapsed().as_secs_f64() * 1000.0;
        if let Ok(mut inner) = self.sink.lock() {
            inner.record_measurement(self.kind, elapsed_ms);
        }
    }
}

/// Inner state for the profiler (protected by mutex).
struct TrayProfilerInner {
    /// Map of operation kind to all recorded measurements in milliseconds.
    measurements: HashMap<OperationKind, Vec<f64>>,
    /// Maximum number of measurements to keep per operation (prevents unbounded growth).
    max_samples: usize,
}

impl TrayProfilerInner {
    fn new(max_samples: usize) -> Self {
        Self {
            measurements: HashMap::new(),
            max_samples,
        }
    }

    fn record_measurement(&mut self, kind: OperationKind, elapsed_ms: f64) {
        let measurements = self.measurements.entry(kind).or_insert_with(Vec::new);
        measurements.push(elapsed_ms);
        // Keep a rolling window of recent measurements
        if measurements.len() > self.max_samples {
            measurements.remove(0);
        }
    }
}

/// Thread-safe profiler for tray operations.
#[derive(Clone)]
pub struct TrayProfiler {
    inner: Arc<Mutex<TrayProfilerInner>>,
}

impl TrayProfiler {
    /// Create a new profiler with default sample limit (1000 per operation).
    pub fn new() -> Self {
        Self::with_sample_limit(1000)
    }

    /// Create a profiler with a custom maximum sample count.
    pub fn with_sample_limit(max_samples: usize) -> Self {
        Self {
            inner: Arc::new(Mutex::new(TrayProfilerInner::new(max_samples))),
        }
    }

    /// Start timing an operation.
    pub fn start(&self, kind: OperationKind) -> OperationTimer {
        OperationTimer {
            kind,
            start: Instant::now(),
            sink: self.inner.clone(),
        }
    }

    /// Export current metrics as a snapshot (does not clear measurements).
    pub fn export_metrics(&self) -> PerfMetrics {
        if let Ok(inner) = self.inner.lock() {
            let mut operation_latencies = HashMap::new();
            let mut total_ops = 0u64;

            for (kind, measurements) in &inner.measurements {
                // Sort for percentile calculation
                let mut sorted = measurements.clone();
                sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

                if let Some(stats) = LatencyStats::from_measurements(&sorted) {
                    total_ops += stats.count;
                    operation_latencies.insert(kind.as_str().to_string(), stats);
                }
            }

            PerfMetrics {
                operation_latencies,
                total_ops,
                hotspots: vec![],
            }
            .with_hotspots()
        } else {
            PerfMetrics {
                operation_latencies: HashMap::new(),
                total_ops: 0,
                hotspots: vec![],
            }
        }
    }

    /// Clear all recorded measurements.
    pub fn reset(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.measurements.clear();
        }
    }

    /// Get the count of recorded operations for a specific kind (for testing).
    #[cfg(test)]
    pub fn operation_count(&self, kind: OperationKind) -> usize {
        if let Ok(inner) = self.inner.lock() {
            inner
                .measurements
                .get(&kind)
                .map(|m| m.len())
                .unwrap_or(0)
        } else {
            0
        }
    }
}

impl Default for TrayProfiler {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for TrayProfiler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TrayProfiler").finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[test]
    fn test_profiler_records_operations() {
        let profiler = TrayProfiler::new();

        let _timer = profiler.start(OperationKind::MenuOpen);
        thread::sleep(Duration::from_millis(10));
        drop(_timer);

        assert_eq!(profiler.operation_count(OperationKind::MenuOpen), 1);

        let metrics = profiler.export_metrics();
        assert_eq!(metrics.total_ops, 1);
        assert!(metrics.operation_latencies.contains_key("MenuOpen"));
        let stats = &metrics.operation_latencies["MenuOpen"];
        assert!(stats.avg_ms >= 10.0, "Expected at least 10ms, got {}", stats.avg_ms);
    }

    #[test]
    fn test_latency_stats_calculation() {
        let profiler = TrayProfiler::new();

        // Record 5 operations with predictable latencies
        for latency_ms in [10.0, 20.0, 30.0, 40.0, 50.0] {
            let timer = profiler.start(OperationKind::MenuSwitch);
            // Simulate work
            let start = Instant::now();
            while start.elapsed().as_secs_f64() * 1000.0 < latency_ms * 0.5 {
                // Busy-wait to approximate desired latency
            }
            drop(timer);
            thread::sleep(Duration::from_millis(5));
        }

        let metrics = profiler.export_metrics();
        assert_eq!(metrics.total_ops, 5);

        let stats = &metrics.operation_latencies["MenuSwitch"];
        assert!(stats.min_ms <= stats.avg_ms, "Min should be <= avg");
        assert!(stats.avg_ms <= stats.max_ms, "Avg should be <= max");
        assert!(stats.p95_ms >= stats.avg_ms, "P95 should be >= avg");
        assert!(stats.p99_ms >= stats.p95_ms, "P99 should be >= p95");
    }

    #[test]
    fn test_hotspot_detection() {
        let profiler = TrayProfiler::new();

        // Record operations that will trigger hotspot threshold (avg > 50ms)
        for _ in 0..3 {
            let timer = profiler.start(OperationKind::MenuRebuild);
            thread::sleep(Duration::from_millis(60));
            drop(timer);
        }

        let metrics = profiler.export_metrics();
        assert!(!metrics.hotspots.is_empty(), "Should detect MenuRebuild as hotspot");
        assert!(metrics.hotspots.contains(&"MenuRebuild".to_string()));
    }

    #[test]
    fn test_multiple_operation_kinds() {
        let profiler = TrayProfiler::new();

        let _t1 = profiler.start(OperationKind::MenuOpen);
        thread::sleep(Duration::from_millis(5));
        drop(_t1);

        let _t2 = profiler.start(OperationKind::MenuSelect);
        thread::sleep(Duration::from_millis(10));
        drop(_t2);

        let _t3 = profiler.start(OperationKind::IconUpdate);
        thread::sleep(Duration::from_millis(3));
        drop(_t3);

        let metrics = profiler.export_metrics();
        assert_eq!(metrics.total_ops, 3);
        assert_eq!(metrics.operation_latencies.len(), 3);
    }

    #[test]
    fn test_reset_clears_measurements() {
        let profiler = TrayProfiler::new();

        let _timer = profiler.start(OperationKind::MenuOpen);
        thread::sleep(Duration::from_millis(5));
        drop(_timer);

        assert_eq!(profiler.operation_count(OperationKind::MenuOpen), 1);

        profiler.reset();
        assert_eq!(profiler.operation_count(OperationKind::MenuOpen), 0);

        let metrics = profiler.export_metrics();
        assert_eq!(metrics.total_ops, 0);
    }
}
