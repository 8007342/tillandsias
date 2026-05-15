// @trace spec:runtime-logging, spec:logging-levels, spec:external-logs-layer, gap:OBS-003
//! Structured JSON logging layer for Tillandsias runtime.
//!
//! Provides:
//! - Async file writing with non-blocking design
//! - Structured LogEntry with timestamp, level, component, message, context, and spec_trace
//! - Schema versioning for log entry evolution tracking (@trace gap:OBS-003)
//! - File rotation: 7-day TTL, 10MB per file
//! - Dual sinks: host (~/.tillandsias/logs/) and per-project (.tillandsias/logs/)
//! - TILLANDSIAS_LOG environment variable for runtime filtering
//! - Accountability event tagging with spec trace links

pub mod aggregator;
pub mod budget_enforcer;
pub mod cardinality;
pub mod config;
pub mod dead_trace_detector;
pub mod error;
pub mod event_collector;
pub mod formatter;
pub mod log_entry;
pub mod logger;
pub mod query;
pub mod rotation;
pub mod sampler;
pub mod span_context;
pub mod surface;

pub use aggregator::{AggregatedLogEntry, AggregationFilter, ContainerSource, LogAggregator};
pub use budget_enforcer::BudgetEnforcer;
pub use cardinality::{CardinalityAnalyzer, CardinalityReport};
pub use dead_trace_detector::{DeadTrace, DeadTraceAudit, extract_dead_specs, find_dead_traces};
pub use error::{LoggingError, Result};
pub use event_collector::{EventCollector, EventMetadata, ImageBuildEvent, SecretRotationEvent};
pub use log_entry::LogEntry;
pub use logger::Logger;
pub use query::{AggregationOp, Filter, JsonFilter, Query, QueryExecutor, parse};
pub use sampler::CostAwareSampler;
pub use span_context::{
    SpanContext, SpanContextBuilder, SpanId, TraceId, clear_current_span, current_span,
    set_current_span,
};
pub use surface::{AggregationResult, BudgetStatus, ObservabilityAPI, QueryResult, SamplingStatus};

/// Initialize the global logging subscriber with file rotation and filtering.
///
/// # Arguments
/// * `log_dir` - Directory for log files (defaults to `~/.local/state/tillandsias/`)
/// * `project_dir` - Optional project-specific log directory
pub async fn init_logging(
    log_dir: Option<std::path::PathBuf>,
    project_dir: Option<std::path::PathBuf>,
) -> Result<Logger> {
    let logger = Logger::new(log_dir, project_dir).await?;
    logger.install_subscriber();
    Ok(logger)
}
