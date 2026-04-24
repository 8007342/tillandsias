use tracing::{debug, info, instrument, warn};

/// Async podman CLI client. All operations are non-blocking.
#[derive(Debug, Clone)]
pub struct PodmanClient;

impl PodmanClient {
    pub fn new() -> Self {
        Self
    }

    /// Check if podman is available in PATH.
    pub async fn is_available(&self) -> bool {
        crate::podman_cmd()
            .arg("--version")
            .output()
            .await
            .is_ok_and(|o| o.status.success())
    }

    /// Check if any Podman Machine exists (macOS/Windows).
    pub async fn has_machine(&self) -> bool {
        let output = crate::podman_cmd()
            .args(["machine", "list", "--format", "json"])
            .output()
            .await;

        match output {
            Ok(o) if o.status.success() => {
                let stdout = String::from_utf8_lossy(&o.stdout).trim().to_string();
                // Empty array or empty output means no machines
                !stdout.is_empty() && stdout != "[]"
            }
            _ => false,
        }
    }

    /// Initialize a new Podman Machine (macOS/Windows). Returns true on success.
    ///
    /// Uses `--disk-size=10` to limit the VM to 10GB instead of the default
    /// 20GB. The enclave runs lean containers (forge <400MB, inference <500MB,
    /// proxy <25MB, git <30MB) so 10GB is sufficient with headroom for models.
    ///
    /// @trace spec:cross-platform
    pub async fn init_machine(&self) -> bool {
        info!("Initializing podman machine (disk-size=10GB)...");
        let output = crate::podman_cmd()
            .args(["machine", "init", "--disk-size", "10"])
            .output()
            .await;

        match output {
            Ok(o) if o.status.success() => {
                info!("Podman machine initialized successfully");
                true
            }
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                warn!(%stderr, "Podman machine init failed");
                false
            }
            Err(e) => {
                warn!(%e, "Podman machine init command error");
                false
            }
        }
    }

    /// Check if Podman Machine is running (macOS/Windows).
    pub async fn is_machine_running(&self) -> bool {
        let output = crate::podman_cmd()
            .args(["machine", "list", "--format", "json"])
            .output()
            .await;

        match output {
            Ok(o) if o.status.success() => {
                let stdout = String::from_utf8_lossy(&o.stdout);
                // Check if any machine has "Running": true (not just the key name)
                stdout.contains("\"Running\": true") || stdout.contains("\"Running\":true")
            }
            _ => false,
        }
    }

    /// Start the podman machine (macOS/Windows). Returns true on success.
    pub async fn start_machine(&self) -> bool {
        info!("Starting podman machine...");
        let output = crate::podman_cmd()
            .args(["machine", "start"])
            .output()
            .await;

        match output {
            Ok(o) if o.status.success() => {
                info!("Podman machine started successfully");
                true
            }
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                warn!(%stderr, "Podman machine start failed");
                false
            }
            Err(e) => {
                warn!(%e, "Podman machine start command error");
                false
            }
        }
    }

    /// Wait for podman to be ready to accept commands after machine start.
    /// Polls `podman --version` with exponential backoff up to `max_attempts`.
    /// Returns true if podman became ready, false if all attempts exhausted.
    pub async fn wait_for_ready(&self, max_attempts: u32) -> bool {
        let mut delay = std::time::Duration::from_millis(500);
        for attempt in 1..=max_attempts {
            if self.is_available().await {
                info!(attempt, "Podman API ready after machine start");
                return true;
            }
            debug!(
                attempt,
                delay_ms = delay.as_millis() as u64,
                "Waiting for podman API..."
            );
            tokio::time::sleep(delay).await;
            delay = (delay * 2).min(std::time::Duration::from_secs(4));
        }
        false
    }

    /// Check if a container image exists locally.
    pub async fn image_exists(&self, image: &str) -> bool {
        crate::podman_cmd()
            .args(["image", "exists", image])
            .output()
            .await
            .is_ok_and(|o| o.status.success())
    }

    /// Pull a container image.
    pub async fn pull_image(&self, image: &str) -> Result<(), PodmanError> {
        debug!(image, "Pulling image");
        let output = crate::podman_cmd()
            .args(["pull", image])
            .output()
            .await
            .map_err(|e| PodmanError::CommandFailed(format!("pull: {e}")))?;

        if output.status.success() {
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(PodmanError::CommandFailed(format!("pull failed: {stderr}")))
        }
    }

    /// Inspect a container and return its state.
    pub async fn inspect_container(&self, name: &str) -> Result<ContainerInspect, PodmanError> {
        let output = crate::podman_cmd()
            .args(["inspect", name, "--format", "json"])
            .output()
            .await
            .map_err(|e| PodmanError::CommandFailed(format!("inspect: {e}")))?;

        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let inspects: Vec<serde_json::Value> = serde_json::from_str(&stdout)
                .map_err(|e| PodmanError::ParseError(format!("inspect parse: {e}")))?;

            if let Some(inspect) = inspects.first() {
                let state = inspect["State"]["Status"]
                    .as_str()
                    .unwrap_or("unknown")
                    .to_string();
                let image = inspect["ImageName"]
                    .as_str()
                    .unwrap_or("")
                    .to_string();
                Ok(ContainerInspect {
                    name: name.to_string(),
                    state,
                    image,
                })
            } else {
                Err(PodmanError::NotFound(name.to_string()))
            }
        } else {
            Err(PodmanError::NotFound(name.to_string()))
        }
    }

    /// List containers matching a name prefix.
    pub async fn list_containers(
        &self,
        prefix: &str,
    ) -> Result<Vec<ContainerListEntry>, PodmanError> {
        let output = crate::podman_cmd()
            .args([
                "ps",
                "-a",
                "--filter",
                &format!("name=^{prefix}"),
                "--format",
                "json",
            ])
            .output()
            .await
            .map_err(|e| PodmanError::CommandFailed(format!("ps: {e}")))?;

        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            if stdout.trim().is_empty() || stdout.trim() == "[]" {
                return Ok(Vec::new());
            }
            let entries: Vec<PodmanPsEntry> = serde_json::from_str(&stdout)
                .map_err(|e| PodmanError::ParseError(format!("ps parse: {e}")))?;

            Ok(entries
                .into_iter()
                .map(|e| ContainerListEntry {
                    name: e.names.first().cloned().unwrap_or_default(),
                    state: e.state,
                })
                .collect())
        } else {
            Ok(Vec::new())
        }
    }

    /// Stop a container gracefully.
    pub async fn stop_container(&self, name: &str, timeout_secs: u32) -> Result<(), PodmanError> {
        debug!(name, timeout_secs, "Stopping container");
        let output = crate::podman_cmd()
            .args(["stop", "-t", &timeout_secs.to_string(), name])
            .output()
            .await
            .map_err(|e| PodmanError::CommandFailed(format!("stop: {e}")))?;

        if output.status.success() {
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            warn!(name, %stderr, "Container stop returned error");
            // Not necessarily fatal — container may already be stopped
            Ok(())
        }
    }

    /// Force kill a container.
    pub async fn kill_container(&self, name: &str) -> Result<(), PodmanError> {
        debug!(name, "Killing container");
        match crate::podman_cmd().args(["kill", name]).output().await {
            Ok(output) if !output.status.success() => {
                let stderr = String::from_utf8_lossy(&output.stderr);
                warn!(name, %stderr, "Container kill failed — may already be stopped");
            }
            Err(e) => {
                warn!(name, error = %e, "Container kill command failed");
            }
            _ => {}
        }
        Ok(())
    }

    /// Remove a container.
    pub async fn remove_container(&self, name: &str) -> Result<(), PodmanError> {
        debug!(name, "Removing container");
        match crate::podman_cmd().args(["rm", "-f", name]).output().await {
            Ok(output) if !output.status.success() => {
                let stderr = String::from_utf8_lossy(&output.stderr);
                warn!(name, %stderr, "Container removal failed — may not exist");
            }
            Err(e) => {
                warn!(name, error = %e, "Container removal command failed");
            }
            _ => {}
        }
        Ok(())
    }

    /// Build a container image from a Containerfile.
    #[instrument(skip(self), fields(image.tag = %tag))]
    pub async fn build_image(
        &self,
        containerfile: &str,
        tag: &str,
        context_dir: &str,
    ) -> Result<(), PodmanError> {
        debug!(tag, containerfile, context_dir, "Building image");
        let start = std::time::Instant::now();
        let output = crate::podman_cmd()
            .args(["build", "-t", tag, "-f", containerfile, context_dir])
            .output()
            .await
            .map_err(|e| PodmanError::CommandFailed(format!("build: {e}")))?;

        if output.status.success() {
            let elapsed = start.elapsed().as_secs_f64();
            info!(duration_secs = elapsed, "Image build complete");
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(PodmanError::CommandFailed(format!(
                "build failed: {stderr}"
            )))
        }
    }

    /// Build image only if it doesn't already exist.
    #[instrument(skip(self), fields(image.tag = %tag))]
    pub async fn ensure_image_built(
        &self,
        tag: &str,
        containerfile: &str,
        context_dir: &str,
    ) -> Result<(), PodmanError> {
        if self.image_exists(tag).await {
            debug!(tag, "Image already exists, skipping build");
            return Ok(());
        }
        self.build_image(containerfile, tag, context_dir).await
    }

    /// Load a container image from a tarball (produced by nix build).
    #[instrument(skip(self), fields(tarball = %tarball_path))]
    pub async fn load_image(&self, tarball_path: &str) -> Result<(), PodmanError> {
        debug!(tarball_path, "Loading image from tarball");
        let start = std::time::Instant::now();
        let output = crate::podman_cmd()
            .args(["load", "-i", tarball_path])
            .output()
            .await
            .map_err(|e| PodmanError::CommandFailed(format!("load: {e}")))?;

        if output.status.success() {
            let elapsed = start.elapsed().as_secs_f64();
            info!(duration_secs = elapsed, "Image loaded from tarball");
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(PodmanError::CommandFailed(format!("load failed: {stderr}")))
        }
    }

    /// Check if a podman network exists.
    /// @trace spec:enclave-network
    pub async fn network_exists(&self, name: &str) -> bool {
        crate::podman_cmd()
            .args(["network", "exists", name])
            .output()
            .await
            .is_ok_and(|o| o.status.success())
    }

    /// Create an internal podman network.
    /// Runs: `podman network create <name> --internal`
    /// @trace spec:enclave-network
    pub async fn create_internal_network(&self, name: &str) -> Result<(), PodmanError> {
        debug!(name, "Creating internal network");
        let output = crate::podman_cmd()
            .args(["network", "create", name, "--internal"])
            .output()
            .await
            .map_err(|e| PodmanError::CommandFailed(format!("network create: {e}")))?;

        if output.status.success() {
            info!(name, "Internal network created");
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(PodmanError::CommandFailed(format!(
                "network create failed: {stderr}"
            )))
        }
    }

    /// Remove a podman network. Returns Ok(()) even on failure (callers handle gracefully).
    /// @trace spec:enclave-network
    ///
    /// Uses `podman network rm -f` so any lingering attached container
    /// (e.g. an exited forge that wasn't yet `podman rm`-ed) does not block
    /// teardown. The `-f` flag disconnects attached containers before removing
    /// the network, which is exactly the behaviour the shutdown path wants
    /// — we've already stopped those containers, we just want the network gone.
    pub async fn remove_network(&self, name: &str) -> Result<(), PodmanError> {
        debug!(name, "Removing network (force)");
        let output = crate::podman_cmd()
            .args(["network", "rm", "-f", name])
            .output()
            .await
            .map_err(|e| PodmanError::CommandFailed(format!("network rm: {e}")))?;

        if output.status.success() {
            info!(name, "Network removed");
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            tracing::error!(name, %stderr, "Network removal failed");
        }
        Ok(())
    }

    /// Start a container with the given arguments.
    pub async fn run_container(&self, args: &[String]) -> Result<String, PodmanError> {
        debug!(?args, "Running container");
        let output = crate::podman_cmd()
            .arg("run")
            .args(args)
            .output()
            .await
            .map_err(|e| PodmanError::CommandFailed(format!("run: {e}")))?;

        if output.status.success() {
            let container_id = String::from_utf8_lossy(&output.stdout).trim().to_string();
            Ok(container_id)
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Err(PodmanError::CommandFailed(format!("run failed: {stderr}")))
        }
    }
}

impl Default for PodmanClient {
    fn default() -> Self {
        Self::new()
    }
}

/// Check if a podman network exists (sync, for CLI mode).
/// @trace spec:enclave-network
pub fn network_exists_sync(name: &str) -> bool {
    crate::podman_cmd_sync()
        .args(["network", "exists", name])
        .output()
        .is_ok_and(|o| o.status.success())
}

#[derive(Debug, Clone)]
pub struct ContainerInspect {
    pub name: String,
    pub state: String,
    pub image: String,
}

#[derive(Debug, Clone)]
pub struct ContainerListEntry {
    pub name: String,
    pub state: String,
}

#[derive(Debug, serde::Deserialize)]
struct PodmanPsEntry {
    #[serde(rename = "Names")]
    names: Vec<String>,
    #[serde(rename = "State")]
    state: String,
}

#[derive(Debug, thiserror::Error)]
pub enum PodmanError {
    #[error("Command failed: {0}")]
    CommandFailed(String),
    #[error("Container not found: {0}")]
    NotFound(String),
    #[error("Parse error: {0}")]
    ParseError(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    /// @trace spec:enclave-network
    #[test]
    fn enclave_network_constant_value() {
        assert_eq!(crate::ENCLAVE_NETWORK, "tillandsias-enclave");
    }

    /// Verify PodmanClient has network_exists method and it returns bool.
    /// We cannot call podman in tests, but we can instantiate the client.
    /// @trace spec:enclave-network
    #[test]
    fn client_has_network_methods() {
        let _client = PodmanClient::new();
        // Compile-time verification: these methods exist with correct signatures.
        // The async methods are tested by type — calling them would require a runtime
        // and a real podman socket.
        let _ = PodmanClient::network_exists;
        let _ = PodmanClient::create_internal_network;
        let _ = PodmanClient::remove_network;
    }

    /// Verify the sync network_exists_sync function exists and compiles.
    /// @trace spec:enclave-network
    #[test]
    fn network_exists_sync_compiles() {
        let _ = network_exists_sync as fn(&str) -> bool;
    }
}
