/// Abstraction over container/VM runtime backends (podman on Linux/macOS, WSL on Windows).
///
/// The Runtime trait provides a unified API for orchestrating containers across platforms.
/// Platform-specific implementations handle the differences:
/// - **Linux/macOS**: Direct podman CLI via tillandsias-podman crate
/// - **Windows**: WSL distro management (stub for now, implemented in Wave 5.2)
///
/// All methods are async and return `Result` for error handling. Container names follow
/// the convention `tillandsias-<project>-<genus>` across all platforms.
///
/// @trace spec:cross-platform, spec:podman-orchestration
use std::sync::Arc;

use tokio::sync::mpsc;

// Re-export types from client module to avoid duplication
pub use crate::client::{
    ContainerInspect, ContainerListEntry, PodmanClient, PodmanError, RunOutput,
};
use crate::events::PodmanEventStream;

/// Error type for Runtime operations. Wraps PodmanError into a unified enum.
pub type RuntimeError = PodmanError;

/// Event from container runtime (podman or WSL daemon).
#[derive(Debug, Clone)]
pub struct RuntimeEvent {
    pub container_name: String,
    pub new_state: tillandsias_core::event::ContainerState,
}

/// Unified container/VM runtime abstraction.
///
/// Implementations:
/// - `PodmanRuntime`: Linux/macOS, wraps `tillandsias_podman::PodmanClient`
/// - `WslRuntime`: Windows, manages WSL distros (stub in Wave 5.1)
///
/// All operations are async and non-blocking.
#[async_trait::async_trait]
pub trait Runtime: Send + Sync {
    // ============= Image Lifecycle =============

    /// Check if an image exists locally.
    /// On Linux/macOS: checks podman image exists.
    /// On Windows: checks if WSL distro is registered.
    async fn image_exists(&self, image: &str) -> bool;

    /// Pull/acquire an image.
    /// On Linux/macOS: podman pull.
    /// On Windows: validates WSL distro was imported via --init.
    async fn image_pull(&self, image: &str) -> Result<(), RuntimeError>;

    /// Remove an image.
    async fn image_rm(&self, image: &str) -> Result<(), RuntimeError>;

    /// Inspect an image and return JSON metadata as a string.
    async fn image_inspect(&self, image: &str) -> Result<String, RuntimeError>;

    // ============= Container Lifecycle =============

    /// Execute a command in a container, returning stdout/stderr/exit status.
    ///
    /// On Linux/macOS: `podman run --rm <args>`.
    /// On Windows: WSL command execution (TBD in Wave 5.2).
    ///
    /// The caller provides fully-formed args including security flags, volumes, etc.
    async fn container_run(&self, image: &str, args: &[String]) -> Result<RunOutput, RuntimeError>;

    /// Stop a container gracefully with timeout.
    ///
    /// On Linux/macOS: `podman stop -t <timeout_secs> <name>`.
    /// On Windows: No-op (WSL distros persist).
    async fn container_stop(&self, container: &str, timeout_secs: u32) -> Result<(), RuntimeError>;

    /// Kill a container with a signal.
    ///
    /// On Linux/macOS: `podman kill --signal <signal> <name>`.
    /// On Windows: No-op (WSL distros persist).
    async fn container_kill(
        &self,
        container: &str,
        signal: Option<&str>,
    ) -> Result<(), RuntimeError>;

    /// List all containers/distros.
    /// Returns raw output as a newline-delimited string.
    async fn container_list(&self) -> Result<String, RuntimeError>;

    /// Inspect a container and return metadata (name, state, image).
    async fn container_inspect(&self, container: &str) -> Result<ContainerInspect, RuntimeError>;

    // ============= Events =============

    /// Subscribe to container state change events.
    ///
    /// Returns a channel receiver that emits `RuntimeEvent` for containers matching the prefix.
    /// Platform-specific:
    /// - **Linux/macOS**: Consumes `podman events --format json`, falls back to exponential
    ///   backoff polling if unavailable.
    /// - **Windows**: Connects to WSL daemon socket for state changes (TBD in Wave 5.2),
    ///   falls back to polling.
    async fn subscribe_events(&self, prefix: &str) -> mpsc::Receiver<RuntimeEvent>;
}

/// Trait object type for runtime backends.
pub type RuntimeBox = Arc<dyn Runtime>;

/// Get the default Runtime for the current platform.
///
/// Returns:
/// - `PodmanRuntime` on Linux/macOS
/// - `WslRuntime` on Windows (stub in Wave 5.1, fills out in Wave 5.2)
///
/// @trace spec:cross-platform
pub fn default_runtime() -> RuntimeBox {
    #[cfg(target_os = "windows")]
    {
        Arc::new(WslRuntime::new())
    }

    #[cfg(not(target_os = "windows"))]
    {
        Arc::new(PodmanRuntime::new())
    }
}

// ============= PodmanRuntime: Linux/macOS =============

/// Container runtime backed by podman (Linux and macOS).
/// Wraps `PodmanClient` with a thin adapter layer.
#[derive(Debug, Clone)]
pub struct PodmanRuntime {
    client: PodmanClient,
}

impl PodmanRuntime {
    pub fn new() -> Self {
        Self {
            client: PodmanClient::new(),
        }
    }
}

impl Default for PodmanRuntime {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl Runtime for PodmanRuntime {
    async fn image_exists(&self, image: &str) -> bool {
        self.client.image_exists(image).await
    }

    async fn image_pull(&self, image: &str) -> Result<(), RuntimeError> {
        self.client.pull_image(image).await
    }

    async fn image_rm(&self, image: &str) -> Result<(), RuntimeError> {
        self.client.image_rm(image).await
    }

    async fn image_inspect(&self, image: &str) -> Result<String, RuntimeError> {
        self.client.image_inspect(image).await
    }

    async fn container_run(&self, image: &str, args: &[String]) -> Result<RunOutput, RuntimeError> {
        let mut full_args = vec![String::from("run")];
        full_args.extend_from_slice(args);
        full_args.push(image.to_string());

        let output = self.client.run_container(&full_args).await?;

        // The podman client returns stdout as a String; we construct RunOutput.
        // The exit status is embedded in the output or we assume success (status = 0).
        #[cfg(target_os = "windows")]
        let status = {
            use std::os::windows::process::ExitStatusExt;
            std::process::ExitStatus::from_raw(0)
        };
        #[cfg(not(target_os = "windows"))]
        let status = {
            use std::os::unix::process::ExitStatusExt;
            std::process::ExitStatus::from_raw(0)
        };

        Ok(RunOutput {
            stdout: output,
            stderr: String::new(),
            status,
        })
    }

    async fn container_stop(&self, container: &str, timeout_secs: u32) -> Result<(), RuntimeError> {
        self.client.stop_container(container, timeout_secs).await
    }

    async fn container_kill(
        &self,
        container: &str,
        signal: Option<&str>,
    ) -> Result<(), RuntimeError> {
        self.client.kill_container(container, signal).await
    }

    async fn container_list(&self) -> Result<String, RuntimeError> {
        self.client.container_list().await
    }

    async fn container_inspect(&self, container: &str) -> Result<ContainerInspect, RuntimeError> {
        let inspect = self.client.inspect_container(container).await?;

        Ok(ContainerInspect {
            name: inspect.name,
            state: inspect.state,
            image: inspect.image,
        })
    }

    async fn subscribe_events(&self, prefix: &str) -> mpsc::Receiver<RuntimeEvent> {
        let (podman_tx, mut podman_rx) = mpsc::channel(100);
        let (runtime_tx, runtime_rx) = mpsc::channel(100);
        let event_stream = PodmanEventStream::new(prefix);

        // Stream podman events
        tokio::spawn(async move {
            event_stream.stream(podman_tx).await;
        });

        // Adapt podman events to runtime events
        tokio::spawn(async move {
            while let Some(podman_event) = podman_rx.recv().await {
                let runtime_event = RuntimeEvent {
                    container_name: podman_event.container_name,
                    new_state: podman_event.new_state,
                };
                if runtime_tx.send(runtime_event).await.is_err() {
                    break; // Receiver dropped
                }
            }
        });

        runtime_rx
    }
}

// ============= WslRuntime: Windows (stub) =============

/// Container runtime backed by WSL (Windows).
/// Stub implementation for Wave 5.1; filled out in Wave 5.2 with actual WSL distro management.
///
/// @trace spec:cross-platform, spec:wsl-runtime
#[derive(Debug, Clone)]
pub struct WslRuntime;

impl WslRuntime {
    pub fn new() -> Self {
        Self
    }
}

impl Default for WslRuntime {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl Runtime for WslRuntime {
    async fn image_exists(&self, _image: &str) -> bool {
        // Stub: Wave 5.2 will check WSL distro registry
        false
    }

    async fn image_pull(&self, _image: &str) -> Result<(), RuntimeError> {
        // Stub: Wave 5.2 will validate distro was imported
        Err(RuntimeError::CommandFailed(
            "WSL runtime not yet implemented".to_string(),
        ))
    }

    async fn image_rm(&self, _image: &str) -> Result<(), RuntimeError> {
        // Stub: Wave 5.2 will unregister distro
        Err(RuntimeError::CommandFailed(
            "WSL runtime not yet implemented".to_string(),
        ))
    }

    async fn image_inspect(&self, _image: &str) -> Result<String, RuntimeError> {
        // Stub: Wave 5.2 will query distro info
        Err(RuntimeError::CommandFailed(
            "WSL runtime not yet implemented".to_string(),
        ))
    }

    async fn container_run(
        &self,
        _image: &str,
        _args: &[String],
    ) -> Result<RunOutput, RuntimeError> {
        // Stub: Wave 5.2 will execute via wsl.exe
        Err(RuntimeError::CommandFailed(
            "WSL runtime not yet implemented".to_string(),
        ))
    }

    async fn container_stop(
        &self,
        _container: &str,
        _timeout_secs: u32,
    ) -> Result<(), RuntimeError> {
        // Stub: no-op (WSL distros persist)
        Ok(())
    }

    async fn container_kill(
        &self,
        _container: &str,
        _signal: Option<&str>,
    ) -> Result<(), RuntimeError> {
        // Stub: no-op (WSL distros persist)
        Ok(())
    }

    async fn container_list(&self) -> Result<String, RuntimeError> {
        // Stub: Wave 5.2 will list WSL distros
        Err(RuntimeError::CommandFailed(
            "WSL runtime not yet implemented".to_string(),
        ))
    }

    async fn container_inspect(&self, _container: &str) -> Result<ContainerInspect, RuntimeError> {
        // Stub: Wave 5.2 will query distro info
        Err(RuntimeError::CommandFailed(
            "WSL runtime not yet implemented".to_string(),
        ))
    }

    async fn subscribe_events(&self, _prefix: &str) -> mpsc::Receiver<RuntimeEvent> {
        // Stub: Wave 5.2 will connect to WSL daemon socket
        let (_, rx) = mpsc::channel(100);
        rx
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn podman_runtime_creates() {
        let _rt = PodmanRuntime::new();
    }

    #[test]
    fn wsl_runtime_creates() {
        let _rt = WslRuntime::new();
    }

    #[test]
    fn default_runtime_compiles() {
        let _rt = default_runtime();
    }
}
