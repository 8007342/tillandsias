// @trace spec:runtime-logging, spec:logging-levels, spec:external-logs-layer
//! Structured JSON logging layer for Tillandsias runtime.
//!
//! Provides:
//! - Async file writing with non-blocking design
//! - Structured LogEntry with timestamp, level, component, message, context, and spec_trace
//! - File rotation: 7-day TTL, 10MB per file
//! - Dual sinks: host (~/.tillandsias/logs/) and per-project (.tillandsias/logs/)
//! - TILLANDSIAS_LOG environment variable for runtime filtering
//! - Accountability event tagging with spec trace links

pub mod cardinality;
pub mod config;
pub mod error;
pub mod formatter;
pub mod log_entry;
pub mod logger;
pub mod query;
pub mod rotation;

pub use cardinality::{CardinalityAnalyzer, CardinalityReport};
pub use error::{LoggingError, Result};
pub use log_entry::LogEntry;
pub use logger::Logger;
pub use query::{parse, Query, QueryExecutor, Filter, AggregationOp, JsonFilter};

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
