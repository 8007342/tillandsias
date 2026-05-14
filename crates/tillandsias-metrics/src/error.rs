//! Error types for the metrics crate.
//!
//! @trace spec:resource-metric-collection

use thiserror::Error;

/// Errors produced by the metrics sampler.
///
/// The sampler is intentionally permissive — most failures (e.g., a single
/// missing /proc entry on a stripped container) degrade rather than error.
/// Hard errors are reserved for misconfiguration or impossible system states.
#[derive(Debug, Error)]
pub enum MetricsError {
    /// The continuous sampler was started with a non-positive interval.
    #[error("sampler interval must be > 0ms, got {0:?}")]
    InvalidInterval(std::time::Duration),

    /// Serialization of a dashboard snapshot failed.
    #[error("dashboard snapshot serialization failed: {0}")]
    Serde(#[from] serde_json::Error),
}
