//! Resource metric sampling for Tillandsias observability.
//!
//! This crate provides CPU, memory, and disk sampling primitives used to
//! detect predictive saturation events (e.g., a forge container climbing
//! toward memory pressure before being OOM-killed). The crate is a scaffold
//! — Wave 13 lands CPU + memory; Wave 15/16 will extend with disk IO and
//! cgroup PSI.
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

pub use dashboard::{DashboardSnapshot, emit_dashboard_metric};
pub use error::MetricsError;
pub use models::{CpuMetric, DiskMetric, MemoryMetric};
pub use sampler::MetricsSampler;
