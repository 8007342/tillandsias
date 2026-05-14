//! Convergence dashboard integration hooks.
//!
//! `emit_dashboard_metric` writes a named metric value to the tracing
//! subscriber so any sink (file logger, journald, etc.) can pick it up.
//! `DashboardSnapshot` is the shape the convergence dashboard expects under
//! its `metrics` key (see `docs/convergence/centicolon-dashboard.json`).
//!
//! @trace spec:observability-metrics, spec:observability-convergence
//! @cheatsheet observability/cheatsheet-metrics.md

use crate::models::{CpuMetric, DiskIoMetric, DiskMetric, MemoryMetric, PsiMetric};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tracing::info;

/// Shape of the `metrics` block embedded in the convergence dashboard JSON.
///
/// The renderer (`scripts/update-convergence-dashboard.sh`) reads this
/// structure to project the latest resource sample alongside the existing
/// CentiColon trend metrics. Fields are intentionally flat to make the JSON
/// trivially diffable. Disk-I/O and PSI fields default to zero on older
/// snapshots so the schema is forward-compatible with existing dashboard
/// readers.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DashboardSnapshot {
    /// Aggregate CPU usage percent at sample time.
    pub cpu_percent: f64,
    /// Memory usage percent at sample time.
    pub memory_percent: f64,
    /// Worst (highest) disk usage percent across all mounts at sample time.
    /// 0.0 if no mounts were observable.
    pub disk_percent: f64,
    /// Aggregate bytes-read-per-second across every block device, 0.0 if no
    /// disk I/O samples were available.
    #[serde(default)]
    pub disk_read_bytes_per_sec: f64,
    /// Aggregate bytes-written-per-second across every block device.
    #[serde(default)]
    pub disk_write_bytes_per_sec: f64,
    /// Aggregate IOPS (reads + writes per second) across every block device.
    #[serde(default)]
    pub disk_iops: f64,
    /// Worst (highest) per-device utilisation percent at sample time.
    #[serde(default)]
    pub disk_io_percent: f64,
    /// CPU pressure (PSI avg10) percent. 0.0 when PSI is unavailable.
    #[serde(default)]
    pub cpu_psi_percent: f64,
    /// Memory pressure (PSI avg10) percent. 0.0 when PSI is unavailable.
    #[serde(default)]
    pub memory_psi_percent: f64,
    /// I/O pressure (PSI avg10) percent. 0.0 when PSI is unavailable.
    #[serde(default)]
    pub io_psi_percent: f64,
    /// `false` when `/proc/pressure` was missing or unreadable at sample time.
    #[serde(default)]
    pub psi_available: bool,
    /// ISO 8601 UTC timestamp the sample was taken.
    pub sample_timestamp: DateTime<Utc>,
}

impl DashboardSnapshot {
    /// Build a snapshot from a CPU + memory + (optional worst disk) sample.
    /// Uses the CPU sample's timestamp as the canonical `sample_timestamp`.
    /// Disk-I/O and PSI fields default to zero — call
    /// [`Self::with_disk_io`] / [`Self::with_psi`] to populate them.
    pub fn from_samples(cpu: &CpuMetric, mem: &MemoryMetric, disks: &[DiskMetric]) -> Self {
        let disk_percent = disks
            .iter()
            .map(|d| d.used_percent())
            .fold(0.0_f64, f64::max);
        Self {
            cpu_percent: cpu.system_percent,
            memory_percent: mem.used_percent(),
            disk_percent,
            disk_read_bytes_per_sec: 0.0,
            disk_write_bytes_per_sec: 0.0,
            disk_iops: 0.0,
            disk_io_percent: 0.0,
            cpu_psi_percent: 0.0,
            memory_psi_percent: 0.0,
            io_psi_percent: 0.0,
            psi_available: false,
            sample_timestamp: cpu.timestamp,
        }
    }

    /// Fold a disk-I/O sample slice into this snapshot, aggregating rates
    /// across every device and tracking the worst per-device utilisation.
    pub fn with_disk_io(mut self, disk_io: &[DiskIoMetric]) -> Self {
        let mut worst = 0.0_f64;
        for m in disk_io {
            self.disk_read_bytes_per_sec += m.read_bytes_per_sec;
            self.disk_write_bytes_per_sec += m.write_bytes_per_sec;
            self.disk_iops += m.io_ops_per_sec;
            worst = worst.max(m.io_util_percent);
        }
        self.disk_io_percent = worst;
        self
    }

    /// Fold a PSI sample into this snapshot. Unavailable PSI samples leave
    /// the snapshot's PSI fields at zero with `psi_available = false`.
    pub fn with_psi(mut self, psi: &PsiMetric) -> Self {
        self.psi_available = psi.available;
        self.cpu_psi_percent = psi.cpu_psi_percent;
        self.memory_psi_percent = psi.memory_psi_percent;
        self.io_psi_percent = psi.io_psi_percent;
        self
    }

    /// Serialize to a `serde_json::Value` for embedding into the dashboard
    /// JSON renderer.
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "cpu_percent": self.cpu_percent,
            "memory_percent": self.memory_percent,
            "disk_percent": self.disk_percent,
            "disk_read_bytes_per_sec": self.disk_read_bytes_per_sec,
            "disk_write_bytes_per_sec": self.disk_write_bytes_per_sec,
            "disk_iops": self.disk_iops,
            "disk_io_percent": self.disk_io_percent,
            "cpu_psi_percent": self.cpu_psi_percent,
            "memory_psi_percent": self.memory_psi_percent,
            "io_psi_percent": self.io_psi_percent,
            "psi_available": self.psi_available,
            "sample_timestamp": self.sample_timestamp.to_rfc3339(),
        })
    }
}

/// Emit a single named metric to the tracing pipeline.
///
/// Consumers (file logger, journald, central CentiColon collector) can grep
/// for `metric_name=<name>` in the JSON log stream to extract a time series
/// without bespoke wire formats.
///
/// @trace spec:resource-metric-collection
pub fn emit_dashboard_metric(name: &str, value: f64) {
    info!(
        spec = "resource-metric-collection",
        cheatsheet = "observability/cheatsheet-metrics.md",
        metric_name = name,
        metric_value = format!("{value:.4}"),
        "dashboard metric"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{CpuMetric, DiskIoMetric, DiskMetric, MemoryMetric, PsiMetric};
    use chrono::Utc;

    fn cpu(p: f64) -> CpuMetric {
        CpuMetric {
            system_percent: p,
            per_core_percent: vec![p],
            timestamp: Utc::now(),
        }
    }

    fn mem(total: u64, used: u64) -> MemoryMetric {
        MemoryMetric {
            total_bytes: total,
            used_bytes: used,
            available_bytes: total.saturating_sub(used),
            swap_total_bytes: 0,
            swap_used_bytes: 0,
            timestamp: Utc::now(),
        }
    }

    fn disk(mount: &str, total: u64, available: u64) -> DiskMetric {
        DiskMetric {
            mount_point: mount.into(),
            total_bytes: total,
            available_bytes: available,
            timestamp: Utc::now(),
        }
    }

    #[test]
    fn snapshot_uses_worst_disk_percent() {
        let snap = DashboardSnapshot::from_samples(
            &cpu(50.0),
            &mem(1000, 500),
            &[
                disk("/", 1000, 900),     // 10% used
                disk("/home", 1000, 100), // 90% used (worst)
            ],
        );
        assert_eq!(snap.cpu_percent, 50.0);
        assert_eq!(snap.memory_percent, 50.0);
        assert_eq!(snap.disk_percent, 90.0);
    }

    #[test]
    fn snapshot_empty_disks_is_zero() {
        let snap = DashboardSnapshot::from_samples(&cpu(25.0), &mem(1000, 250), &[]);
        assert_eq!(snap.disk_percent, 0.0);
    }

    #[test]
    fn snapshot_round_trips_json() {
        let snap = DashboardSnapshot::from_samples(&cpu(33.3), &mem(1000, 333), &[]);
        let json = snap.to_json();
        assert!(json.is_object());
        let obj = json.as_object().unwrap();
        assert!(obj.contains_key("cpu_percent"));
        assert!(obj.contains_key("memory_percent"));
        assert!(obj.contains_key("disk_percent"));
        assert!(obj.contains_key("sample_timestamp"));
    }

    #[test]
    fn emit_dashboard_metric_does_not_panic() {
        // Without a subscriber attached, info!() is a no-op; just confirm
        // the call site is safe.
        emit_dashboard_metric("cpu_percent", 42.5);
        emit_dashboard_metric("memory_percent", 0.0);
        emit_dashboard_metric("disk_percent", 100.0);
    }

    fn disk_io(read: f64, write: f64, ops: f64, util: f64) -> DiskIoMetric {
        DiskIoMetric {
            device: "sda".into(),
            read_bytes_per_sec: read,
            write_bytes_per_sec: write,
            io_ops_per_sec: ops,
            io_util_percent: util,
            timestamp: Utc::now(),
        }
    }

    #[test]
    fn snapshot_with_disk_io_aggregates_devices() {
        let snap = DashboardSnapshot::from_samples(&cpu(0.0), &mem(1000, 0), &[]).with_disk_io(&[
            disk_io(100.0, 50.0, 10.0, 20.0),
            disk_io(200.0, 25.0, 5.0, 90.0),
        ]);
        assert_eq!(snap.disk_read_bytes_per_sec, 300.0);
        assert_eq!(snap.disk_write_bytes_per_sec, 75.0);
        assert_eq!(snap.disk_iops, 15.0);
        // Worst-case utilisation, not sum.
        assert_eq!(snap.disk_io_percent, 90.0);
    }

    #[test]
    fn snapshot_with_psi_unavailable_leaves_zero() {
        let snap = DashboardSnapshot::from_samples(&cpu(0.0), &mem(1000, 0), &[])
            .with_psi(&PsiMetric::unavailable());
        assert!(!snap.psi_available);
        assert_eq!(snap.cpu_psi_percent, 0.0);
        assert_eq!(snap.memory_psi_percent, 0.0);
        assert_eq!(snap.io_psi_percent, 0.0);
    }

    #[test]
    fn snapshot_with_psi_available_copies_values() {
        let psi = PsiMetric {
            cpu_psi_percent: 1.5,
            memory_psi_percent: 2.5,
            io_psi_percent: 3.5,
            available: true,
            timestamp: Utc::now(),
        };
        let snap = DashboardSnapshot::from_samples(&cpu(0.0), &mem(1000, 0), &[]).with_psi(&psi);
        assert!(snap.psi_available);
        assert_eq!(snap.cpu_psi_percent, 1.5);
        assert_eq!(snap.memory_psi_percent, 2.5);
        assert_eq!(snap.io_psi_percent, 3.5);
    }

    #[test]
    fn snapshot_json_includes_new_fields() {
        let snap = DashboardSnapshot::from_samples(&cpu(0.0), &mem(1000, 0), &[])
            .with_disk_io(&[disk_io(1.0, 2.0, 3.0, 4.0)])
            .with_psi(&PsiMetric {
                cpu_psi_percent: 0.1,
                memory_psi_percent: 0.2,
                io_psi_percent: 0.3,
                available: true,
                timestamp: Utc::now(),
            });
        let json = snap.to_json();
        let obj = json.as_object().unwrap();
        for key in [
            "disk_read_bytes_per_sec",
            "disk_write_bytes_per_sec",
            "disk_iops",
            "disk_io_percent",
            "cpu_psi_percent",
            "memory_psi_percent",
            "io_psi_percent",
            "psi_available",
        ] {
            assert!(obj.contains_key(key), "missing dashboard field: {key}");
        }
    }
}
