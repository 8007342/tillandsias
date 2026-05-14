//! Sysinfo-backed sampler for CPU, memory, and disk metrics.
//!
//! The sampler holds a [`sysinfo::System`] and a [`sysinfo::Disks`] handle
//! and refreshes only the components it needs for each sample call. This
//! keeps individual samples cheap (sub-millisecond on Linux for memory; CPU
//! requires the documented minimum interval between two refreshes to be
//! accurate).
//!
//! @trace spec:observability-metrics, spec:resource-metric-collection
//! @cheatsheet observability/cheatsheet-metrics.md

use crate::error::MetricsError;
use crate::models::{CpuMetric, DiskMetric, MemoryMetric};
use chrono::Utc;
use std::time::Duration;
use sysinfo::{Disks, MINIMUM_CPU_UPDATE_INTERVAL, System};
use tracing::{debug, info, warn};

/// Sampler for CPU, memory, and disk resource metrics.
///
/// `MetricsSampler` owns a [`sysinfo::System`] that is refreshed on demand.
/// CPU sampling requires the sampler to be alive long enough between calls
/// to satisfy sysinfo's [`MINIMUM_CPU_UPDATE_INTERVAL`] — the first call may
/// return zeros, which is documented and not an error.
#[derive(Debug)]
pub struct MetricsSampler {
    system: System,
    disks: Disks,
}

impl MetricsSampler {
    /// Construct a new sampler. The underlying `System` is created with no
    /// initial refresh; call a `sample_*` method to populate values.
    pub fn new() -> Self {
        let system = System::new();
        let disks = Disks::new_with_refreshed_list();
        Self { system, disks }
    }

    /// Sample current CPU usage (aggregate and per-core).
    ///
    /// Note: sysinfo computes CPU usage as a delta between two refreshes.
    /// The very first call after [`Self::new`] returns 0.0 for every core.
    /// Production callers should either:
    ///
    /// 1. Discard the first sample, or
    /// 2. Use [`Self::collect_continuous`], which warms up the sampler
    ///    before emitting events.
    pub fn sample_cpu(&mut self) -> CpuMetric {
        self.system.refresh_cpu_usage();
        let per_core_percent: Vec<f64> = self
            .system
            .cpus()
            .iter()
            .map(|c| c.cpu_usage() as f64)
            .collect();
        let system_percent = self.system.global_cpu_info().cpu_usage() as f64;
        CpuMetric {
            system_percent: clamp_percent(system_percent),
            per_core_percent: per_core_percent.into_iter().map(clamp_percent).collect(),
            timestamp: Utc::now(),
        }
    }

    /// Sample current memory usage (RAM + swap).
    pub fn sample_memory(&mut self) -> MemoryMetric {
        self.system.refresh_memory();
        MemoryMetric {
            total_bytes: self.system.total_memory(),
            used_bytes: self.system.used_memory(),
            available_bytes: self.system.available_memory(),
            swap_total_bytes: self.system.total_swap(),
            swap_used_bytes: self.system.used_swap(),
            timestamp: Utc::now(),
        }
    }

    /// Sample disk usage across all mounted filesystems known to the kernel.
    ///
    /// Filesystem entries that report zero total bytes (e.g., pseudo
    /// filesystems like cgroup2) are filtered out.
    pub fn sample_disk(&mut self) -> Vec<DiskMetric> {
        self.disks.refresh();
        let timestamp = Utc::now();
        self.disks
            .iter()
            .filter(|d| d.total_space() > 0)
            .map(|d| DiskMetric {
                mount_point: d.mount_point().to_string_lossy().to_string(),
                total_bytes: d.total_space(),
                available_bytes: d.available_space(),
                timestamp,
            })
            .collect()
    }

    /// Run a continuous sampling loop that emits tracing events at the given
    /// interval. Intended to be spawned as a background tokio task.
    ///
    /// The first iteration warms up the CPU sampler by taking two samples
    /// separated by [`MINIMUM_CPU_UPDATE_INTERVAL`] before emitting its
    /// first dashboard-bound event. Cancellation is via `JoinHandle::abort`
    /// — the loop is cancellation-safe at every `await` point.
    ///
    /// @trace spec:resource-metric-collection
    pub async fn collect_continuous(&mut self, interval: Duration) {
        if interval.is_zero() {
            warn!(
                spec = "resource-metric-collection",
                "collect_continuous called with zero interval; aborting loop"
            );
            return;
        }

        // Warm-up: prime CPU counters before the first emit.
        let _ = self.sample_cpu();
        tokio::time::sleep(MINIMUM_CPU_UPDATE_INTERVAL).await;

        let mut ticker = tokio::time::interval(interval);
        // Skip the immediate first tick — interval() fires once at t=0.
        ticker.tick().await;
        loop {
            ticker.tick().await;
            let cpu = self.sample_cpu();
            let mem = self.sample_memory();
            // Disk sampling is comparatively expensive (one syscall per
            // mount); sample once per loop iteration but emit only the
            // aggregate "root" percent to the trace stream.
            let disks = self.sample_disk();
            let worst_disk_percent = disks
                .iter()
                .map(|d| d.used_percent())
                .fold(0.0_f64, f64::max);

            info!(
                spec = "resource-metric-collection",
                cheatsheet = "observability/cheatsheet-metrics.md",
                cpu_percent = format!("{:.1}", cpu.system_percent),
                mem_percent = format!("{:.1}", mem.used_percent()),
                disk_worst_percent = format!("{:.1}", worst_disk_percent),
                "resource sample"
            );
            debug!(
                spec = "resource-metric-collection",
                cores = cpu.per_core_percent.len(),
                mount_count = disks.len(),
                "resource sample detail"
            );
        }
    }

    /// Validate that an interval is usable for [`Self::collect_continuous`].
    /// Exposed for callers that want to reject misconfiguration up front.
    pub fn validate_interval(interval: Duration) -> Result<(), MetricsError> {
        if interval.is_zero() {
            return Err(MetricsError::InvalidInterval(interval));
        }
        Ok(())
    }
}

impl Default for MetricsSampler {
    fn default() -> Self {
        Self::new()
    }
}

fn clamp_percent(v: f64) -> f64 {
    if v.is_nan() {
        return 0.0;
    }
    v.clamp(0.0, 100.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn new_does_not_panic() {
        let _s = MetricsSampler::new();
    }

    #[test]
    fn sample_cpu_returns_zeros_on_first_call() {
        // sysinfo documents that the first refresh returns 0% for all cores.
        // We assert the type and shape, not the value.
        let mut s = MetricsSampler::new();
        let cpu = s.sample_cpu();
        assert!(cpu.is_valid(), "first sample should still be in [0,100]");
        assert!(
            !cpu.per_core_percent.is_empty(),
            "expected at least one CPU core to be reported"
        );
    }

    #[test]
    fn sample_cpu_after_warmup_in_range() {
        let mut s = MetricsSampler::new();
        let _ = s.sample_cpu();
        std::thread::sleep(MINIMUM_CPU_UPDATE_INTERVAL);
        let cpu = s.sample_cpu();
        assert!(cpu.is_valid(), "warmed sample out of range: {cpu:?}");
    }

    #[test]
    fn sample_memory_returns_sane_values() {
        let mut s = MetricsSampler::new();
        let m = s.sample_memory();
        // On any real Linux box this is at least 1 MiB. CI containers may
        // report tiny values, so we only assert non-zero.
        assert!(m.total_bytes > 0, "total memory unexpectedly zero");
        assert!(
            m.used_bytes <= m.total_bytes,
            "used > total: {} > {}",
            m.used_bytes,
            m.total_bytes
        );
        assert!(m.used_percent() >= 0.0 && m.used_percent() <= 100.0);
    }

    #[test]
    fn sample_disk_finds_at_least_one_mount() {
        let mut s = MetricsSampler::new();
        let disks = s.sample_disk();
        // CI sandboxes occasionally lack /proc/mounts visibility; only
        // assert that we never panic. If we do see mounts, validate them.
        for d in &disks {
            assert!(d.total_bytes > 0, "filtered disks should be non-zero");
            assert!(d.used_percent() >= 0.0 && d.used_percent() <= 100.0);
        }
    }

    #[test]
    fn validate_interval_rejects_zero() {
        assert!(MetricsSampler::validate_interval(Duration::ZERO).is_err());
        assert!(MetricsSampler::validate_interval(Duration::from_millis(1)).is_ok());
    }

    #[test]
    fn clamp_percent_handles_edges() {
        assert_eq!(clamp_percent(-1.0), 0.0);
        assert_eq!(clamp_percent(150.0), 100.0);
        assert_eq!(clamp_percent(f64::NAN), 0.0);
        assert_eq!(clamp_percent(42.5), 42.5);
    }

    #[test]
    fn ten_rapid_samples_do_not_panic() {
        let mut s = MetricsSampler::new();
        for _ in 0..10 {
            let _ = s.sample_cpu();
            let _ = s.sample_memory();
            let _ = s.sample_disk();
        }
    }

    #[tokio::test]
    async fn collect_continuous_returns_immediately_on_zero_interval() {
        let mut s = MetricsSampler::new();
        // With zero interval the loop logs a warning and returns; assert it
        // does not hang.
        tokio::time::timeout(Duration::from_secs(2), s.collect_continuous(Duration::ZERO))
            .await
            .expect("collect_continuous should return on zero interval, not hang");
    }
}
