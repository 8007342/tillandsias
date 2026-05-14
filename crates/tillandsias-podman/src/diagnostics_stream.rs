// @trace spec:runtime-diagnostics-stream
//! Linux/macOS implementation of live container log streaming via `podman logs -f`.
//!
//! This module implements the runtime-diagnostics-stream capability for Linux and macOS
//! platforms, providing multiplexed, prefixed log output from all enclave containers
//! (proxy, git, inference, forge) for real-time observability.

use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Child;
use tokio::sync::mpsc;
use tracing::{debug, warn};

/// A single log stream from `podman logs -f <container>`.
pub struct ContainerLogStream {
    container_name: String,
    child: Child,
}

impl ContainerLogStream {
    /// Create and spawn a new log stream for the given container.
    ///
    /// The stream will use `podman logs -f` to follow container output in real-time.
    /// Returns None if the container is not running or does not exist.
    pub async fn spawn(container_name: impl Into<String>) -> Result<Self, DiagnosticsError> {
        let container_name = container_name.into();
        debug!(%container_name, "Starting log stream");

        let child = crate::podman_cmd()
            .args(["logs", "-f", &container_name])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| DiagnosticsError::SpawnFailed {
                container: container_name.clone(),
                reason: e.to_string(),
            })?;

        Ok(Self { container_name, child })
    }

    /// Read and forward log lines from this container's stream.
    ///
    /// Each line is prefixed with `[<container_name>]` and sent to the provided channel.
    /// Stops when the stream ends or the channel closes.
    pub async fn forward_lines(&mut self, tx: mpsc::UnboundedSender<String>) -> Result<(), DiagnosticsError> {
        if let Some(stdout) = self.child.stdout.take() {
            let reader = BufReader::new(stdout);
            let mut lines = reader.lines();

            while let Some(line) = lines.next_line().await
                .map_err(|e| DiagnosticsError::ReadFailed {
                    container: self.container_name.clone(),
                    reason: e.to_string(),
                })?
            {
                let prefixed = format!("[{}] {}", self.container_name, line);
                if tx.send(prefixed).is_err() {
                    // Channel closed, clean shutdown
                    return Ok(());
                }
            }
        }

        Ok(())
    }

    /// Get the container name for this stream.
    pub fn container_name(&self) -> &str {
        &self.container_name
    }

    /// Wait for the stream to finish (blocking).
    pub async fn wait(&mut self) -> Result<(), DiagnosticsError> {
        self.child.wait().await
            .map_err(|e| DiagnosticsError::WaitFailed {
                container: self.container_name.clone(),
                reason: e.to_string(),
            })?;
        Ok(())
    }
}

impl Drop for ContainerLogStream {
    fn drop(&mut self) {
        // Kill the podman logs process on drop to ensure clean shutdown.
        // @trace spec:runtime-diagnostics-stream
        if let Ok(child) = self.child.try_wait() {
            if child.is_none() {
                // Process is still running, kill it
                let _ = self.child.kill();
            }
        }
    }
}

/// Multiplex multiple container log streams and forward lines to stdout.
///
/// This handle manages multiple `podman logs -f` processes and ensures clean
/// shutdown when the diagnostics session ends.
pub struct DiagnosticsHandle {
    join_handles: Vec<tokio::task::JoinHandle<()>>,
}

impl DiagnosticsHandle {
    /// Create a new diagnostics session with streams for the given containers.
    ///
    /// Each container logs to stdout with a `[<container_name>]` prefix.
    /// Failures to spawn individual streams are logged but do not stop the process.
    ///
    /// # Arguments
    /// * `container_names` - List of container names to stream logs from
    ///
    /// # Returns
    /// A handle that keeps the log streams alive. Dropping it stops all streams.
    pub async fn start(container_names: Vec<String>) -> Self {
        let (tx, mut rx) = mpsc::unbounded_channel();

        let mut join_handles = Vec::new();

        // Spawn a task for each container's log stream.
        for container_name in container_names {
            let tx = tx.clone();

            let task = tokio::spawn(async move {
                match ContainerLogStream::spawn(&container_name).await {
                    Ok(mut stream) => {
                        debug!(container = %container_name, "Log stream started");
                        if let Err(e) = stream.forward_lines(tx).await {
                            warn!(
                                container = %container_name,
                                %e,
                                "Log stream failed"
                            );
                        }
                    }
                    Err(e) => {
                        warn!(
                            container = %container_name,
                            %e,
                            "Failed to start log stream"
                        );
                    }
                }
            });

            join_handles.push(task);
        }

        // Drop the original sender so the channel only has senders from stream tasks
        drop(tx);

        // Spawn a task to read from the channel and print prefixed lines.
        let print_task = tokio::spawn(async move {
            while let Some(line) = rx.recv().await {
                println!("{}", line);
            }
        });

        join_handles.push(print_task);

        Self { join_handles }
    }

    /// Wait for all log streams to complete.
    pub async fn wait_all(&mut self) {
        for handle in &mut self.join_handles {
            let _ = handle.await;
        }
    }
}

impl Drop for DiagnosticsHandle {
    fn drop(&mut self) {
        // Abort all running tasks to ensure clean shutdown.
        // @trace spec:runtime-diagnostics-stream
        for handle in &self.join_handles {
            handle.abort();
        }
    }
}

/// Error types for diagnostics streaming.
#[derive(Debug, thiserror::Error)]
pub enum DiagnosticsError {
    #[error("Failed to spawn stream for {container}: {reason}")]
    SpawnFailed { container: String, reason: String },

    #[error("Failed to read from {container}: {reason}")]
    ReadFailed { container: String, reason: String },

    #[error("Failed to wait on {container}: {reason}")]
    WaitFailed { container: String, reason: String },

    #[error("Container not found: {0}")]
    ContainerNotFound(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_diagnostics_error_display() {
        let err = DiagnosticsError::SpawnFailed {
            container: "tillandsias-test-forge".to_string(),
            reason: "container not found".to_string(),
        };
        assert!(err.to_string().contains("tillandsias-test-forge"));
        assert!(err.to_string().contains("container not found"));
    }

    #[test]
    fn test_diagnostics_error_container_not_found() {
        let err = DiagnosticsError::ContainerNotFound("missing-container".to_string());
        assert!(err.to_string().contains("missing-container"));
    }

    #[test]
    fn test_enclave_container_info_creation() {
        let info = crate::EnclaveContainerInfo {
            name: "tillandsias-myapp-aeranthos".to_string(),
            state: "Running".to_string(),
        };
        assert_eq!(info.name, "tillandsias-myapp-aeranthos");
        assert_eq!(info.state, "Running");
    }
}
