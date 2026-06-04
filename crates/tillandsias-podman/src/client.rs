// @trace spec:security-privacy-isolation, spec:podman-idiomatic-patterns
use std::process::Stdio;
use std::sync::Arc;

use tracing::{debug, info, instrument, warn};

use crate::backend::{BackendRef, CommandFailure, OperationKind, RealBackend, redact_argv};
use crate::diagnostics::{ContainerDiagnostics, LogTail};

/// Output from executing a command in a container (podman or WSL).
/// Contains stdout, stderr, and exit status.
/// @trace spec:cross-platform, spec:podman-orchestration
#[derive(Debug, Clone)]
pub struct RunOutput {
    pub stdout: String,
    pub stderr: String,
    pub status: std::process::ExitStatus,
}

#[cfg(unix)]
fn exit_status_from_code(code: Option<i32>) -> std::process::ExitStatus {
    use std::os::unix::process::ExitStatusExt;
    std::process::ExitStatus::from_raw(code.unwrap_or(1) << 8)
}

#[cfg(windows)]
fn exit_status_from_code(code: Option<i32>) -> std::process::ExitStatus {
    use std::os::windows::process::ExitStatusExt;
    std::process::ExitStatus::from_raw(code.unwrap_or(1) as u32)
}

/// Async equivalent of `wsl_distro_exists` — used by `image_exists` on Windows
/// where the runtime backend is WSL, not podman. Returns true when a WSL distro
/// with the given name appears in `wsl --list --quiet`.
/// @trace spec:cross-platform
#[cfg(target_os = "windows")]
async fn wsl_distro_exists_async(name: &str) -> bool {
    let out = match {
        let mut __c = tokio::process::Command::new("wsl.exe");
        crate::no_window_async(&mut __c);
        __c
    }
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
#[derive(Clone)]
pub struct PodmanClient {
    backend: BackendRef,
}

impl std::fmt::Debug for PodmanClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PodmanClient").finish_non_exhaustive()
    }
}

impl PodmanClient {
    pub fn new() -> Self {
        Self {
            backend: Arc::new(RealBackend),
        }
    }

    pub fn with_backend(backend: BackendRef) -> Self {
        Self { backend }
    }

    pub async fn execute(
        &self,
        operation: OperationKind,
        argv: &[String],
    ) -> Result<crate::CommandOutput, CommandFailure> {
        self.backend.execute(operation, argv).await
    }

    /// Check if podman is available in PATH.
    pub async fn is_available(&self) -> bool {
        self.execute(OperationKind::Availability, &["--version".into()])
            .await
            .is_ok()
    }

    /// Check if any Podman Machine exists (macOS/Windows).
    pub async fn has_machine(&self) -> bool {
        match self
            .execute(
                OperationKind::Availability,
                &[
                    "machine".into(),
                    "list".into(),
                    "--format".into(),
                    "json".into(),
                ],
            )
            .await
        {
            Ok(output) => {
                let stdout = output.stdout.trim().to_string();
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
        match self
            .execute(
                OperationKind::Availability,
                &[
                    "machine".into(),
                    "init".into(),
                    "--disk-size".into(),
                    "10".into(),
                ],
            )
            .await
        {
            Ok(_) => {
                info!("Podman machine initialized successfully");
                true
            }
            Err(failure) => {
                warn!(error = %failure, "Podman machine init failed");
                false
            }
        }
    }

    /// Check if Podman Machine is running (macOS/Windows).
    pub async fn is_machine_running(&self) -> bool {
        match self
            .execute(
                OperationKind::Availability,
                &[
                    "machine".into(),
                    "list".into(),
                    "--format".into(),
                    "json".into(),
                ],
            )
            .await
        {
            Ok(output) => {
                let stdout = output.stdout;
                // Check if any machine has "Running": true (not just the key name)
                stdout.contains("\"Running\": true") || stdout.contains("\"Running\":true")
            }
            _ => false,
        }
    }

    /// Start the podman machine (macOS/Windows). Returns true on success.
    pub async fn start_machine(&self) -> bool {
        info!("Starting podman machine...");
        match self
            .execute(
                OperationKind::Availability,
                &["machine".into(), "start".into()],
            )
            .await
        {
            Ok(_) => {
                info!("Podman machine started successfully");
                true
            }
            Err(failure) => {
                warn!(error = %failure, "Podman machine start failed");
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
        {
            self.execute(
                OperationKind::Image,
                &["image".into(), "exists".into(), image.into()],
            )
            .await
            .is_ok()
        }
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
            self.execute(OperationKind::Image, &["pull".into(), image.into()])
                .await
                .map(|_| ())
                .map_err(PodmanError::CommandFailure)
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
            match self
                .execute(
                    OperationKind::Inspect,
                    &[
                        "inspect".into(),
                        name.into(),
                        "--format".into(),
                        "json".into(),
                    ],
                )
                .await
            {
                Ok(output) => {
                    let inspects: Vec<serde_json::Value> = serde_json::from_str(&output.stdout)
                        .map_err(|e| PodmanError::ParseError(format!("inspect parse: {e}")))?;

                    if let Some(inspect) = inspects.first() {
                        let state = inspect["State"]["Status"]
                            .as_str()
                            .unwrap_or("unknown")
                            .to_string();
                        let image = inspect["ImageName"].as_str().unwrap_or("").to_string();
                        Ok(ContainerInspect {
                            name: name.to_string(),
                            state,
                            image,
                        })
                    } else {
                        Err(PodmanError::NotFound(name.to_string()))
                    }
                }
                Err(_) => Err(PodmanError::NotFound(name.to_string())),
            }
        }
    }

    /// Return the published host port for a container port, if Podman has one.
    ///
    /// On Linux/macOS this runs `podman port <name> <container_port>/tcp` and
    /// parses the first published mapping. A missing or failed mapping returns
    /// `Ok(None)` so callers can distinguish "running but unmapped" from a hard
    /// Podman failure elsewhere.
    pub async fn container_host_port(
        &self,
        name: &str,
        container_port: u16,
    ) -> Result<Option<u16>, PodmanError> {
        let Ok(output) = self
            .execute(
                OperationKind::Inspect,
                &["port".into(), name.into(), format!("{container_port}/tcp")],
            )
            .await
        else {
            return Ok(None);
        };

        for line in output.stdout.lines() {
            let port = line
                .rsplit(':')
                .next()
                .and_then(|candidate| candidate.trim().parse::<u16>().ok());
            if port.is_some() {
                return Ok(port);
            }
        }

        Ok(None)
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
            let output = {
                let mut __c = tokio::process::Command::new("wsl.exe");
                crate::no_window_async(&mut __c);
                __c
            }
            .args(["--list", "--quiet"])
            .output()
            .await
            .map_err(|e| PodmanError::CommandFailed(format!("wsl --list: {e}")))?;

            if !output.status.success() {
                return Err(PodmanError::CommandFailed("wsl --list failed".to_string()));
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
            self.execute(OperationKind::Container, &["ps".into(), "--all".into()])
                .await
                .map(|output| output.stdout)
                .map_err(PodmanError::CommandFailure)
        }
    }

    /// List containers matching a name prefix.
    pub async fn list_containers(
        &self,
        prefix: &str,
    ) -> Result<Vec<ContainerListEntry>, PodmanError> {
        match self
            .execute(
                OperationKind::Container,
                &[
                    "ps".into(),
                    "-a".into(),
                    "--filter".into(),
                    format!("name=^{prefix}"),
                    "--format".into(),
                    "json".into(),
                ],
            )
            .await
        {
            Ok(output) => {
                if output.stdout.trim().is_empty() || output.stdout.trim() == "[]" {
                    return Ok(Vec::new());
                }
                let entries: Vec<PodmanPsEntry> = serde_json::from_str(&output.stdout)
                    .map_err(|e| PodmanError::ParseError(format!("ps parse: {e}")))?;

                Ok(entries
                    .into_iter()
                    .map(|e| ContainerListEntry {
                        name: e.names.first().cloned().unwrap_or_default(),
                        state: e.state,
                    })
                    .collect())
            }
            Err(_) => Ok(Vec::new()),
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
            let args = vec![
                "stop".into(),
                "-t".into(),
                timeout_secs.to_string(),
                name.to_string(),
            ];
            match self.execute(OperationKind::Container, &args).await {
                Ok(_) => Ok(()),
                Err(failure) => {
                    warn!(name, error = %failure, "Container stop returned error");
                    Ok(())
                }
            }
        }
    }

    /// Start a container.
    ///
    /// This is the lifecycle counterpart to `stop_container` and is used by
    /// shell wrappers that need to reuse a pre-created container without
    /// re-encoding Podman's runtime policy.
    pub async fn start_container(&self, name: &str) -> Result<(), PodmanError> {
        #[cfg(target_os = "windows")]
        {
            debug!(name, "WSL distro start is a no-op");
            return Ok(());
        }

        #[cfg(not(target_os = "windows"))]
        {
            debug!(name, "Starting container");
            self.execute(OperationKind::Container, &["start".into(), name.into()])
                .await
                .map(|_| ())
                .map_err(PodmanError::CommandFailure)
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
        #[cfg(not(target_os = "windows"))] signal: Option<&str>,
        #[cfg(target_os = "windows")] _signal: Option<&str>,
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
            if let Err(failure) = self.execute(OperationKind::Container, &args).await {
                warn!(name, error = %failure, "Container kill failed — may already be stopped");
            }
            Ok(())
        }
    }

    /// Remove a container.
    pub async fn remove_container(&self, name: &str) -> Result<(), PodmanError> {
        debug!(name, "Removing container");
        let args = vec!["rm".into(), "-f".into(), name.to_string()];
        if let Err(failure) = self.execute(OperationKind::Container, &args).await {
            warn!(name, error = %failure, "Container removal failed — may not exist");
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
        build_args: &[String],
    ) -> Result<(), PodmanError> {
        debug!(tag, containerfile, context_dir, "Building image");
        let mut args = vec!["build".into(), "-t".into(), tag.into()];
        args.extend_from_slice(build_args);
        args.extend(["-f".into(), containerfile.into(), context_dir.into()]);
        let output = self.execute(OperationKind::Image, &args).await;

        if let Ok(output) = output {
            let elapsed = output.duration.as_secs_f64();
            info!(duration_secs = elapsed, "Image build complete");
            Ok(())
        } else {
            Err(PodmanError::CommandFailure(output.err().unwrap()))
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
        self.build_image(containerfile, tag, context_dir, &[]).await
    }

    /// Load a container image from a tarball (produced by nix build).
    #[instrument(skip(self), fields(tarball = %tarball_path))]
    pub async fn load_image(&self, tarball_path: &str) -> Result<(), PodmanError> {
        debug!(tarball_path, "Loading image from tarball");
        match self
            .execute(
                OperationKind::Image,
                &["load".into(), "-i".into(), tarball_path.into()],
            )
            .await
        {
            Ok(output) => {
                let elapsed = output.duration.as_secs_f64();
                info!(duration_secs = elapsed, "Image loaded from tarball");
                Ok(())
            }
            Err(failure) => Err(PodmanError::CommandFailure(failure)),
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
            let output = {
                let mut __c = tokio::process::Command::new("wsl.exe");
                crate::no_window_async(&mut __c);
                __c
            }
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
            self.execute(
                OperationKind::Image,
                &["image".into(), "rm".into(), image.into()],
            )
            .await
            .map(|_| {
                info!(image, "Image removed successfully");
            })
            .map_err(PodmanError::CommandFailure)
        }
    }

    /// Check if a podman network exists.
    /// @trace spec:enclave-network
    pub async fn network_exists(&self, name: &str) -> bool {
        self.execute(
            OperationKind::Network,
            &["network".into(), "exists".into(), name.into()],
        )
        .await
        .is_ok()
    }

    /// Create an internal podman network.
    /// Runs: `podman network create <name> --internal`
    /// @trace spec:enclave-network
    pub async fn create_internal_network(&self, name: &str) -> Result<(), PodmanError> {
        debug!(name, "Creating internal network");
        let args = vec![
            "network".into(),
            "create".into(),
            name.into(),
            "--internal".into(),
        ];
        self.execute(OperationKind::Network, &args)
            .await
            .map(|_| {
                info!(name, "Internal network created");
            })
            .map_err(PodmanError::CommandFailure)
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
        let args = vec!["network".into(), "rm".into(), "-f".into(), name.into()];
        if let Err(failure) = self.execute(OperationKind::Network, &args).await {
            tracing::error!(name, error = %failure, "Network removal failed");
        } else {
            info!(name, "Network removed");
        }
        Ok(())
    }

    /// Start a container with the given arguments.
    pub async fn run_container(&self, args: &[String]) -> Result<String, PodmanError> {
        debug!(?args, "Running container");

        // @trace spec:cross-platform, spec:windows-wsl-runtime, spec:browser-isolation-tray-integration
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
            let mut full_args = vec!["run".to_string()];
            full_args.extend_from_slice(args);
            match self.execute(OperationKind::Container, &full_args).await {
                Ok(output) => Ok(output.stdout.trim().to_string()),
                Err(failure) => Err(PodmanError::CommandFailure(failure)),
            }
        }
    }

    /// Run a detached/background container and render user-actionable
    /// diagnostics on failure.
    ///
    /// @trace spec:podman-idiomatic-patterns, spec:runtime-diagnostics-stream
    pub async fn run_container_observed(
        &self,
        stage: &str,
        container_name: &str,
        args: &[String],
        debug_enabled: bool,
    ) -> Result<String, String> {
        emit_launch_event(debug_enabled, stage, container_name, "starting", None);
        match self.run_container(args).await {
            Ok(output) => {
                emit_launch_event(debug_enabled, stage, container_name, "running", None);
                Ok(output)
            }
            Err(err) => {
                let detail = self
                    .format_observed_launch_failure(stage, container_name, args, &err)
                    .await;
                emit_launch_event(
                    debug_enabled,
                    stage,
                    container_name,
                    "failed",
                    Some(summary_line(&detail)),
                );
                Err(detail)
            }
        }
    }

    /// Run an interactive container attached to the current terminal.
    ///
    /// This inherits stdio so TUI agents receive a real terminal, while still
    /// reporting structured launch events and post-failure diagnostics.
    /// @trace spec:podman-idiomatic-patterns, spec:runtime-diagnostics-stream
    pub async fn run_container_attached_observed(
        &self,
        stage: &str,
        container_name: &str,
        args: &[String],
        debug_enabled: bool,
    ) -> Result<(), String> {
        emit_launch_event(
            debug_enabled,
            stage,
            container_name,
            "starting",
            Some("attached=true"),
        );

        let mut full_args = vec!["run".to_string()];
        full_args.extend_from_slice(args);
        let mut cmd = crate::podman_cmd();
        cmd.args(&full_args)
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
        // User-visible --debug log; honors TILLANDSIAS_DEBUG or the per-launch
        // debug_enabled flag passed in by the caller.
        crate::log_podman_invocation_with_flag(
            &format!("run-attached:{stage}"),
            cmd.as_std(),
            debug_enabled,
        );
        let status = cmd.status().await.map_err(|err| {
            let message = format!(
                "stage '{stage}' could not spawn attached container {container_name}: {err}\nnext: verify podman is available in this desktop session\nredacted argv: podman {}",
                redact_argv(&full_args).join(" ")
            );
            crate::log_podman_failure(
                &format!("run-attached:{stage}"),
                "spawn-error",
                &err.to_string(),
            );
            emit_launch_event(
                debug_enabled,
                stage,
                container_name,
                "failed",
                Some(summary_line(&message)),
            );
            message
        })?;

        if status.success() {
            emit_launch_event(
                debug_enabled,
                stage,
                container_name,
                "exited",
                Some("status=0"),
            );
            return Ok(());
        }

        let status_code = status
            .code()
            .map(|code| code.to_string())
            .unwrap_or_else(|| "signal".to_string());
        crate::log_podman_failure(
            &format!("run-attached:{stage}"),
            &status_code,
            "(stderr inherited to terminal)",
        );
        let detail = format_attached_command_failure(stage, container_name, &status_code);
        emit_launch_event(
            debug_enabled,
            stage,
            container_name,
            "failed",
            Some(summary_line(&detail)),
        );
        Err(detail)
    }

    async fn format_observed_launch_failure(
        &self,
        stage: &str,
        container_name: &str,
        args: &[String],
        err: &PodmanError,
    ) -> String {
        let mut diagnostics = self.diagnostics_snapshot(container_name).await;
        if let PodmanError::CommandFailure(failure) = err {
            diagnostics.failure = Some(failure.clone());
        }

        let mut full_args = vec!["run".to_string()];
        full_args.extend_from_slice(args);

        let mut parts = vec![format!(
            "stage '{stage}' failed for container {container_name}"
        )];
        // Step 15 slice 4: when the failure is a known exit-125 pattern (network
        // missing / port already bound / image not found), prepend a single
        // actionable typed line BEFORE the verbose cause+hint+argv chain so the
        // operator sees what to do without parsing the podman stderr cascade.
        if let PodmanError::CommandFailure(failure) = err
            && let Some(typed) = classify_typed_launch_failure(failure)
        {
            parts.push(typed);
        }
        parts.extend([
            format!("cause: {err}"),
            observed_failure_hint(stage, container_name, args),
            format!(
                "redacted argv: podman {}",
                redact_argv(&full_args).join(" ")
            ),
        ]);
        let rendered = diagnostics.render_human();
        if !rendered.trim().is_empty() {
            parts.push(rendered);
        }
        parts.join("\n")
    }

    pub async fn wait_healthy(&self, name: &str) -> Result<(), PodmanError> {
        let args = vec![
            "wait".into(),
            "--condition=healthy".into(),
            name.to_string(),
        ];
        self.execute(OperationKind::Health, &args)
            .await
            .map(|_| ())
            .map_err(PodmanError::CommandFailure)
    }

    pub async fn log_tail(&self, name: &str, lines: usize) -> Result<LogTail, PodmanError> {
        let args = vec![
            "logs".into(),
            "--tail".into(),
            lines.to_string(),
            name.to_string(),
        ];
        let output = self
            .execute(OperationKind::Logs, &args)
            .await
            .map_err(PodmanError::CommandFailure)?;
        Ok(LogTail {
            lines: output.stdout.lines().map(ToOwned::to_owned).collect(),
        })
    }

    pub async fn diagnostics_snapshot(&self, name: &str) -> ContainerDiagnostics {
        let inspect = self.inspect_container(name).await.ok();
        let logs = self.log_tail(name, 40).await.unwrap_or_default();
        ContainerDiagnostics {
            name: name.to_string(),
            state: inspect.as_ref().map(|i| i.state.clone()),
            image: inspect.as_ref().map(|i| i.image.clone()),
            health: None,
            inspect_json: None,
            log_tail: logs,
            command: None,
            failure: None,
        }
    }

    /// Tag a container image with an alias.
    ///
    /// On Linux/podman, creates an image alias using `podman tag <source> <target>`.
    /// For example, `tillandsias-forge:v0.1.170` -> `localhost/tillandsias-forge:v0.1.170`.
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
            self.execute(
                OperationKind::Image,
                &["tag".into(), source.into(), target.into()],
            )
            .await
            .map(|_| {
                info!(source, target, "Image tagged successfully");
            })
            .map_err(PodmanError::CommandFailure)
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
            self.execute(
                OperationKind::Inspect,
                &[
                    "image".into(),
                    "inspect".into(),
                    image.into(),
                    "--format".into(),
                    "json".into(),
                ],
            )
            .await
            .map(|output| output.stdout)
            .map_err(|_| PodmanError::NotFound(image.to_string()))
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

            let output = {
                let mut __c = tokio::process::Command::new("wsl.exe");
                crate::no_window_async(&mut __c);
                __c
            }
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
                "-q".to_string(),   // Quiet mode — only output the container output
                "--rm".to_string(), // Auto-remove the container
                "--user".to_string(),
                user.to_string(),
                "-w".to_string(), // Working directory
                cwd.to_string(),
                image.to_string(),
                "/bin/sh".to_string(),
                "-c".to_string(),
                cmd.to_string(),
            ];

            let mut full_args = vec!["run".to_string()];
            full_args.extend(args);
            let output = self
                .execute(OperationKind::Container, &full_args)
                .await
                .map_err(PodmanError::CommandFailure)?;

            debug!(
                status = output.status,
                stdout_len = output.stdout.len(),
                stderr_len = output.stderr.len(),
                "podman command executed"
            );

            Ok(RunOutput {
                stdout: output.stdout,
                stderr: output.stderr,
                status: exit_status_from_code(output.status),
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
    let mut cmd = crate::podman_cmd_sync();
    cmd.args(["network", "exists", name]);
    crate::log_podman_invocation("network-exists", &cmd);
    let out = cmd.output();
    if let Ok(ref o) = out
        && !o.status.success()
    {
        crate::log_podman_failure(
            "network-exists",
            &o.status
                .code()
                .map(|c| c.to_string())
                .unwrap_or_else(|| "signal".into()),
            &String::from_utf8_lossy(&o.stderr),
        );
    }
    out.is_ok_and(|o| o.status.success())
}

/// Check whether podman is available in the current environment (sync).
pub fn podman_available_sync() -> bool {
    let mut cmd = crate::podman_cmd_sync();
    cmd.arg("--version");
    crate::log_podman_invocation("available", &cmd);
    let out = cmd.output();
    if let Ok(ref o) = out
        && !o.status.success()
    {
        crate::log_podman_failure(
            "available",
            &o.status
                .code()
                .map(|c| c.to_string())
                .unwrap_or_else(|| "signal".into()),
            &String::from_utf8_lossy(&o.stderr),
        );
    }
    out.is_ok_and(|o| o.status.success())
}

/// Check whether an image exists locally (sync).
pub fn image_exists_sync(image: &str) -> bool {
    let mut cmd = crate::podman_cmd_sync();
    cmd.args(["image", "exists", image]);
    crate::log_podman_invocation("image-exists", &cmd);
    // Non-existence is the common case; do not log a failure line for it.
    cmd.output().is_ok_and(|o| o.status.success())
}

/// Check whether a container exists locally (sync).
pub fn container_exists_sync(name: &str) -> bool {
    let mut cmd = crate::podman_cmd_sync();
    cmd.args(["inspect", name]);
    crate::log_podman_invocation("container-exists", &cmd);
    // Non-existence is the common case; do not log a failure line for it.
    cmd.output().is_ok_and(|o| o.status.success())
}

/// Stop a container gracefully (sync).
pub fn stop_container_sync(name: &str, timeout_secs: u32) -> Result<(), PodmanError> {
    let mut cmd = crate::podman_cmd_sync();
    cmd.args(["stop", "-t", &timeout_secs.to_string(), name]);
    crate::log_podman_invocation("stop", &cmd);
    let output = cmd.output().map_err(|e| {
        crate::log_podman_failure("stop", "spawn-error", &e.to_string());
        PodmanError::CommandFailed(format!("stop: {e}"))
    })?;

    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        crate::log_podman_failure(
            "stop",
            &output
                .status
                .code()
                .map(|c| c.to_string())
                .unwrap_or_else(|| "signal".into()),
            &stderr,
        );
        Err(PodmanError::CommandFailed(if stderr.is_empty() {
            format!("stop failed for {name} with status {}", output.status)
        } else {
            format!("stop failed for {name}: {stderr}")
        }))
    }
}

/// Extract the host port from a podman `-p` publish spec.
/// Accepts: "HOST:CONT", "HOST:CONT/proto", "IP:HOST:CONT", "IP:HOST:CONT/proto", or "RANGE:RANGE".
/// For ranges like "3000-3019:3000-3019" returns the lower bound (3000).
/// @trace spec:cross-platform, spec:windows-wsl-runtime, spec:browser-isolation-tray-integration
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
/// to /tmp/forge-detached.log inside the distro. The forge-lifecycle.log is
/// the canonical observability surface for runtime-diagnostics-stream.
///
/// @trace spec:cross-platform, spec:windows-wsl-runtime, spec:browser-isolation-tray-integration
#[cfg(target_os = "windows")]
async fn run_container_wsl_detached(args: &[String]) -> Result<String, PodmanError> {
    let mut name: Option<String> = None;
    let mut entrypoint: Option<String> = None;
    let mut image_tag: Option<String> = None;
    let mut env_vars: Vec<String> = Vec::new();
    let mut command_args: Vec<String> = Vec::new();
    let mut consume_image_done = false;
    // @trace spec:cross-platform, spec:windows-wsl-runtime, spec:browser-isolation-tray-integration
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
            "-v" | "--add-host" | "--memory" | "--memory-swap" | "--pids-limit"
            | "--stop-timeout" => {
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

    let tag = image_tag.ok_or_else(|| {
        PodmanError::CommandFailed(
            "run_container_wsl_detached: no image tag found in args".to_string(),
        )
    })?;
    let distro = tag.split(':').next().unwrap_or(&tag).to_string();
    let entry = entrypoint.unwrap_or_else(|| "/bin/sh".to_string());
    let container_id = name.unwrap_or_else(|| format!("{distro}-detached"));

    // Inject OC_EXPOSED_PORT so the forge web entrypoint binds the host port
    // directly (no podman -p mapping in WSL).
    if let Some(hp) = extracted_host_port {
        env_vars.push(format!("OC_EXPOSED_PORT={hp}"));
        debug!(
            host_port = hp,
            "Injected OC_EXPOSED_PORT for WSL detached forge"
        );
    }

    debug!(
        distro = %distro, entrypoint = %entry, env_count = env_vars.len(),
        cmd_count = command_args.len(),
        "WSL detached spawn"
    );

    // Build the wsl.exe command: wsl.exe -d <distro> --user forge --cd /home/forge --exec env K=V ... <entrypoint> [args...]
    let mut cmd = {
        let mut __c = tokio::process::Command::new("wsl.exe");
        crate::no_window_async(&mut __c);
        __c
    };
    cmd.args([
        "-d",
        &distro,
        "--user",
        "forge",
        "--cd",
        "/home/forge",
        "--exec",
        "env",
    ]);
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
    #[error("Stream error: {0}")]
    StreamError(String),
    #[error("{0}")]
    CommandFailure(CommandFailure),
}

impl PodmanError {
    /// Classify whether this error is transient (retry-safe) or permanent (propagate).
    ///
    /// Transient errors (should retry):
    /// - `StreamError` — EOF or connection loss on event stream
    /// - `CommandFailed` containing "timeout" or "connection refused"
    ///
    /// Permanent errors (propagate immediately):
    /// - `NotFound` — container/image does not exist
    /// - `ParseError` — malformed JSON or other unrecoverable parse failure
    /// - `CommandFailed` with exit code 125 or containing "permission denied"
    ///
    /// @trace spec:podman-idiomatic-patterns
    pub fn is_transient(&self) -> bool {
        match self {
            PodmanError::StreamError(_) => true,
            PodmanError::CommandFailure(failure) => {
                failure.retry == crate::backend::RetryClass::Retryable
            }
            PodmanError::CommandFailed(msg) => {
                msg.contains("timeout") || msg.contains("connection refused")
            }
            PodmanError::NotFound(_) | PodmanError::ParseError(_) => false,
        }
    }
}

fn emit_launch_event(
    enabled: bool,
    stage: &str,
    container_name: &str,
    state: &str,
    detail: Option<&str>,
) {
    if !enabled {
        return;
    }
    // Consult the process-wide diagnostics filter (env-driven; see
    // crate::diagnostics_filter). The filter is built once per process
    // and pass-through unless the user set TILLANDSIAS_DEBUG_FILTER /
    // TILLANDSIAS_DEBUG_CONTAINER / TILLANDSIAS_DEBUG_LEVEL.
    //
    // @trace spec:runtime-diagnostics-stream (Requirement: Event filtering and control)
    if !crate::diagnostics_filter::DiagnosticsFilter::global()
        .allows("event:container_launch", container_name)
    {
        return;
    }
    eprintln!(
        "[{}] {}",
        iso8601_millis(chrono::Utc::now()),
        format_launch_event(stage, container_name, state, detail)
    );
}

/// Format a UTC instant as the runtime-diagnostics-stream timestamp:
/// `2026-05-03T14:23:45.123Z` (ISO 8601 UTC, millisecond precision). Pure +
/// testable; `emit_launch_event` prepends `[<this>] ` to every event line so
/// the stream is ordered + parseable per spec:runtime-diagnostics-stream.
fn iso8601_millis(dt: chrono::DateTime<chrono::Utc>) -> String {
    dt.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()
}

/// Build the idiomatic-layer container-launch diagnostics line. Extracted so
/// the exact wire shape is unit-pinnable — litmus tests grep this stream
/// (`event:container_launch ... state=running|failed`) to verify containers
/// start correctly via the shared layer rather than raw podman. Keep the
/// `key=value` field order stable: assertions depend on it.
///
/// @trace spec:runtime-diagnostics-stream, spec:podman-idiomatic-patterns
fn format_launch_event(
    stage: &str,
    container_name: &str,
    state: &str,
    detail: Option<&str>,
) -> String {
    let mut line = format!(
        "event:container_launch stage={} state={} container={}",
        shell_escape_field(stage),
        shell_escape_field(state),
        shell_escape_field(container_name)
    );
    if let Some(detail) = detail {
        line.push_str(" detail=");
        line.push_str(&shell_escape_field(detail));
    }
    line
}

/// Build the diagnostics-stream container-start line. Field order is
/// `container`, `status` — pinned by unit test so litmus assertions can grep on it.
///
/// @trace spec:runtime-diagnostics-stream (scenario "Container start event")
pub(crate) fn format_container_start_event(container_name: &str, status: &str) -> String {
    format!(
        "event:container_start container={} status={}",
        shell_escape_field(container_name),
        shell_escape_field(status)
    )
}

/// Build the diagnostics-stream container-exit line. Field order is
/// `container`, `exit_code`, optional `duration_seconds` — pinned by unit
/// test so litmus assertions can grep on it.
///
/// The four typed-event formatters below are intentionally STAGED ahead of
/// the PodmanEventStream → diagnostics emitter wiring (tracked as gap-2/
/// gap-3 in plan/issues/linux-headless-spec-gaps-2026-05-27.md). Pinning
/// the wire shape now via unit tests means the live-runtime wiring slice
/// doesn't have to relitigate field order or escaping.
///
/// @trace spec:runtime-diagnostics-stream (scenario "Container exit event")
#[allow(dead_code)] // staged for diagnostics-stream wiring slice (gap-2/gap-3)
pub(crate) fn format_container_exit_event(
    container_name: &str,
    exit_code: i32,
    duration_seconds: Option<u64>,
) -> String {
    let mut line = format!(
        "event:container_exit container={} exit_code={}",
        shell_escape_field(container_name),
        exit_code
    );
    if let Some(secs) = duration_seconds {
        line.push_str(&format!(" duration_seconds={secs}"));
    }
    line
}

/// Build the diagnostics-stream container-signal line. Signals carry the
/// short name (`SIGTERM`, `SIGSEGV`, `SIGKILL`, ...) so operators don't have
/// to translate numeric codes from podman's raw event payload.
///
/// @trace spec:runtime-diagnostics-stream (scenario "Container signal event")
#[allow(dead_code)] // staged for diagnostics-stream wiring slice (gap-2/gap-3)
pub(crate) fn format_container_signal_event(container_name: &str, signal: &str) -> String {
    format!(
        "event:container_signal container={} signal={}",
        shell_escape_field(container_name),
        shell_escape_field(signal)
    )
}

/// Build the diagnostics-stream resource-exhaustion line. `resource` is a
/// short identifier such as `memory_oom` or `disk_full`; `limit_bytes` is
/// optional because not every resource is byte-quantified (e.g. file
/// descriptors). Keep field order stable.
///
/// @trace spec:runtime-diagnostics-stream (scenario "Resource event (OOM, disk)")
#[allow(dead_code)] // staged for diagnostics-stream wiring slice (gap-2/gap-3)
pub(crate) fn format_resource_exhaustion_event(
    container_name: &str,
    resource: &str,
    limit_bytes: Option<u64>,
) -> String {
    let mut line = format!(
        "event:resource_exhaustion container={} resource={}",
        shell_escape_field(container_name),
        shell_escape_field(resource)
    );
    if let Some(bytes) = limit_bytes {
        line.push_str(&format!(" limit_bytes={bytes}"));
    }
    line
}

/// Build the diagnostics-stream container-stderr pass-through line. The raw
/// stderr line is shell-escaped so embedded whitespace/quotes survive as a
/// single grep-able value — spec mandates one event per terminal line.
///
/// @trace spec:runtime-diagnostics-stream (scenario "Stderr line pass-through")
#[allow(dead_code)] // staged for diagnostics-stream wiring slice (gap-2/gap-3)
pub(crate) fn format_container_stderr_event(container_name: &str, line: &str) -> String {
    format!(
        "event:container_stderr container={} line={}",
        shell_escape_field(container_name),
        shell_escape_field(line)
    )
}

/// Emit a typed diagnostic-stream event to stderr with the ISO-8601 prefix
/// the spec mandates. Mirrors `emit_launch_event` — gated on `enabled` so
/// callers can pass the runtime `debug` flag without branching themselves,
/// and consults the global `DiagnosticsFilter` so
/// `TILLANDSIAS_DEBUG_FILTER`/`TILLANDSIAS_DEBUG_CONTAINER` env vars take
/// effect uniformly across all typed events.
///
/// `event_type` MUST be the wire-shape event kind (`event:container_exit`,
/// `event:container_signal`, ...) so the filter can match it. `container`
/// MUST be the literal container name as emitted in the event body, so a
/// `TILLANDSIAS_DEBUG_CONTAINER=tillandsias-myproject-*` glob can target
/// it. `event_body` MUST be the body produced by one of
/// `format_container_exit_event`, `format_container_signal_event`,
/// `format_resource_exhaustion_event`, or `format_container_stderr_event`.
#[allow(dead_code)] // staged for diagnostics-stream wiring slice (gap-2/gap-3)
pub(crate) fn emit_diagnostic_event(
    enabled: bool,
    event_type: &str,
    container: &str,
    event_body: &str,
) {
    if !enabled {
        return;
    }
    if !crate::diagnostics_filter::DiagnosticsFilter::global().allows(event_type, container) {
        return;
    }
    eprintln!("[{}] {}", iso8601_millis(chrono::Utc::now()), event_body);
}

fn summary_line(value: &str) -> &str {
    value.lines().next().unwrap_or(value)
}

/// Step 15 slice 4: collapse the exit-125 cascade into a single actionable
/// typed error line.
///
/// `podman run` returns exit 125 for *many* distinct conditions (network
/// missing, image not found, port-bind conflict, rootless setup errors, …).
/// Operators historically saw the same generic "stage X failed" wrapper for
/// each, so the actual root cause was buried in the stderr that the
/// `cause:` line carried forward verbatim. This classifier inspects the
/// CommandFailure and, for known patterns, returns a SINGLE line the
/// operator can act on without parsing podman stderr.
///
/// Returns `None` when the failure does not match a known typed pattern —
/// the caller then falls back to the generic stage-keyed hint.
///
/// @trace plan/steps/15-tray-network-bootstrap.md, spec:enclave-network
pub(crate) fn classify_typed_launch_failure(
    failure: &crate::backend::CommandFailure,
) -> Option<String> {
    if failure.output.status != Some(125) {
        return None;
    }
    let stderr_lc = failure.output.stderr.to_ascii_lowercase();

    // Enclave network missing — `ensure_enclave_network` did not run, or
    // ran and failed silently before this spawn. This is a Step 15
    // ordering regression by definition. Match podman 4.x + 5.x stderr.
    if stderr_lc.contains("network")
        && (stderr_lc.contains("not found")
            || stderr_lc.contains("does not exist")
            || stderr_lc.contains("no such network"))
    {
        return Some(
            "typed-error: enclave network missing — ensure_enclave_network must run before this \
             spawn; this is a Step 15 ordering regression (see plan/steps/15-tray-network-bootstrap.md)"
                .to_string(),
        );
    }

    // Host port conflict — the router or a sibling service is holding
    // the port we tried to publish. Actionable: kill the orphan or pick
    // a new port.
    if stderr_lc.contains("address already in use")
        || stderr_lc.contains("port is already allocated")
        || stderr_lc.contains("bind: permission denied")
    {
        return Some(
            "typed-error: host port already bound — kill the prior tillandsias process holding \
             the port (try `podman ps -a` + `pkill tillandsias`) or pick a different port"
                .to_string(),
        );
    }

    // Image missing — the recipe pull/build step didn't deposit this
    // tag locally. Actionable: re-run the materializer / pull pass.
    if (stderr_lc.contains("no such image") || stderr_lc.contains("image not known"))
        || stderr_lc.contains("manifest unknown")
    {
        return Some(
            "typed-error: container image is not present locally — run the materializer \
             (`cargo run -p tillandsias-vm-layer --features materialize --bin materialize-cli`) \
             or `podman pull` the missing tag before this spawn"
                .to_string(),
        );
    }

    None
}

fn observed_failure_hint(stage: &str, _container_name: &str, args: &[String]) -> String {
    let joined = args.join(" ");
    if joined.contains("TILLANDSIAS_PROJECT_HOST_MOUNT=1") {
        return "next: check the entrypoint logs above; this launch uses a protected host-mounted project and must not wipe or clone over it".to_string();
    }
    if stage.contains("git") {
        return "next: inspect the git mirror container logs and verify the project mirror exists"
            .to_string();
    }
    if stage.contains("inference") {
        return "next: inspect the inference container logs; local models may still be starting"
            .to_string();
    }
    if stage.contains("proxy") {
        return "next: inspect the proxy container logs and CA bundle mounts".to_string();
    }
    "next: inspect the entrypoint lines immediately above and the rendered container diagnostics below".to_string()
}

fn format_attached_command_failure(stage: &str, container_name: &str, status_code: &str) -> String {
    let mut lines = vec![
        format!("stage '{stage}' attached command exited with status {status_code}"),
        format!("container: {container_name}"),
        "cause: the container launched and the foreground tool exited non-zero".to_string(),
    ];

    if matches!(stage, "claude" | "codex" | "opencode") {
        lines.push(
            "next: read the agent output immediately above; auth, upstream service, or model availability errors are agent/runtime issues, not podman launch failures"
                .to_string(),
        );
    } else {
        lines.push(
            "next: read the terminal output immediately above; the runtime stack was started and the foreground command returned this status"
                .to_string(),
        );
    }

    lines.join("\n")
}

fn shell_escape_field(value: &str) -> String {
    if value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.' | '/' | ':' | '='))
    {
        return value.to_string();
    }

    let mut escaped = String::from("\"");
    for ch in value.chars() {
        match ch {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            c if c.is_control() => escaped.push_str(&format!("\\u{:04x}", c as u32)),
            c => escaped.push(c),
        }
    }
    escaped.push('"');
    escaped
}

/// Information about a container in the enclave.
#[derive(Debug, Clone)]
pub struct EnclaveContainerInfo {
    pub name: String,
    pub state: String,
}

impl PodmanClient {
    /// Get all active containers in the Tillandsias enclave with the given project prefix.
    ///
    /// Returns containers matching `tillandsias-<project>-*` naming scheme.
    /// @trace spec:runtime-diagnostics-stream
    pub async fn get_enclave_containers(
        &self,
        project_prefix: &str,
    ) -> Result<Vec<EnclaveContainerInfo>, PodmanError> {
        let filter_prefix = format!("tillandsias-{project_prefix}-");
        let containers = self.list_containers(&filter_prefix).await?;

        Ok(containers
            .into_iter()
            .map(|c| EnclaveContainerInfo {
                name: c.name,
                state: c.state,
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::{CommandFailure, CommandOutput, OperationKind, RetryClass};
    use std::time::Duration;

    fn fake_failure(status: Option<i32>, stderr: &str) -> CommandFailure {
        CommandFailure {
            output: Box::new(CommandOutput {
                operation: OperationKind::Container,
                argv: vec!["run".into()],
                redacted_argv: vec!["run".into()],
                status,
                stdout: String::new(),
                stderr: stderr.into(),
                duration: Duration::ZERO,
            }),
            retry: RetryClass::Unknown,
        }
    }

    /// Step 15 slice 4: the canonical "network does not exist" cascade
    /// produces a single actionable typed-error line.
    /// @trace plan/steps/15-tray-network-bootstrap.md
    #[test]
    fn classify_typed_125_network_missing() {
        let f = fake_failure(Some(125), r#"Error: network not found"#);
        let typed = classify_typed_launch_failure(&f).expect("should classify");
        assert!(
            typed.starts_with("typed-error: enclave network missing"),
            "got: {typed}"
        );
        assert!(typed.contains("Step 15"));
    }

    #[test]
    fn classify_typed_125_network_missing_alt_phrasing() {
        // podman 4.x sometimes reports "does not exist"; 5.x sometimes
        // reports "no such network".
        for stderr in [
            "Error: network tillandsias-enclave does not exist",
            "Error: no such network: tillandsias-enclave",
        ] {
            let f = fake_failure(Some(125), stderr);
            let typed = classify_typed_launch_failure(&f)
                .unwrap_or_else(|| panic!("should classify: {stderr}"));
            assert!(typed.starts_with("typed-error: enclave network missing"));
        }
    }

    #[test]
    fn classify_typed_125_port_bound() {
        let f = fake_failure(
            Some(125),
            "Error: rootlessport listen tcp 0.0.0.0:8443: bind: address already in use",
        );
        let typed = classify_typed_launch_failure(&f).expect("should classify");
        assert!(
            typed.starts_with("typed-error: host port already bound"),
            "got: {typed}"
        );
    }

    #[test]
    fn classify_typed_125_image_missing() {
        let f = fake_failure(
            Some(125),
            "Error: short-name resolution failed: no such image \"tillandsias-router:v0\"",
        );
        let typed = classify_typed_launch_failure(&f).expect("should classify");
        assert!(
            typed.starts_with("typed-error: container image is not present locally"),
            "got: {typed}"
        );
    }

    /// Non-125 exit codes are not classified — we don't want false
    /// positives swallowing legitimate runtime errors.
    #[test]
    fn classify_typed_only_fires_on_125() {
        let f = fake_failure(Some(1), "Error: network not found");
        assert!(classify_typed_launch_failure(&f).is_none());
        let f = fake_failure(None, "Error: network not found");
        assert!(classify_typed_launch_failure(&f).is_none());
    }

    /// Generic exit-125 with unrecognized stderr falls through to None so
    /// the operator gets the stage-keyed hint instead.
    #[test]
    fn classify_typed_unknown_125_falls_through() {
        let f = fake_failure(Some(125), "Error: some unrecognized failure");
        assert!(classify_typed_launch_failure(&f).is_none());
    }

    /// Pins the idiomatic-layer container-launch diagnostics wire shape that
    /// the container-start-health litmus greps. If this changes, update
    /// openspec/litmus-tests/litmus-container-start-health.yaml in lockstep.
    /// @trace spec:runtime-diagnostics-stream, spec:podman-idiomatic-patterns
    #[test]
    fn launch_event_line_shape_is_stable() {
        let running = format_launch_event("forge", "tillandsias-acme-forge", "running", None);
        assert_eq!(
            running,
            "event:container_launch stage=forge state=running container=tillandsias-acme-forge"
        );
        // Field order is stage, state, container — litmus assertions depend on it.
        assert!(running.starts_with("event:container_launch stage="));
        assert!(running.contains(" state=running "));

        let failed =
            format_launch_event("router", "tillandsias-router", "failed", Some("exit 125"));
        assert_eq!(
            failed,
            "event:container_launch stage=router state=failed container=tillandsias-router detail=\"exit 125\""
        );
    }

    /// The diagnostics timestamp is ISO 8601 UTC with millisecond precision
    /// and a trailing Z (spec:runtime-diagnostics-stream). Pinned against a
    /// fixed instant so it's deterministic.
    #[test]
    fn iso8601_millis_shape() {
        use chrono::TimeZone;
        let dt = chrono::Utc
            .with_ymd_and_hms(2026, 5, 3, 14, 23, 45)
            .unwrap()
            + chrono::Duration::milliseconds(123);
        assert_eq!(iso8601_millis(dt), "2026-05-03T14:23:45.123Z");
        // Always 3 fractional digits + trailing Z, even on a whole second.
        let whole = chrono::Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap();
        assert_eq!(iso8601_millis(whole), "2026-01-01T00:00:00.000Z");
    }

    /// A whitespace/special-char detail is quoted (shell_escape_field) so a
    /// grep-based litmus parse stays single-line and unambiguous.
    #[test]
    fn launch_event_detail_is_escaped() {
        let line = format_launch_event("git", "c", "starting", Some("multi word detail"));
        assert!(
            line.ends_with("detail=\"multi word detail\""),
            "got: {line}"
        );
    }

    /// Pins the `event:container_start` wire shape from
    /// spec:runtime-diagnostics-stream. Field order is `container`, `status`.
    #[test]
    fn container_start_event_shape() {
        let running = format_container_start_event("tillandsias-myproject-foo", "running");
        assert_eq!(
            running,
            "event:container_start container=tillandsias-myproject-foo status=running"
        );
    }

    /// Pins the `event:container_exit` wire shape from
    /// spec:runtime-diagnostics-stream verbatim. Field order is
    /// `container`, `exit_code`, optional `duration_seconds` — litmus
    /// assertions and the (future) PodmanEvents → diagnostics emitter both
    /// depend on this ordering.
    #[test]
    fn container_exit_event_shape() {
        let zero = format_container_exit_event("tillandsias-myproject-foo", 0, Some(25));
        assert_eq!(
            zero,
            "event:container_exit container=tillandsias-myproject-foo exit_code=0 duration_seconds=25"
        );
        // No duration when we can't pair start→exit (start lost across
        // restarts, observed-only via inspect, ...).
        let no_dur = format_container_exit_event("tillandsias-x", 137, None);
        assert_eq!(
            no_dur,
            "event:container_exit container=tillandsias-x exit_code=137"
        );
        // Negative exit codes (signal-killed reported as -N by some
        // runtimes) survive without mangling.
        let neg = format_container_exit_event("c", -11, None);
        assert!(neg.contains(" exit_code=-11"), "got: {neg}");
    }

    /// Pins the `event:container_signal` wire shape from
    /// spec:runtime-diagnostics-stream. Signals are emitted by short name
    /// (SIGTERM, SIGSEGV, ...) — operators should not need to translate
    /// numeric codes from podman's raw payload.
    #[test]
    fn container_signal_event_shape() {
        let line = format_container_signal_event("tillandsias-myproject-foo", "SIGSEGV");
        assert_eq!(
            line,
            "event:container_signal container=tillandsias-myproject-foo signal=SIGSEGV"
        );
    }

    /// Pins the `event:resource_exhaustion` wire shape from
    /// spec:runtime-diagnostics-stream. `limit_bytes` is optional because
    /// not every resource is byte-quantified.
    #[test]
    fn resource_exhaustion_event_shape() {
        let oom = format_resource_exhaustion_event(
            "tillandsias-myproject-foo",
            "memory_oom",
            Some(2_147_483_648),
        );
        assert_eq!(
            oom,
            "event:resource_exhaustion container=tillandsias-myproject-foo resource=memory_oom limit_bytes=2147483648"
        );
        // Resource without a numeric limit (FDs, processes, ...).
        let fds = format_resource_exhaustion_event("c", "file_descriptors", None);
        assert_eq!(
            fds,
            "event:resource_exhaustion container=c resource=file_descriptors"
        );
    }

    /// Pins the `event:container_stderr` pass-through shape and verifies
    /// that an embedded-whitespace stderr line is shell-escaped to stay on
    /// one terminal line per spec:runtime-diagnostics-stream.
    #[test]
    fn container_stderr_event_shape() {
        let line =
            format_container_stderr_event("tillandsias-myproject-foo", "error: compilation failed");
        assert_eq!(
            line,
            "event:container_stderr container=tillandsias-myproject-foo line=\"error: compilation failed\""
        );
    }

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
        let status = std::process::Command::new("true").output().unwrap().status;

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

    /// Verify that PodmanClient has the get_enclave_containers method.
    /// We cannot call it without a real podman runtime in a sync test,
    /// but we can instantiate the client and verify it compiles.
    /// @trace spec:runtime-diagnostics-stream
    #[test]
    fn client_has_get_enclave_containers() {
        let _client = PodmanClient::new();
        // The existence of get_enclave_containers is verified by compile-time type checking.
        // An async integration test would call: _client.get_enclave_containers("myapp").await
    }

    /// Verify EnclaveContainerInfo structure can be created.
    /// @trace spec:runtime-diagnostics-stream
    #[test]
    fn enclave_container_info_creation() {
        let info = EnclaveContainerInfo {
            name: "tillandsias-test-proxy".to_string(),
            state: "Running".to_string(),
        };
        assert_eq!(info.name, "tillandsias-test-proxy");
        assert_eq!(info.state, "Running");
    }

    /// Verify PodmanError::is_transient() correctly classifies errors.
    /// @trace spec:podman-idiomatic-patterns
    #[test]
    fn podman_error_transient_classification() {
        // Transient: StreamError
        assert!(PodmanError::StreamError("EOF on event stream".into()).is_transient());

        // Transient: CommandFailed with "timeout"
        assert!(PodmanError::CommandFailed("operation timeout".into()).is_transient());

        // Transient: CommandFailed with "connection refused"
        assert!(
            PodmanError::CommandFailed("connection refused to podman socket".into()).is_transient()
        );

        // Permanent: NotFound
        assert!(!PodmanError::NotFound("tillandsias-foo".into()).is_transient());

        // Permanent: ParseError
        assert!(!PodmanError::ParseError("invalid JSON in podman output".into()).is_transient());

        // Permanent: CommandFailed with "permission denied"
        assert!(!PodmanError::CommandFailed("permission denied".into()).is_transient());

        // Permanent: CommandFailed with other message
        assert!(
            !PodmanError::CommandFailed("image build failed: some other error".into())
                .is_transient()
        );
    }
}
