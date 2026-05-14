//! Convergence dashboard integration hooks.
//!
//! `emit_dashboard_metric` writes a named metric value to the tracing
//! subscriber so any sink (file logger, journald, etc.) can pick it up.
//! `DashboardSnapshot` is the shape the convergence dashboard expects under
//! its `metrics` key (see `docs/convergence/centicolon-dashboard.json`).
//!
//! @trace spec:observability-metrics, spec:observability-convergence
//! @cheatsheet observability/cheatsheet-metrics.md

use crate::models::{CpuMetric, DiskMetric, MemoryMetric};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tracing::info;

/// Shape of the `metrics` block embedded in the convergence dashboard JSON.
///
/// The renderer (`scripts/update-convergence-dashboard.sh`) reads this
/// structure to project the latest resource sample alongside the existing
/// CentiColon trend metrics. Fields are intentionally flat to make the JSON
/// trivially diffable.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DashboardSnapshot {
    /// Aggregate CPU usage percent at sample time.
    pub cpu_percent: f64,
    /// Memory usage percent at sample time.
    pub memory_percent: f64,
    /// Worst (highest) disk usage percent across all mounts at sample time.
    /// 0.0 if no mounts were observable.
    pub disk_percent: f64,
    /// ISO 8601 UTC timestamp the sample was taken.
    pub sample_timestamp: DateTime<Utc>,
}

impl DashboardSnapshot {
    /// Build a snapshot from a CPU + memory + (optional worst disk) sample.
    /// Uses the CPU sample's timestamp as the canonical `sample_timestamp`.
    pub fn from_samples(cpu: &CpuMetric, mem: &MemoryMetric, disks: &[DiskMetric]) -> Self {
        let disk_percent = disks
            .iter()
            .map(|d| d.used_percent())
            .fold(0.0_f64, f64::max);
        Self {
            cpu_percent: cpu.system_percent,
            memory_percent: mem.used_percent(),
            disk_percent,
            sample_timestamp: cpu.timestamp,
        }
    }

    /// Serialize to a `serde_json::Value` for embedding into the dashboard
    /// JSON renderer.
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "cpu_percent": self.cpu_percent,
            "memory_percent": self.memory_percent,
            "disk_percent": self.disk_percent,
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
    use crate::models::{CpuMetric, DiskMetric, MemoryMetric};
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
}
