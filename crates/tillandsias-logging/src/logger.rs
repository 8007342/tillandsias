// @trace spec:runtime-logging, spec:logging-levels, spec:external-logs-layer
use crate::Result;
use crate::config::LoggingConfig;
use crate::rotation::RotationPolicy;
use parking_lot::RwLock;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::fs;
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::EnvFilter;
use tracing_subscriber::prelude::*;

/// Main logging system
///
/// Manages:
/// - Async file writing with non-blocking subscriber
/// - File rotation (7-day TTL, 10MB per file)
/// - Dual sinks (host + per-project)
/// - TILLANDSIAS_LOG env var filtering
/// - Accountability event metadata
pub struct Logger {
    config: LoggingConfig,
    rotation_policy: RotationPolicy,
    _guard: Arc<RwLock<Vec<WorkerGuard>>>,
}

impl Logger {
    /// Create a new logger with default or custom configuration
    pub async fn new(log_dir: Option<PathBuf>, project_log_dir: Option<PathBuf>) -> Result<Self> {
        let mut config = LoggingConfig::default();

        if let Some(dir) = log_dir {
            config.log_dir = dir;
        }

        if let Some(dir) = project_log_dir {
            config.project_log_dir = Some(dir);
        }

        // Create log directories
        fs::create_dir_all(&config.log_dir).await?;
        if let Some(ref project_dir) = config.project_log_dir {
            fs::create_dir_all(project_dir).await?;
        }

        Ok(Self {
            config,
            rotation_policy: RotationPolicy::default(),
            _guard: Arc::new(RwLock::new(Vec::new())),
        })
    }

    /// Install the tracing subscriber globally
    pub fn install_subscriber(&self) {
        let env_filter = EnvFilter::try_from_default_env()
            .or_else(|_| EnvFilter::try_new(&self.config.env_filter))
            .unwrap_or_else(|_| EnvFilter::new("tillandsias=info"));

        // Main log file
        let log_file_path = self.config.log_dir.join("tillandsias.log");
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_file_path)
            .expect("failed to open log file");

        let (non_blocking, guard) = tracing_appender::non_blocking(file);

        let fmt_layer = tracing_subscriber::fmt::layer()
            .with_writer(non_blocking)
            .with_target(true)
            .with_thread_ids(true)
            .with_level(true)
            .with_ansi(false)
            .compact();

        tracing_subscriber::registry()
            .with(env_filter)
            .with(fmt_layer)
            .init();

        // Store guard to prevent premature shutdown
        self._guard.write().push(guard);
    }

    /// Emit a structured log entry
    pub async fn log(&self, entry: &crate::LogEntry) -> Result<()> {
        // Emit via tracing with standard target "tillandsias"
        match entry.level.as_str() {
            "TRACE" => tracing::trace!(
                target: "tillandsias",
                component = %entry.component,
                spec = ?entry.spec_trace,
                accountability = ?entry.accountability,
                category = ?entry.category,
                "{}",
                entry.message
            ),
            "DEBUG" => tracing::debug!(
                target: "tillandsias",
                component = %entry.component,
                spec = ?entry.spec_trace,
                accountability = ?entry.accountability,
                category = ?entry.category,
                "{}",
                entry.message
            ),
            "INFO" => tracing::info!(
                target: "tillandsias",
                component = %entry.component,
                spec = ?entry.spec_trace,
                accountability = ?entry.accountability,
                category = ?entry.category,
                "{}",
                entry.message
            ),
            "WARN" => tracing::warn!(
                target: "tillandsias",
                component = %entry.component,
                spec = ?entry.spec_trace,
                accountability = ?entry.accountability,
                category = ?entry.category,
                "{}",
                entry.message
            ),
            "ERROR" => tracing::error!(
                target: "tillandsias",
                component = %entry.component,
                spec = ?entry.spec_trace,
                accountability = ?entry.accountability,
                category = ?entry.category,
                "{}",
                entry.message
            ),
            _ => {}
        }

        Ok(())
    }

    /// Manually rotate log files if needed
    pub async fn rotate_if_needed(&self) -> Result<()> {
        let main_log = self.config.log_dir.join("tillandsias.log");
        if self.rotation_policy.should_rotate(&main_log).await {
            self.rotation_policy.rotate_in_place(&main_log).await?;
        }

        if let Some(ref project_dir) = self.config.project_log_dir {
            let project_log = project_dir.join("project.log");
            if self.rotation_policy.should_rotate(&project_log).await {
                self.rotation_policy.rotate_in_place(&project_log).await?;
            }
        }

        Ok(())
    }

    /// Cleanup expired log files
    pub async fn cleanup_expired(&self) -> Result<()> {
        self.rotation_policy
            .cleanup_expired(&self.config.log_dir, "tillandsias")
            .await?;

        if let Some(ref project_dir) = self.config.project_log_dir {
            self.rotation_policy
                .cleanup_expired(project_dir, "project")
                .await?;
        }

        Ok(())
    }

    /// Get configuration
    pub fn config(&self) -> &LoggingConfig {
        &self.config
    }

    /// Check if proxy accountability logging is enabled
    pub fn is_proxy_logging_enabled(&self) -> bool {
        self.config.log_proxy
    }

    /// Check if enclave accountability logging is enabled
    pub fn is_enclave_logging_enabled(&self) -> bool {
        self.config.log_enclave
    }

    /// Check if git accountability logging is enabled
    pub fn is_git_logging_enabled(&self) -> bool {
        self.config.log_git
    }
}

impl Drop for Logger {
    fn drop(&mut self) {
        // Guards are dropped automatically, flushing any buffered events
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[tokio::test]
    async fn test_logger_creation() {
        let dir = tempdir().unwrap();
        let logger = Logger::new(Some(dir.path().to_path_buf()), None)
            .await
            .unwrap();

        assert!(logger.config.log_dir.exists());
    }

    #[tokio::test]
    async fn test_logger_rotation_check() {
        let dir = tempdir().unwrap();
        let logger = Logger::new(Some(dir.path().to_path_buf()), None)
            .await
            .unwrap();

        // Create a small log file
        let log_file = dir.path().join("tillandsias.log");
        fs::write(&log_file, "test").await.unwrap();

        // Rotation should not be needed for small file
        logger.rotate_if_needed().await.unwrap();
        let content = fs::read_to_string(&log_file).await.unwrap();
        assert_eq!(content, "test");
    }

    #[test]
    fn test_accountability_flags() {
        let config = LoggingConfig {
            log_dir: PathBuf::from("/tmp"),
            project_log_dir: None,
            env_filter: "tillandsias=info".to_string(),
            file_size_limit: 10 * 1024 * 1024,
            ttl_days: 7,
            log_proxy: true,
            log_enclave: true,
            log_git: false,
        };

        let logger = Logger {
            config,
            rotation_policy: RotationPolicy::default(),
            _guard: Arc::new(RwLock::new(Vec::new())),
        };

        assert!(logger.is_proxy_logging_enabled());
        assert!(logger.is_enclave_logging_enabled());
        assert!(!logger.is_git_logging_enabled());
    }
}
