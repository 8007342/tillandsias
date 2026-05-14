use thiserror::Error;

#[derive(Error, Debug)]
pub enum LoggingError {
    #[error("failed to create log directory: {0}")]
    DirectoryCreationFailed(#[from] std::io::Error),

    #[error("failed to write log entry: {0}")]
    WriteError(String),

    #[error("invalid log directory path: {0}")]
    InvalidPath(String),

    #[error("tracing initialization failed: {0}")]
    TracingInitFailed(String),

    #[error("rotation error: {0}")]
    RotationError(String),
}

pub type Result<T> = std::result::Result<T, LoggingError>;
