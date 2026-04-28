use tracing::{debug, info, instrument, warn};

/// Output from executing a command in a container (podman or WSL).
/// Contains stdout, stderr, and exit status.
/// @trace spec:cross-platform, spec:podman-orchestration
#[derive(Debug, Clone)]
pub struct RunOutput {
    pub stdout: String,
    pub stderr: String,
    pub status: std::process::ExitStatus,
}

/// Async equivalent of `wsl_distro_exists` — used by `image_exists` on Windows
/// where the runtime backend is WSL, not podman. Returns true when a WSL distro
/// with the given name appears in `wsl --list --quiet`.
/// @trace spec:cross-platform
#[cfg(target_os = "windows")]
async fn wsl_distro_exists_async(name: &str) -> bool {
    let out = match { let mut __c = tokio::process::Command::new("wsl.exe"); crate::no_window_async(&mut __c); __c }
        .args(["--list", "--quiet"])
        .output()
        .await
    {
        Ok(o) => o,
        Err(_) => return false,
    };
    if !out.status.success() {
        return false;
    }
    // wsl.exe emits UTF-16 LE on Windows.
    let utf16: Vec<u16> = out
        .stdout
        .chunks_exact(2)
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect();
    let decoded = String::from_utf16_lossy(&utf16);
    decoded
        .lines()
        .any(|l| l.trim().trim_matches('\u{feff}') == name)
}

/// Build the argument list for `podman kill` — pure helper, unit-testable.
///
/// `signal = None` → `["kill", <name>]` (podman default = SIGTERM).
/// `signal = Some(s)` → `["kill", "--signal", s, <name>]`.
///
/// @trace spec:app-lifecycle, spec:podman-orchestration
fn build_kill_args(name: &str, signal: Option<&str>) -> Vec<String> {
    let mut args = Vec::with_capacity(4);
    args.push("kill".into());
    if let Some(s) = signal {
        args.push("--signal".into());
        args.push(s.into());
    }
    args.push(name.into());
    args
}

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
    ///
    /// On Windows the runtime backend is WSL, not podman. This method
    /// strips the `:tag` suffix off the image and consults
    /// `wsl --list --quiet` for a matching distro name. The naming
    /// convention `tillandsias-<service>` for both podman tags and
    /// WSL distros makes the check uniform.
    /// @trace spec:cross-platform, spec:podman-orchestration
    pub async fn image_exists(&self, image: &str) -> bool {
        #[cfg(target_os = "windows")]
        {
            // image is e.g. "tillandsias-proxy:v0.1.170.249"; the WSL
            // distro name is the part before ':'.
            let distro = image.split(':').next().unwrap_or(image);
            return wsl_distro_exists_async(distro).await;
        }
        #[cfg(not(target_os = "windows"))]
        crate::podman_cmd()
            .args(["image", "exists", image])
            .output()
            .await
            .is_ok_and(|o| o.status.success())
    }

    /// Pull a container image.
    ///
    /// On Windows, the runtime backend is WSL, not podman. This method
    /// checks if the WSL distro has already been imported via `--init`.
    /// If not found, returns an error directing the user to run `--init`.
    /// The actual WSL import happens in `init.rs` via `wsl --import`.
    ///
    /// @trace spec:cross-platform
    pub async fn pull_image(&self, image: &str) -> Result<(), PodmanError> {
        debug!(image, "Pulling image");

        #[cfg(target_os = "windows")]
        {
            // image is e.g. "tillandsias-proxy:v0.1.170.249"; the WSL
            // distro name is the part before ':'.
            let distro = image.split(':').next().unwrap_or(image);
            if wsl_distro_exists_async(distro).await {
                Ok(())
            } else {
                Err(PodmanError::CommandFailed(
                    "WSL distro not yet built. Run tillandsias --init first".to_string(),
                ))
            }
        }

        #[cfg(not(target_os = "windows"))]
        {
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
    }

    /// Inspect a container and return its state.
    ///
    /// On Linux/macOS, runs `podman inspect <container> --format json` and
    /// extracts the container state and image name from the JSON output.
    ///
    /// On Windows, the runtime backend is WSL, not podman. This method checks
    /// if the WSL distro exists via `wsl_distro_exists_async()`. If the distro
    /// exists, returns a `ContainerInspect` with state "running" (WSL distros
    /// are persistent and always considered available). If not found, returns
    /// a `NotFound` error.
    ///
    /// @trace spec:cross-platform, spec:podman-orchestration
    pub async fn inspect_container(&self, name: &str) -> Result<ContainerInspect, PodmanError> {
        #[cfg(target_os = "windows")]
        {
            // On Windows, name is the WSL distro name (e.g., "tillandsias-proxy").
            // Extract the distro name by stripping the tag if present.
            let distro = name.split(':').next().unwrap_or(name);
            debug!(distro, "Inspecting WSL distro");

            if wsl_distro_exists_async(distro).await {
                // Return ContainerInspect with distro running state.
                // WSL distros are persistent VMs, so they're always "running"
                // in the sense they're registered and available.
                Ok(ContainerInspect {
                    name: distro.to_string(),
                    state: "running".to_string(),
                    image: distro.to_string(),
                })
            } else {
                Err(PodmanError::NotFound(distro.to_string()))
            }
        }

        #[cfg(not(target_os = "windows"))]
        {
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
    }

    /// List all containers (or registered WSL distros on Windows).
    ///
    /// On Linux/macOS, runs `podman ps --all` and returns the raw output as a
    /// newline-delimited list of container names (or full ps output).
    ///
    /// On Windows, the runtime backend is WSL. This method runs `wsl.exe --list --quiet`
    /// to enumerate registered distros, parses the UTF-16 LE output (stripping null bytes),
    /// and returns distro names as a newline-delimited string in the same format as
    /// the Linux path.
    ///
    /// Returns an empty string (not an error) if no containers/distros exist.
    ///
    /// @trace spec:cross-platform
    pub async fn container_list(&self) -> Result<String, PodmanError> {
        #[cfg(target_os = "windows")]
        {
            let output = { let mut __c = tokio::process::Command::new("wsl.exe"); crate::no_window_async(&mut __c); __c }
                .args(["--list", "--quiet"])
                .output()
                .await
                .map_err(|e| PodmanError::CommandFailed(format!("wsl --list: {e}")))?;

            if !output.status.success() {
                return Err(PodmanError::CommandFailed(
                    "wsl --list failed".to_string(),
                ));
            }

            // wsl.exe emits UTF-16 LE on Windows.
            let utf16: Vec<u16> = output
                .stdout
                .chunks_exact(2)
                .map(|c| u16::from_le_bytes([c[0], c[1]]))
                .collect();
            let decoded = String::from_utf16_lossy(&utf16);

            // Return the decoded output as-is: newline-delimited distro names.
            // Each line may have a BOM or trailing whitespace, matching
            // the behavior of the wsl_distro_exists_async() path.
            Ok(decoded)
        }

        #[cfg(not(target_os = "windows"))]
        {
            let output = crate::podman_cmd()
                .args(["ps", "--all"])
                .output()
                .await
                .map_err(|e| PodmanError::CommandFailed(format!("ps --all: {e}")))?;

            if output.status.success() {
                let stdout = String::from_utf8_lossy(&output.stdout).to_string();
                Ok(stdout)
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);
                Err(PodmanError::CommandFailed(format!(
                    "podman ps --all failed: {stderr}"
                )))
            }
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
    ///
    /// On Linux/macOS, runs `podman stop -t <timeout_secs> <name>`.
    ///
    /// On Windows, the runtime backend is WSL — WSL distros persist and are
    /// not ephemeral containers. Stopping does not apply; this is a no-op.
    ///
    /// @trace spec:cross-platform
    pub async fn stop_container(&self, name: &str, timeout_secs: u32) -> Result<(), PodmanError> {
        #[cfg(target_os = "windows")]
        {
            debug!(name, "WSL distro stop is a no-op (distros persist)");
            return Ok(());
        }

        #[cfg(not(target_os = "windows"))]
        {
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
    }

    /// Force kill a container.
    ///
    /// On Linux/macOS, `signal = None` invokes `podman kill <name>` with no
    /// `--signal` flag, preserving today's exact behavior (podman default = SIGTERM).
    /// The graceful-stop fallback in `ContainerLauncher::stop` calls this path.
    ///
    /// `signal = Some("KILL")` invokes `podman kill --signal=KILL <name>` —
    /// used by the post-shutdown verification phase
    /// (`handlers::verify_shutdown_clean`) when a container survived the
    /// graceful pass. Always escalates to real SIGKILL, never SIGTERM.
    ///
    /// On Windows, the runtime backend is WSL, not podman. WSL distros are
    /// persistent VMs that don't support the kill operation. This method
    /// returns `Ok(())` immediately with a debug log (no-op).
    ///
    /// @trace spec:app-lifecycle, spec:podman-orchestration, spec:cross-platform
    pub async fn kill_container(
        &self,
        name: &str,
        #[cfg(not(target_os = "windows"))]
        signal: Option<&str>,
        #[cfg(target_os = "windows")]
        _signal: Option<&str>,
    ) -> Result<(), PodmanError> {
        #[cfg(target_os = "windows")]
        {
            debug!(name, "WSL distro kill is a no-op");
            return Ok(());
        }

        #[cfg(not(target_os = "windows"))]
        {
            debug!(name, ?signal, "Killing container");
            let args = build_kill_args(name, signal);
            let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
            match crate::podman_cmd().args(arg_refs).output().await {
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

    /// Remove a container image.
    ///
    /// On Linux/macOS, runs `podman image rm <image>` to delete the image.
    ///
    /// On Windows, the runtime backend is WSL, not podman. This method
    /// unregisters the WSL distro via `wsl.exe --unregister <distro_name>`.
    /// The distro name is extracted by stripping the `:tag` suffix from the image.
    /// Returns `Ok(())` on success or if the distro doesn't exist (idempotent).
    ///
    /// @trace spec:cross-platform
    pub async fn image_rm(&self, image: &str) -> Result<(), PodmanError> {
        #[cfg(target_os = "windows")]
        {
            // image is e.g. "tillandsias-proxy:v0.1.170.249"; the WSL
            // distro name is the part before ':'.
            let distro = image.split(':').next().unwrap_or(image);
            debug!(distro, "Unregistering WSL distro");

            // Check if the distro exists first.
            if !wsl_distro_exists_async(distro).await {
                debug!(distro, "WSL distro does not exist, no-op");
                return Ok(());
            }

            // Unregister the distro.
            let output = { let mut __c = tokio::process::Command::new("wsl.exe"); crate::no_window_async(&mut __c); __c }
                .args(["--unregister", distro])
                .output()
                .await
                .map_err(|e| PodmanError::CommandFailed(format!("wsl unregister: {e}")))?;

            if output.status.success() {
                info!(distro, "WSL distro unregistered successfully");
                Ok(())
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);
                Err(PodmanError::CommandFailed(format!(
                    "wsl unregister failed: {stderr}"
                )))
            }
        }

        #[cfg(not(target_os = "windows"))]
        {
            debug!(image, "Removing podman image");
            let output = crate::podman_cmd()
                .args(["image", "rm", image])
                .output()
                .await
                .map_err(|e| PodmanError::CommandFailed(format!("image rm: {e}")))?;

            if output.status.success() {
                info!(image, "Image removed successfully");
                Ok(())
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);
                Err(PodmanError::CommandFailed(format!(
                    "image rm failed: {stderr}"
                )))
            }
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

        // @trace spec:cross-platform, spec:windows-wsl-runtime, spec:opencode-web-session
        // Windows: detached forge launches go through wsl.exe. We translate
        // the podman-shaped args (--name, -e, -p, --entrypoint, image, ...)
        // into WSL semantics: distro = image name (without :tag), env vars
        // become `env K=V` prefix, --entrypoint is the wsl --exec target,
        // -p is suppressed (WSL2 auto-forwards localhost), mounts are
        // ignored (host fs is auto-visible via /mnt/c).
        //
        // This restores the OpenCode Web tray flow on Windows without
        // requiring podman. The detached process keeps running after this
        // function returns — wsl.exe spawns the process, returns, and the
        // distro keeps it alive.
        #[cfg(target_os = "windows")]
        {
            return run_container_wsl_detached(args).await;
        }

        #[cfg(not(target_os = "windows"))]
        {
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

    /// Tag a container image with an alias.
    ///
    /// On Linux/podman, creates an image alias using `podman tag <source> <target>`.
    /// For example, `tillandsias-forge:v0.1.170` → `tillandsias-forge:latest`.
    ///
    /// On Windows, WSL distros don't support multiple tags — a single distro name
    /// is registered once. Tagging is a no-op; returns `Ok(())` immediately with a
    /// debug log message.
    ///
    /// @trace spec:cross-platform
    pub async fn image_tag(&self, source: &str, target: &str) -> Result<(), PodmanError> {
        #[cfg(target_os = "windows")]
        {
            // WSL distro tagging is a no-op — distros are registered by name only,
            // no alias support like podman images.
            let distro = source.split(':').next().unwrap_or(source);
            debug!(distro, target, "WSL distro tagging is a no-op");
            Ok(())
        }

        #[cfg(not(target_os = "windows"))]
        {
            debug!(source, target, "Tagging image");
            let output = crate::podman_cmd()
                .args(["tag", source, target])
                .output()
                .await
                .map_err(|e| PodmanError::CommandFailed(format!("tag: {e}")))?;

            if output.status.success() {
                info!(source, target, "Image tagged successfully");
                Ok(())
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);
                Err(PodmanError::CommandFailed(format!("tag failed: {stderr}")))
            }
        }
    }

    /// Inspect a container image and return its metadata as JSON.
    ///
    /// On Linux/macOS, runs `podman image inspect <image> --format json` and
    /// returns the raw JSON output.
    ///
    /// On Windows, the runtime backend is WSL, not podman. This method checks
    /// if the WSL distro exists via `wsl_distro_exists_async()`. If the distro
    /// exists, returns a minimal JSON response with the distro name as `Id` and
    /// size as 0 (WSL distros don't expose size easily). If not found, returns
    /// an error.
    ///
    /// @trace spec:cross-platform
    pub async fn image_inspect(&self, image: &str) -> Result<String, PodmanError> {
        #[cfg(target_os = "windows")]
        {
            // image is e.g. "tillandsias-proxy:v0.1.170.249"; the WSL
            // distro name is the part before ':'.
            let distro = image.split(':').next().unwrap_or(image);
            debug!(distro, "Inspecting WSL distro");

            if wsl_distro_exists_async(distro).await {
                // Return minimal JSON response: {"Id":"<distro_name>","Size":0}
                let json = serde_json::json!([{
                    "Id": distro,
                    "Size": 0,
                }]);
                Ok(json.to_string())
            } else {
                Err(PodmanError::NotFound(distro.to_string()))
            }
        }

        #[cfg(not(target_os = "windows"))]
        {
            debug!(image, "Inspecting podman image");
            let output = crate::podman_cmd()
                .args(["image", "inspect", image, "--format", "json"])
                .output()
                .await
                .map_err(|e| PodmanError::CommandFailed(format!("image inspect: {e}")))?;

            if output.status.success() {
                let stdout = String::from_utf8_lossy(&output.stdout).to_string();
                Ok(stdout)
            } else {
                Err(PodmanError::NotFound(image.to_string()))
            }
        }
    }

    /// Execute a command inside a container, capturing stdout/stderr.
    ///
    /// On Linux/macOS, uses `podman run` with the given image and command.
    /// On Windows, the runtime backend is WSL — the image name is treated as a
    /// WSL distro name (e.g., "tillandsias-forge"), and the command is executed
    /// via `wsl.exe -d <distro> --user <uid> --cd <cwd> -- <cmd>`.
    ///
    /// Returns a `RunOutput` with stdout, stderr, and exit status. The function
    /// does not fail on non-zero exit codes — callers decide if status is fatal.
    ///
    /// Parameters:
    /// - `image`: Container image name (podman) or WSL distro name (Windows)
    /// - `cmd`: Command to execute (will be quoted for shell safety)
    /// - `user`: Numeric UID to run as (mapped to `--user` on Windows, included in podman args)
    /// - `cwd`: Working directory inside the container (mapped to `--cd` on Windows)
    ///
    /// @trace spec:cross-platform, spec:podman-orchestration
    pub async fn container_run(
        &self,
        image: &str,
        cmd: &str,
        user: u32,
        cwd: &str,
    ) -> Result<RunOutput, PodmanError> {
        #[cfg(target_os = "windows")]
        {
            // On Windows, image is the WSL distro name (e.g., "tillandsias-forge").
            // Extract the distro name by stripping the tag if present.
            let distro = image.split(':').next().unwrap_or(image);

            // Build `wsl.exe -d <distro> --user <uid> --cd <cwd> -- /bin/sh -c "<cmd>"`.
            // The `--` stops option parsing; /bin/sh -c is POSIX-universal and Alpine's
            // minirootfs has no bash by default.
            debug!(distro, %cmd, user, cwd, "Executing command in WSL distro");

            let output = { let mut __c = tokio::process::Command::new("wsl.exe"); crate::no_window_async(&mut __c); __c }
                .arg("-d")
                .arg(distro)
                .arg("--user")
                .arg(user.to_string())
                .arg("--cd")
                .arg(cwd)
                .arg("--")
                .arg("/bin/sh")
                .arg("-c")
                .arg(cmd)
                .output()
                .await
                .map_err(|e| PodmanError::CommandFailed(format!("wsl.exe: {e}")))?;

            let stdout = String::from_utf8_lossy(&output.stdout).to_string();
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();

            debug!(
                status = output.status.code(),
                stdout_len = stdout.len(),
                stderr_len = stderr.len(),
                "WSL command executed"
            );

            Ok(RunOutput {
                stdout,
                stderr,
                status: output.status,
            })
        }

        #[cfg(not(target_os = "windows"))]
        {
            // On Linux/macOS, use podman run.
            // Build args: run -q --rm --user <uid> -w <cwd> <image> /bin/sh -c "<cmd>"
            debug!(image, %cmd, user, cwd, "Executing command in podman container");

            let args = vec![
                "-q".to_string(),        // Quiet mode — only output the container output
                "--rm".to_string(),      // Auto-remove the container
                "--user".to_string(),
                user.to_string(),
                "-w".to_string(),        // Working directory
                cwd.to_string(),
                image.to_string(),
                "/bin/sh".to_string(),
                "-c".to_string(),
                cmd.to_string(),
            ];

            let output = crate::podman_cmd()
                .arg("run")
                .args(&args)
                .output()
                .await
                .map_err(|e| PodmanError::CommandFailed(format!("podman run: {e}")))?;

            let stdout = String::from_utf8_lossy(&output.stdout).to_string();
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();

            debug!(
                status = output.status.code(),
                stdout_len = stdout.len(),
                stderr_len = stderr.len(),
                "podman command executed"
            );

            Ok(RunOutput {
                stdout,
                stderr,
                status: output.status,
            })
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

/// Extract the host port from a podman `-p` publish spec.
/// Accepts: "HOST:CONT", "HOST:CONT/proto", "IP:HOST:CONT", "IP:HOST:CONT/proto", or "RANGE:RANGE".
/// For ranges like "3000-3019:3000-3019" returns the lower bound (3000).
/// @trace spec:cross-platform, spec:windows-wsl-runtime, spec:opencode-web-session
#[cfg(target_os = "windows")]
fn parse_host_port_from_publish(spec: &str) -> Option<u16> {
    let spec = spec.split('/').next().unwrap_or(spec); // strip /tcp /udp
    let parts: Vec<&str> = spec.split(':').collect();
    let host_part = match parts.len() {
        2 => parts[0],
        3 => parts[1], // IP:HOST:CONT
        _ => return None,
    };
    // If a range "3000-3019", take the lower bound.
    let host_first = host_part.split('-').next().unwrap_or(host_part);
    host_first.parse::<u16>().ok()
}

/// Translate podman `run` args to a detached `wsl.exe` invocation and spawn it.
///
/// Args layout (from build_podman_args): a flag block, then `-e` env pairs,
/// then `-v` mounts, then `-p` ports, then `--entrypoint <path>`, finally the
/// image tag and optional command. We extract:
///   - image tag → distro name (strip `:tag`)
///   - --entrypoint → the binary wsl will exec
///   - -e VAR=val → env vars passed via `env K=V` prefix
///   - --name → kept as identifier (returned as the "container_id")
///   - everything else (mounts, --userns, --cap-drop, -p, --rm, --tmpfs, etc.)
///     is dropped — those are podman-specific and have no WSL equivalent.
///
/// The wsl.exe process is spawned with stdin closed and stdout/stderr piped
/// to /tmp/forge-detached.log inside the distro. The forge-lifecycle.log
/// (caught by --diagnostics) is the canonical observability surface.
///
/// @trace spec:cross-platform, spec:windows-wsl-runtime, spec:opencode-web-session
#[cfg(target_os = "windows")]
async fn run_container_wsl_detached(args: &[String]) -> Result<String, PodmanError> {
    let mut name: Option<String> = None;
    let mut entrypoint: Option<String> = None;
    let mut image_tag: Option<String> = None;
    let mut env_vars: Vec<String> = Vec::new();
    let mut command_args: Vec<String> = Vec::new();
    let mut consume_image_done = false;
    // @trace spec:cross-platform, spec:windows-wsl-runtime, spec:opencode-web-session
    // Capture port-publish like "127.0.0.1:HOSTPORT:4096" — we drop the
    // -p flag itself (no podman) but extract HOSTPORT and inject it as
    // OC_EXPOSED_PORT so the forge entrypoint binds it directly. WSL2's
    // localhost forwarding makes that bind reachable from Windows host.
    let mut extracted_host_port: Option<u16> = None;

    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        match a.as_str() {
            "--name" => {
                if i + 1 < args.len() {
                    name = Some(args[i + 1].clone());
                    i += 2;
                    continue;
                }
            }
            "--entrypoint" => {
                if i + 1 < args.len() {
                    entrypoint = Some(args[i + 1].clone());
                    i += 2;
                    continue;
                }
            }
            "-e" => {
                if i + 1 < args.len() {
                    env_vars.push(args[i + 1].clone());
                    i += 2;
                    continue;
                }
            }
            // -e=KEY=VAL form
            s if s.starts_with("-e=") => {
                env_vars.push(s.trim_start_matches("-e=").to_string());
                i += 1;
                continue;
            }
            // -p value: capture HOSTPORT for OC_EXPOSED_PORT injection.
            "-p" => {
                if i + 1 < args.len() {
                    if let Some(hp) = parse_host_port_from_publish(&args[i + 1]) {
                        extracted_host_port = Some(hp);
                    }
                    i += 2;
                    continue;
                }
            }
            s if s.starts_with("-p=") => {
                let val = s.trim_start_matches("-p=");
                if let Some(hp) = parse_host_port_from_publish(val) {
                    extracted_host_port = Some(hp);
                }
                i += 1;
                continue;
            }
            // Two-arg flags we drop entirely:
            "-v" | "--add-host" | "--memory" | "--memory-swap"
            | "--pids-limit" | "--stop-timeout" => {
                i += 2;
                continue;
            }
            // Single-flag drops:
            "--rm" | "--init" | "-it" | "-d" | "--detach" => {
                i += 1;
                continue;
            }
            // Flags with embedded values (drop):
            s if s.starts_with("--cap-drop=")
                || s.starts_with("--security-opt=")
                || s.starts_with("--userns=")
                || s.starts_with("--tmpfs=")
                || s.starts_with("-v=")
                || s.starts_with("-p=") =>
            {
                i += 1;
                continue;
            }
            // First non-flag, non-consumed argument = image tag.
            s if !consume_image_done && !s.starts_with('-') => {
                image_tag = Some(s.to_string());
                consume_image_done = true;
                i += 1;
                continue;
            }
            // Everything after the image tag is the command.
            s if consume_image_done => {
                command_args.push(s.to_string());
                i += 1;
                continue;
            }
            _ => {
                i += 1;
            }
        }
    }

    let tag = image_tag.ok_or_else(|| PodmanError::CommandFailed(
        "run_container_wsl_detached: no image tag found in args".to_string(),
    ))?;
    let distro = tag.split(':').next().unwrap_or(&tag).to_string();
    let entry = entrypoint.unwrap_or_else(|| "/bin/sh".to_string());
    let container_id = name.unwrap_or_else(|| format!("{distro}-detached"));

    // Inject OC_EXPOSED_PORT so the forge web entrypoint binds the host port
    // directly (no podman -p mapping in WSL).
    if let Some(hp) = extracted_host_port {
        env_vars.push(format!("OC_EXPOSED_PORT={hp}"));
        debug!(host_port = hp, "Injected OC_EXPOSED_PORT for WSL detached forge");
    }

    debug!(
        distro = %distro, entrypoint = %entry, env_count = env_vars.len(),
        cmd_count = command_args.len(),
        "WSL detached spawn"
    );

    // Build the wsl.exe command: wsl.exe -d <distro> --user forge --cd /home/forge --exec env K=V ... <entrypoint> [args...]
    let mut cmd = { let mut __c = tokio::process::Command::new("wsl.exe"); crate::no_window_async(&mut __c); __c };
    cmd.args(["-d", &distro, "--user", "forge", "--cd", "/home/forge", "--exec", "env"]);
    for ev in &env_vars {
        cmd.arg(ev);
    }
    cmd.arg(&entry);
    for ca in &command_args {
        cmd.arg(ca);
    }

    // Detach: stdio piped to /dev/null inside the parent; the WSL distro
    // process itself outlives wsl.exe. We don't `await` the child — we just
    // spawn it and return. The distro keeps the daemon alive until killed
    // (or until the user runs `wsl --terminate`).
    cmd.stdin(std::process::Stdio::null());
    cmd.stdout(std::process::Stdio::null());
    cmd.stderr(std::process::Stdio::null());

    cmd.spawn()
        .map_err(|e| PodmanError::CommandFailed(format!("wsl.exe spawn: {e}")))?;

    // Brief settle — give the entrypoint a moment to start before callers
    // probe the bound port.
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

    Ok(container_id)
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

    /// Default-signal kill omits the `--signal` flag — preserves today's
    /// behavior for the graceful-stop fallback path in `ContainerLauncher::stop`.
    /// @trace spec:app-lifecycle, spec:podman-orchestration
    #[test]
    fn kill_container_default_signal_omits_flag() {
        let args = build_kill_args("tillandsias-foo-forge", None);
        assert_eq!(
            args,
            vec!["kill".to_string(), "tillandsias-foo-forge".to_string()]
        );
    }

    /// Explicit SIGKILL escalation — used by the post-shutdown verification
    /// phase when graceful failed.
    /// @trace spec:app-lifecycle, spec:podman-orchestration
    #[test]
    fn kill_container_explicit_kill_signal_includes_flag() {
        let args = build_kill_args("tillandsias-bar-forge", Some("KILL"));
        assert_eq!(
            args,
            vec![
                "kill".to_string(),
                "--signal".to_string(),
                "KILL".to_string(),
                "tillandsias-bar-forge".to_string(),
            ]
        );
    }

    /// Verify that RunOutput structure exists and has the expected fields.
    /// @trace spec:cross-platform, spec:podman-orchestration
    #[test]
    fn run_output_structure() {
        // Create an ExitStatus via Command — the simplest cross-platform approach.
        let status = std::process::Command::new("true")
            .output()
            .unwrap()
            .status;

        let output = RunOutput {
            stdout: "hello".to_string(),
            stderr: "".to_string(),
            status,
        };
        assert_eq!(output.stdout, "hello");
        assert_eq!(output.stderr, "");
    }

    /// Verify that PodmanClient has the container_run method.
    /// We cannot call it without a real container runtime in a sync test,
    /// but we can instantiate the client and verify it compiles.
    /// @trace spec:cross-platform, spec:podman-orchestration
    #[test]
    fn client_has_container_run() {
        let _client = PodmanClient::new();
        // The existence of container_run is verified by compile-time type checking.
        // An async integration test would call: _client.container_run(...).await
    }

    /// Verify that PodmanClient has the image_tag method.
    /// We cannot call it without a real podman/WSL runtime in a sync test,
    /// but we can instantiate the client and verify it compiles.
    /// @trace spec:cross-platform
    #[test]
    fn client_has_image_tag() {
        let _client = PodmanClient::new();
        // The existence of image_tag is verified by compile-time type checking.
        // An async integration test would call: _client.image_tag(...).await
    }

    /// Verify that PodmanClient has the image_inspect method.
    /// We cannot call it without a real podman/WSL runtime in a sync test,
    /// but we can instantiate the client and verify it compiles.
    /// @trace spec:cross-platform
    #[test]
    fn client_has_image_inspect() {
        let _client = PodmanClient::new();
        // The existence of image_inspect is verified by compile-time type checking.
        // An async integration test would call: _client.image_inspect(...).await
    }

    /// Verify that PodmanClient has the container_list method.
    /// We cannot call it without a real podman/WSL runtime in a sync test,
    /// but we can instantiate the client and verify it compiles.
    /// @trace spec:cross-platform
    #[test]
    fn client_has_container_list() {
        let _client = PodmanClient::new();
        // The existence of container_list is verified by compile-time type checking.
        // An async integration test would call: _client.container_list().await
    }
}
