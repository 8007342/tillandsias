//! Metric value types.
//!
//! These structs are the canonical wire format for sampled metrics.
//! Designed to be serializable so they can be emitted as JSON events or
//! folded into the convergence dashboard snapshot.
//!
//! @trace spec:resource-metric-collection, spec:observability-metrics

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// A CPU usage sample.
///
/// `system_percent` is the aggregate across all cores (0.0..=100.0).
/// `per_core_percent` is the per-core breakdown, one entry per logical CPU.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CpuMetric {
    /// Aggregate system CPU usage as a percentage (0.0..=100.0).
    pub system_percent: f64,
    /// Per-core usage percentages, indexed by core ID.
    pub per_core_percent: Vec<f64>,
    /// When the sample was taken (UTC).
    pub timestamp: DateTime<Utc>,
}

impl CpuMetric {
    /// Returns true if the sample is within the documented [0, 100] range
    /// for `system_percent` and every per-core entry.
    pub fn is_valid(&self) -> bool {
        if !(0.0..=100.0).contains(&self.system_percent) {
            return false;
        }
        self.per_core_percent
            .iter()
            .all(|c| (0.0..=100.0).contains(c))
    }
}

/// A memory usage sample (bytes, not percent — derived fields are convenience).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MemoryMetric {
    /// Total physical memory available to the system (bytes).
    pub total_bytes: u64,
    /// Used memory (bytes). Excludes buffers/cache where the kernel
    /// distinguishes; sysinfo returns the kernel's "used" value.
    pub used_bytes: u64,
    /// Available memory (bytes) — memory the kernel believes can be
    /// reclaimed without swapping.
    pub available_bytes: u64,
    /// Total swap configured (bytes); 0 on systems without swap.
    pub swap_total_bytes: u64,
    /// Used swap (bytes).
    pub swap_used_bytes: u64,
    /// When the sample was taken.
    pub timestamp: DateTime<Utc>,
}

impl MemoryMetric {
    /// Used memory as a percentage of total (0.0..=100.0).
    /// Returns 0.0 if `total_bytes` is 0 (containers without /proc/meminfo).
    pub fn used_percent(&self) -> f64 {
        if self.total_bytes == 0 {
            return 0.0;
        }
        (self.used_bytes as f64 / self.total_bytes as f64) * 100.0
    }

    /// Swap usage as a percentage of swap total (0.0..=100.0).
    /// Returns 0.0 if swap is not configured.
    pub fn swap_percent(&self) -> f64 {
        if self.swap_total_bytes == 0 {
            return 0.0;
        }
        (self.swap_used_bytes as f64 / self.swap_total_bytes as f64) * 100.0
    }
}

/// Per-mount disk usage sample.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiskMetric {
    /// Mount point path (e.g., "/", "/home", "/var/home").
    pub mount_point: String,
    /// Total bytes on this filesystem.
    pub total_bytes: u64,
    /// Available bytes on this filesystem.
    pub available_bytes: u64,
    /// When the sample was taken.
    pub timestamp: DateTime<Utc>,
}

impl DiskMetric {
    /// Used bytes (total - available). Saturating subtract so we never panic
    /// on filesystems that report transient inconsistencies.
    pub fn used_bytes(&self) -> u64 {
        self.total_bytes.saturating_sub(self.available_bytes)
    }

    /// Used percentage (0.0..=100.0). Returns 0.0 for zero-sized filesystems.
    pub fn used_percent(&self) -> f64 {
        if self.total_bytes == 0 {
            return 0.0;
        }
        (self.used_bytes() as f64 / self.total_bytes as f64) * 100.0
    }
}

/// Per-block-device disk I/O sample, expressed as rates.
///
/// Rates are computed by differencing the kernel's monotonic counters in
/// `/proc/diskstats` between two consecutive samples — the first sample after
/// [`MetricsSampler::new`](crate::MetricsSampler::new) reports zeros because
/// no previous snapshot exists yet (mirrors the CPU warm-up convention).
///
/// @trace spec:resource-metric-collection
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiskIoMetric {
    /// Kernel block-device name (e.g., `nvme0n1`, `sda`, `zram0`).
    pub device: String,
    /// Bytes read per second over the interval between this sample and the
    /// previous one.
    pub read_bytes_per_sec: f64,
    /// Bytes written per second over the interval.
    pub write_bytes_per_sec: f64,
    /// Combined read+write operations per second (IOPS).
    pub io_ops_per_sec: f64,
    /// Disk utilisation percent (0.0..=100.0): fraction of wall-clock time
    /// the device had I/O in flight. Derived from the `io_ticks` column in
    /// `/proc/diskstats`, which the kernel already exposes in milliseconds.
    pub io_util_percent: f64,
    /// When the sample was taken.
    pub timestamp: DateTime<Utc>,
}

impl DiskIoMetric {
    /// True if all rates are non-negative and utilisation is in [0, 100].
    pub fn is_valid(&self) -> bool {
        self.read_bytes_per_sec >= 0.0
            && self.write_bytes_per_sec >= 0.0
            && self.io_ops_per_sec >= 0.0
            && (0.0..=100.0).contains(&self.io_util_percent)
    }
}

/// Cgroup / system-wide Pressure Stall Information sample.
///
/// PSI tracks the percentage of time at least one task was stalled waiting
/// for the corresponding resource over a rolling 10-second window (`avg10`),
/// the value most useful for predictive saturation alerts. Older kernels
/// without `/proc/pressure` are signalled by `available = false` and zeroed
/// metrics.
///
/// @trace spec:resource-metric-collection
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PsiMetric {
    /// CPU pressure (10s window) percent, 0.0..=100.0.
    pub cpu_psi_percent: f64,
    /// Memory pressure (10s window) percent, 0.0..=100.0.
    pub memory_psi_percent: f64,
    /// I/O pressure (10s window) percent, 0.0..=100.0.
    pub io_psi_percent: f64,
    /// `false` on kernels without `/proc/pressure` (pre-4.20 or PSI disabled
    /// at build time); all percent fields are 0.0 in that case.
    pub available: bool,
    /// When the sample was taken.
    pub timestamp: DateTime<Utc>,
}

impl PsiMetric {
    /// Zero-valued sentinel used when `/proc/pressure` is missing.
    pub fn unavailable() -> Self {
        Self {
            cpu_psi_percent: 0.0,
            memory_psi_percent: 0.0,
            io_psi_percent: 0.0,
            available: false,
            timestamp: Utc::now(),
        }
    }

    /// True if every percent field is finite and within [0, 100].
    pub fn is_valid(&self) -> bool {
        [
            self.cpu_psi_percent,
            self.memory_psi_percent,
            self.io_psi_percent,
        ]
        .iter()
        .all(|v| v.is_finite() && (0.0..=100.0).contains(v))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> DateTime<Utc> {
        Utc::now()
    }

    #[test]
    fn cpu_metric_valid_in_range() {
        let m = CpuMetric {
            system_percent: 42.5,
            per_core_percent: vec![10.0, 50.0, 80.0, 0.0],
            timestamp: now(),
        };
        assert!(m.is_valid());
    }

    #[test]
    fn cpu_metric_invalid_out_of_range() {
        let m = CpuMetric {
            system_percent: 101.0,
            per_core_percent: vec![10.0],
            timestamp: now(),
        };
        assert!(!m.is_valid());

        let m = CpuMetric {
            system_percent: 50.0,
            per_core_percent: vec![10.0, -1.0],
            timestamp: now(),
        };
        assert!(!m.is_valid());
    }

    #[test]
    fn memory_used_percent_computes_correctly() {
        let m = MemoryMetric {
            total_bytes: 1000,
            used_bytes: 250,
            available_bytes: 750,
            swap_total_bytes: 0,
            swap_used_bytes: 0,
            timestamp: now(),
        };
        assert_eq!(m.used_percent(), 25.0);
        assert_eq!(m.swap_percent(), 0.0);
    }

    #[test]
    fn memory_zero_total_does_not_panic() {
        let m = MemoryMetric {
            total_bytes: 0,
            used_bytes: 0,
            available_bytes: 0,
            swap_total_bytes: 0,
            swap_used_bytes: 0,
            timestamp: now(),
        };
        assert_eq!(m.used_percent(), 0.0);
    }

    #[test]
    fn disk_used_bytes_saturating_sub() {
        let m = DiskMetric {
            mount_point: "/".into(),
            total_bytes: 100,
            available_bytes: 200, // intentionally inconsistent
            timestamp: now(),
        };
        // Saturating sub returns 0, never panics.
        assert_eq!(m.used_bytes(), 0);
        assert_eq!(m.used_percent(), 0.0);
    }

    #[test]
    fn disk_used_percent_typical() {
        let m = DiskMetric {
            mount_point: "/".into(),
            total_bytes: 1_000_000,
            available_bytes: 250_000,
            timestamp: now(),
        };
        assert_eq!(m.used_bytes(), 750_000);
        assert_eq!(m.used_percent(), 75.0);
    }

    #[test]
    fn disk_io_metric_valid_range() {
        let m = DiskIoMetric {
            device: "nvme0n1".into(),
            read_bytes_per_sec: 1_048_576.0,
            write_bytes_per_sec: 524_288.0,
            io_ops_per_sec: 42.0,
            io_util_percent: 17.5,
            timestamp: now(),
        };
        assert!(m.is_valid());
    }

    #[test]
    fn disk_io_metric_invalid_negative_rate() {
        let m = DiskIoMetric {
            device: "sda".into(),
            read_bytes_per_sec: -1.0,
            write_bytes_per_sec: 0.0,
            io_ops_per_sec: 0.0,
            io_util_percent: 0.0,
            timestamp: now(),
        };
        assert!(!m.is_valid());
    }

    #[test]
    fn disk_io_metric_invalid_over_100_percent() {
        let m = DiskIoMetric {
            device: "sda".into(),
            read_bytes_per_sec: 0.0,
            write_bytes_per_sec: 0.0,
            io_ops_per_sec: 0.0,
            io_util_percent: 250.0,
            timestamp: now(),
        };
        assert!(!m.is_valid());
    }

    #[test]
    fn psi_metric_unavailable_is_valid_zero() {
        let m = PsiMetric::unavailable();
        assert!(!m.available);
        assert_eq!(m.cpu_psi_percent, 0.0);
        assert_eq!(m.memory_psi_percent, 0.0);
        assert_eq!(m.io_psi_percent, 0.0);
        assert!(m.is_valid());
    }

    #[test]
    fn psi_metric_valid_in_range() {
        let m = PsiMetric {
            cpu_psi_percent: 12.3,
            memory_psi_percent: 0.0,
            io_psi_percent: 99.9,
            available: true,
            timestamp: now(),
        };
        assert!(m.is_valid());
    }

    #[test]
    fn psi_metric_invalid_out_of_range() {
        let m = PsiMetric {
            cpu_psi_percent: 150.0,
            memory_psi_percent: 0.0,
            io_psi_percent: 0.0,
            available: true,
            timestamp: now(),
        };
        assert!(!m.is_valid());
    }

    #[test]
    fn psi_metric_invalid_nan() {
        let m = PsiMetric {
            cpu_psi_percent: f64::NAN,
            memory_psi_percent: 0.0,
            io_psi_percent: 0.0,
            available: true,
            timestamp: now(),
        };
        assert!(!m.is_valid());
    }
}
