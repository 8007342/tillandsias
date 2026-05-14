// @trace spec:logging-levels
use std::path::PathBuf;
use std::str::FromStr;

/// Log level configuration
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogLevel {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

impl LogLevel {
    pub fn as_str(&self) -> &'static str {
        match self {
            LogLevel::Trace => "TRACE",
            LogLevel::Debug => "DEBUG",
            LogLevel::Info => "INFO",
            LogLevel::Warn => "WARN",
            LogLevel::Error => "ERROR",
        }
    }
}

impl FromStr for LogLevel {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_uppercase().as_str() {
            "TRACE" => Ok(LogLevel::Trace),
            "DEBUG" => Ok(LogLevel::Debug),
            "INFO" => Ok(LogLevel::Info),
            "WARN" => Ok(LogLevel::Warn),
            "ERROR" => Ok(LogLevel::Error),
            other => Err(format!("invalid log level: {}", other)),
        }
    }
}

/// Logging configuration
#[derive(Debug, Clone)]
pub struct LoggingConfig {
    /// Default log directory (~/.local/state/tillandsias/)
    pub log_dir: PathBuf,

    /// Optional per-project log directory (.tillandsias/logs/)
    pub project_log_dir: Option<PathBuf>,

    /// TILLANDSIAS_LOG env var for module-level filtering (default: "tillandsias=info")
    pub env_filter: String,

    /// File size limit in bytes (10MB default)
    pub file_size_limit: u64,

    /// TTL in days for log files (7 days default)
    pub ttl_days: u32,

    /// Enable accountability logging flags
    pub log_proxy: bool,
    pub log_enclave: bool,
    pub log_git: bool,
}

impl Default for LoggingConfig {
    fn default() -> Self {
        let log_dir = dirs::state_dir()
            .map(|d| d.join("tillandsias"))
            .unwrap_or_else(|| PathBuf::from(".tillandsias/logs"));

        Self {
            log_dir,
            project_log_dir: None,
            env_filter: std::env::var("TILLANDSIAS_LOG")
                .unwrap_or_else(|_| "tillandsias=info".to_string()),
            file_size_limit: 10 * 1024 * 1024, // 10MB
            ttl_days: 7,
            log_proxy: std::env::var("TILLANDSIAS_LOG_PROXY").is_ok(),
            log_enclave: std::env::var("TILLANDSIAS_LOG_ENCLAVE").is_ok(),
            log_git: std::env::var("TILLANDSIAS_LOG_GIT").is_ok(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_log_level_parsing() {
        assert_eq!("info".parse::<LogLevel>().unwrap(), LogLevel::Info);
        assert_eq!("ERROR".parse::<LogLevel>().unwrap(), LogLevel::Error);
        assert!("invalid".parse::<LogLevel>().is_err());
    }

    #[test]
    fn test_default_config() {
        let config = LoggingConfig::default();
        assert_eq!(config.file_size_limit, 10 * 1024 * 1024);
        assert_eq!(config.ttl_days, 7);
        assert!(config.env_filter.contains("tillandsias"));
    }
}
