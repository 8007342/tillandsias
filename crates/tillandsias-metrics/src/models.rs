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
}
