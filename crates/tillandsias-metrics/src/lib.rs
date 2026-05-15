//! Resource metric sampling for Tillandsias observability.
//!
//! This crate provides CPU, memory, disk-usage, disk-I/O, and cgroup-PSI
//! sampling primitives used to detect predictive saturation events (e.g., a
//! forge container climbing toward memory pressure before being OOM-killed).
//! Wave 13 landed CPU + memory; Wave 15 (OBS-016/OBS-017) extends with disk
//! I/O rates derived from `/proc/diskstats` and Pressure Stall Information
//! parsed from `/proc/pressure`.
//!
//! @trace spec:observability-metrics, spec:resource-metric-collection
//! @cheatsheet observability/cheatsheet-metrics.md
//!
//! # Example
//!
//! ```no_run
//! use tillandsias_metrics::MetricsSampler;
//! use std::time::Duration;
//!
//! # async fn run() -> anyhow::Result<()> {
//! let mut sampler = MetricsSampler::new();
//! let cpu = sampler.sample_cpu();
//! let mem = sampler.sample_memory();
//! println!("cpu={:.1}% mem_used={}B", cpu.system_percent, mem.used_bytes);
//!
//! // Long-running background sampler:
//! let handle = tokio::spawn(async move {
//!     sampler.collect_continuous(Duration::from_secs(5)).await;
//! });
//! handle.abort();
//! # Ok(())
//! # }
//! ```

#![deny(missing_debug_implementations)]

mod dashboard;
mod error;
mod models;
mod sampler;
pub mod prometheus_exporter;

pub use dashboard::{DashboardSnapshot, emit_dashboard_metric};
pub use error::MetricsError;
pub use models::{CpuMetric, DiskIoMetric, DiskMetric, MemoryMetric, PsiMetric};
pub use sampler::{MetricsSampler, archive_old_metrics};
