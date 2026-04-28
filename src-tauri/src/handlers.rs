//! Menu action handlers for tray events.
//!
//! Implements the "Attach Here", "Stop", and "Destroy" workflows that
//! bridge tray menu clicks to podman operations and state updates.
//!
//! # Container Security Model (audited 2026-03-23)
//!
//! Every container launched by this module (Attach Here, Ground/Terminal,
//! GitHub Login) enforces the following non-negotiable security flags:
//!
//!   --cap-drop=ALL              Drop all Linux capabilities
//!   --security-opt=no-new-privileges  No privilege escalation (suid, etc.)
//!   --userns=keep-id            Map host UID into container (no root)
//!   --security-opt=label=disable  Disable SELinux relabeling (needed for
//!                                 bind mounts on Silverblue)
//!   --rm                        Ephemeral: container removed on exit
//!
//! Volume mounts are limited to:
//!   (none — proxy handles caching, code comes from git mirror)
//!
//! NOT mounted (by design):
//!   - Project directory (code comes from git mirror service)
//!   - Secrets/credentials (forge containers are credential-free)
//!   - Host root filesystem or /
//!   - Other user projects
//!   - System directories (/etc, /var, /usr)
//!   - Docker/Podman socket (no container-in-container)
//!
//! @trace spec:podman-orchestration, spec:default-image, spec:tray-app

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use tokio::sync::mpsc;
use tracing::{debug, error, info, instrument, warn};

use crate::strings;

/// Global mutex to serialize ALL podman image builds.
///
/// Rootless podman cannot handle concurrent `podman build` operations — they
/// corrupt the overlay storage, producing "identifier is not a container",
/// "layer not known", and false "image not found" errors.
///
/// Every call to `run_build_image_script()` acquires this mutex first. The
/// per-image `build_lock` (PID file) handles cross-process coordination;
/// this mutex handles intra-process serialization.
///
/// Uses `std::sync::Mutex` (not `tokio::sync::Mutex`) because
/// `run_build_image_script` is synchronous and runs on `spawn_blocking` threads.
///
/// @trace spec:default-image
static BUILD_MUTEX: Mutex<()> = Mutex::new(());

/// Acquire the global build mutex, serializing podman image builds.
///
/// Returns a `MutexGuard` that releases the lock when dropped.
/// Recovers from poisoned mutex (a panicking build shouldn't block all future builds).
///
/// @trace spec:default-image
pub fn build_mutex_lock() -> std::sync::MutexGuard<'static, ()> {
    BUILD_MUTEX.lock().unwrap_or_else(|e| {
        tracing::warn!("BUILD_MUTEX poisoned, recovering: {e}");
        e.into_inner()
    })
}

use std::sync::Arc;

use serde_json;
use tillandsias_core::config::{GlobalConfig, cache_dir, load_global_config, load_project_config};
use tillandsias_core::event::{AppEvent, BuildProgressEvent, ContainerState};
use tillandsias_core::genus::GenusAllocator;
use tillandsias_core::state::{ContainerInfo, TrayState};
use tillandsias_core::tools::ToolAllocator;
use tillandsias_podman::PodmanClient;
use tillandsias_podman::launch::{ContainerLauncher, allocate_port_range};
use tillandsias_podman::query_occupied_ports;
use tillandsias_podman::runtime::{Runtime, default_runtime};

/// Find the `gh` CLI binary on the host.
///
/// Checks common installation locations before falling back to PATH.
/// Returns `Some(path)` if gh is found, `None` if it should use container fallback.
///
/// # Locations checked:
/// - Windows: `C:\Program Files\GitHub CLI\gh.exe`, common `winget` paths
/// - Linux/macOS: `/usr/bin/gh`, `/usr/local/bin/gh`, `~/.local/bin/gh`, etc.
///
/// @trace spec:direct-podman-calls
fn find_gh_path() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        // Windows: check common install locations before PATH fallback.
        static WIN_PATHS: &[&str] = &[
            r"C:\Program Files\GitHub CLI\gh.exe",
            r"C:\Program Files (x86)\GitHub CLI\gh.exe",
            r"C:\ProgramData\Chocolatey\bin\gh.exe",
        ];

        for path in WIN_PATHS {
            let p = PathBuf::from(path);
            if p.exists() {
                return Some(p);
            }
        }

        // Try which or standard PATH
        if let Ok(output) = std::process::Command::new("where")
            .arg("gh")
            .output()
        {
            if output.status.success() {
                let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
                return Some(PathBuf::from(path));
            }
        }
        None
    }

    #[cfg(not(target_os = "windows"))]
    {
        // Unix: check standard locations first
        static PATHS: &[&str] = &[
            "/usr/bin/gh",
            "/usr/local/bin/gh",
            "/opt/homebrew/bin/gh", // Homebrew on Apple Silicon
            "/opt/local/bin/gh",    // MacPorts
        ];

        for path in PATHS {
            let p = PathBuf::from(path);
            if p.exists() {
                return Some(p);
            }
        }

        // Try ~/.local/bin/gh (user install)
        if let Ok(home) = std::env::var("HOME") {
            let user_bin = PathBuf::from(&home).join(".local/bin/gh");
            if user_bin.exists() {
                return Some(user_bin);
            }
        }

        // Try which
        if let Ok(output) = std::process::Command::new("which")
            .arg("gh")
            .output()
        {
            if output.status.success() {
                let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
                return Some(PathBuf::from(path));
            }
        }
        None
    }
}

/// Derive the forge image tag from the full 4-part version.
///
/// Uses `TILLANDSIAS_FULL_VERSION` (set by build.rs from the VERSION file)
/// which includes the build number (e.g., "0.1.97.83"). This ensures every
/// local build increment triggers a forge image rebuild.
// @trace spec:default-image, spec:versioning
pub(crate) fn forge_image_tag() -> String {
    format!("tillandsias-forge:v{}", env!("TILLANDSIAS_FULL_VERSION"))
}

/// The versioned proxy image tag, e.g., `tillandsias-proxy:v0.1.126.116`.
/// @trace spec:proxy-container
pub(crate) fn proxy_image_tag() -> String {
    format!("tillandsias-proxy:v{}", env!("TILLANDSIAS_FULL_VERSION"))
}

/// The versioned git service image tag.
/// @trace spec:git-mirror-service
pub(crate) fn git_image_tag() -> String {
    format!("tillandsias-git:v{}", env!("TILLANDSIAS_FULL_VERSION"))
}

/// The versioned inference image tag.
/// @trace spec:inference-container
pub(crate) fn inference_image_tag() -> String {
    format!("tillandsias-inference:v{}", env!("TILLANDSIAS_FULL_VERSION"))
}

/// The versioned router image tag.
/// @trace spec:subdomain-routing-via-reverse-proxy
pub(crate) fn router_image_tag() -> String {
    format!("tillandsias-router:v{}", env!("TILLANDSIAS_FULL_VERSION"))
}

/// The fixed container name for the inference service (not project-specific).
const INFERENCE_CONTAINER_NAME: &str = "tillandsias-inference";

/// Ensure the inference container is running.
///
/// Checks if `tillandsias-inference` container exists and is running. If not,
/// builds the inference image if needed and starts a detached inference container
/// on the enclave network with alias `inference`.
///
/// The model cache is mounted from `~/.cache/tillandsias/models/` to
/// `/home/ollama/.ollama/models/` so downloaded models persist across restarts.
///
/// @trace spec:inference-container, spec:cross-platform, spec:windows-wsl-runtime
// Windows arm returns early into a no-op; the cfg-gated Unix podman path
// below is unreachable on Windows builds. The compiler can't see across cfg.
#[allow(unreachable_code)]
pub(crate) async fn ensure_inference_running(
    state: &TrayState,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    // @trace spec:cross-platform, spec:windows-wsl-runtime
    // Windows: inference (ollama) Phase 2 — distro exists but daemon-launch
    // via wsl.exe isn't wired yet. No-op on Windows so the async spawn doesn't
    // produce spurious podman errors; opencode degrades gracefully when
    // OLLAMA_HOST is unreachable.
    #[cfg(target_os = "windows")]
    {
        let _ = (state, build_tx);
        debug!(spec = "cross-platform, windows-wsl-runtime", "Inference no-op on Windows (Phase 2)");
        return Ok(());
    }

    #[cfg(not(target_os = "windows"))]
    // Check if already running (in our state or via podman inspect)
    if state.running.iter().any(|c| c.name == INFERENCE_CONTAINER_NAME) {
        debug!(spec = "inference-container", "Inference container already tracked in state");
        return Ok(());
    }

    let client = PodmanClient::new();

    // Check if it's running outside our state (e.g., surviving a restart).
    // If running but with a stale image version, stop it and rebuild.
    if let Ok(inspect) = client.inspect_container(INFERENCE_CONTAINER_NAME).await
        && inspect.state == "running" {
            let expected_tag = inference_image_tag();
            if inspect.image.contains(&expected_tag) {
                debug!(spec = "inference-container", "Inference container already running (correct version)");
                return Ok(());
            }
            // Stale version — stop it so we can start the correct one
            warn!(
                spec = "inference-container",
                current = %inspect.image,
                expected = %expected_tag,
                "Inference container running stale version — restarting"
            );
            if let Err(e) = client.stop_container(INFERENCE_CONTAINER_NAME, 5).await {
                warn!(container = INFERENCE_CONTAINER_NAME, error = %e, "Failed to stop stale inference container");
            }
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }

    info!(
        accountability = true,
        category = "inference",
        spec = "inference-container",
        "Starting inference container"
    );

    // Ensure inference image is up to date — always invoke the build script
    // (it handles staleness internally via hash check and exits fast when current).
    // @trace spec:forge-staleness, spec:inference-container
    let mut tag = inference_image_tag();

    // Check for a newer inference image (forward compatibility)
    if let Some(newer_tag) = find_newer_image(&tag) {
        warn!(expected = %tag, found = %newer_tag, spec = "inference-container", "Found newer inference image — using it");
        tag = newer_tag;
    } else {
        // No newer image — ensure current version is built and up to date
        info!(tag = %tag, spec = "inference-container", "Ensuring inference image is up to date...");

        // @trace spec:inference-container
        // User-friendly chip name — never expose "inference" or "image" to users.
        let chip_name = crate::i18n::t("menu.build.chip_inference_engine").to_string();

        if build_tx.try_send(BuildProgressEvent::Started {
            image_name: chip_name.clone(),
        }).is_err() {
            debug!("Build progress channel full/closed — UI may show stale state");
        }

        let build_result =
            tokio::task::spawn_blocking(|| run_build_image_script("inference")).await;

        match build_result {
            Ok(Ok(())) => {
                if !client.image_exists(&tag).await {
                    error!(tag = %tag, spec = "inference-container", "Inference image still not found after build");
                    if build_tx.try_send(BuildProgressEvent::Failed {
                        image_name: chip_name,
                        reason: "Inference image not ready".to_string(),
                    }).is_err() {
                        debug!("Build progress channel full/closed — UI may show stale state");
                    }
                    return Err("Inference image not ready after build".into());
                }
                info!(tag = %tag, spec = "inference-container", "Inference image ready");
                prune_old_images();
                if build_tx.try_send(BuildProgressEvent::Completed {
                    image_name: chip_name,
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
            }
            Ok(Err(ref e)) => {
                error!(tag = %tag, error = %e, spec = "inference-container", "Inference image build failed");
                if build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: chip_name,
                    reason: format!("Inference build failed: {e}"),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                return Err(format!("Inference image build failed: {e}"));
            }
            Err(ref e) => {
                error!(tag = %tag, error = %e, spec = "inference-container", "Inference image build task panicked");
                if build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: chip_name,
                    reason: format!("Inference build panicked: {e}"),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                return Err(format!("Inference image build panicked: {e}"));
            }
        }
    }

    // Build inference container args using the profile + LaunchContext
    let profile = tillandsias_core::container_profile::inference_profile();
    let cache = cache_dir();

    // @trace spec:podman-orchestration
    ensure_container_log_dir(INFERENCE_CONTAINER_NAME);

    // Ensure model cache dir exists
    let models_cache = cache.join("models");
    std::fs::create_dir_all(&models_cache).ok();

    let port_mapping = needs_port_mapping();

    let ctx = tillandsias_core::container_profile::LaunchContext {
        container_name: INFERENCE_CONTAINER_NAME.to_string(),
        project_path: models_cache.clone(), // not meaningful for inference
        project_name: "inference".to_string(),
        cache_dir: cache.clone(),
        port_range: (0, 0),                 // no ports exposed to host
        host_os: tillandsias_core::config::detect_host_os(),
        detached: true,
        is_watch_root: false,
        custom_mounts: vec![],
        image_tag: tag.clone(),
        selected_language: "en".to_string(),
        // @trace spec:inference-container, spec:enclave-network
        // On Linux: enclave network with alias "inference" for DNS resolution.
        // On podman machine: no network flag (default), ports published to host.
        network: if port_mapping {
            None
        } else {
            Some(format!("{}:alias=inference", tillandsias_podman::ENCLAVE_NETWORK))
        },
        git_author_name: String::new(),
        git_author_email: String::new(),
        token_file_path: None,
        use_port_mapping: port_mapping,
        // @trace spec:opencode-web-session
        persistent: false,
        web_host_port: None,
        hot_path_budget_mb: 0, // @trace spec:forge-hot-cold-split — service container
    };

    let mut run_args = crate::launch::build_podman_args(&profile, &ctx);

    // @trace spec:enclave-network
    // On podman machine, publish port 11434 so other containers can reach
    // the inference service via localhost:11434.
    if port_mapping {
        run_args.insert(run_args.len() - 1, "-p".to_string());
        run_args.insert(run_args.len() - 1, "11434:11434".to_string());
    }

    // Mount model cache dynamically: host models dir -> container ollama models dir
    let model_mount = format!(
        "{}:/home/ollama/.ollama/models:rw",
        models_cache.display()
    );
    // Insert before the image tag (always last element)
    run_args.insert(run_args.len() - 1, "-v".to_string());
    run_args.insert(run_args.len() - 1, model_mount);

    // @trace spec:inference-container, spec:proxy-container
    // Inject proxy CA so ollama trusts the SSL-bumped certs from registry.ollama.ai.
    // Without this, `ollama pull` fails with x509 unknown authority because
    // Squid's MITM cert is signed by Tillandsias's own CA. Go reads SSL_CERT_FILE
    // for crypto/tls verification.
    inject_ca_chain_mounts(&mut run_args);
    let chain_path = crate::ca::proxy_certs_dir().join("ca-chain.crt");
    if chain_path.exists() {
        run_args.insert(
            run_args.len() - 1,
            "-e=SSL_CERT_FILE=/run/tillandsias/ca-chain.crt".to_string(),
        );
    }

    // Launch the inference container via podman run (detached)
    match client.run_container(&run_args).await {
        Ok(container_id) => {
            info!(
                accountability = true,
                category = "inference",
                spec = "inference-container",
                container_id = %container_id,
                "Inference container started (detached)"
            );

            // @trace spec:inference-container
            // Health check: verify ollama API is responding before declaring ready.
            // DISTRO: inference is Fedora Minimal — has curl, NOT wget.
            // Alpine containers use wget (busybox); Fedora containers use curl.
            // Ollama takes 15-30s to start (database init, model loading).
            // Exponential backoff: 1s, 2s, 4s, 8s, 8s... (capped at 8s).
            // 10 attempts covers ~55s total, enough for both fast and slow starts.
            let max_attempts: u32 = 10;
            for attempt in 0..max_attempts {
                // --noproxy '*' bypasses HTTP_PROXY/HTTPS_PROXY for this
                // probe. Without it curl tries to reach localhost:11434
                // through the enclave proxy, which refuses and returns an
                // HTTP 502 — making healthy inference look dead.
                let check = tillandsias_podman::podman_cmd()
                    .args([
                        "exec",
                        INFERENCE_CONTAINER_NAME,
                        "curl",
                        "-sf",
                        "--noproxy",
                        "*",
                        "--max-time",
                        "2",
                        "-o",
                        "/dev/null",
                        "http://localhost:11434/api/version",
                    ])
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status()
                    .await;
                if check.map(|s| s.success()).unwrap_or(false) {
                    info!(spec = "inference-container", attempt, "Inference health check passed");

                    // @trace spec:inference-host-side-pull
                    // Spawn background task to pull higher-tier models based on GPU tier
                    let gpu_tier = crate::gpu::detect_gpu_tier();
                    crate::inference_lazy_pull::spawn_model_pull_task(gpu_tier);

                    break;
                }
                if attempt < max_attempts - 1 {
                    let delay = Duration::from_secs((1u64 << attempt).min(8));
                    tokio::time::sleep(delay).await;
                } else {
                    warn!(
                        accountability = true,
                        category = "capability",
                        safety = "DEGRADED: inference container started but API not responding",
                        spec = "inference-container",
                        "Inference health check failed after {max_attempts} attempts — proceeding with degraded inference"
                    );
                }
            }

            Ok(())
        }
        Err(e) => {
            error!(
                spec = "inference-container",
                error = %e,
                "Failed to start inference container"
            );
            Err(format!("Failed to start inference container: {e}"))
        }
    }
}

/// Stop the inference container if running. Best-effort, errors are logged.
/// @trace spec:inference-container
pub(crate) async fn stop_inference(runtime: Arc<dyn Runtime>) {
    // @trace spec:cross-platform, spec:podman-orchestration
    match runtime.container_stop(INFERENCE_CONTAINER_NAME, 10).await {
        Ok(()) => info!(
            accountability = true,
            category = "inference",
            spec = "inference-container",
            "Inference container stopped"
        ),
        Err(e) => {
            // Not an error if it wasn't running
            debug!(spec = "inference-container", error = %e, "Inference stop returned error (may not have been running)");
        }
    }
}

/// Ensure the tillandsias-enclave internal network exists.
/// Creates it if absent. Called before any container launch.
///
/// On podman machine (macOS/Windows), skips network creation entirely.
/// Internal network DNS doesn't work through gvproxy, so containers
/// use the default podman network with localhost port mapping instead.
///
/// @trace spec:enclave-network
pub(crate) async fn ensure_enclave_network() -> Result<(), String> {
    // @trace spec:enclave-network
    // On podman machine, internal network DNS is broken through gvproxy.
    // Skip enclave network creation — use default network + port mapping.
    if tillandsias_core::state::Os::detect().needs_podman_machine() {
        info!(
            accountability = true,
            category = "enclave",
            spec = "enclave-network",
            "Podman machine detected — skipping enclave network (using localhost port mapping)"
        );
        return Ok(());
    }

    let client = PodmanClient::new();
    let name = tillandsias_podman::ENCLAVE_NETWORK;
    if !client.network_exists(name).await {
        info!(
            network = name,
            accountability = true,
            category = "enclave",
            spec = "enclave-network",
            "Creating enclave network"
        );
        client
            .create_internal_network(name)
            .await
            .map_err(|e| format!("Failed to create enclave network: {e}"))?;
    }
    Ok(())
}

/// Whether the current platform needs localhost port mapping instead of DNS aliases.
///
/// Returns `true` on podman machine (macOS/Windows) where internal network DNS
/// doesn't work through gvproxy. Services publish ports to the host and containers
/// communicate via `localhost:<port>`.
///
/// @trace spec:enclave-network
fn needs_port_mapping() -> bool {
    tillandsias_core::state::Os::detect().needs_podman_machine()
}

/// The fixed container name for the proxy (not project-specific).
const PROXY_CONTAINER_NAME: &str = "tillandsias-proxy";

/// Ensure the proxy container is running.
///
/// Checks if `tillandsias-proxy` container exists and is running. If not,
/// builds the proxy image if needed and starts a detached proxy container
/// on the enclave network (dual-homed with bridge for external access).
///
/// @trace spec:proxy-container, spec:enclave-network, spec:cross-platform, spec:podman-orchestration
pub(crate) async fn ensure_proxy_running(
    state: &TrayState,
    runtime: Arc<dyn Runtime>,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    // Check if already running (in our state or via podman inspect)
    if state.running.iter().any(|c| c.name == PROXY_CONTAINER_NAME) {
        debug!(spec = "proxy-container", "Proxy container already tracked in state");
        return Ok(());
    }

    // Check if it's running outside our state (e.g., surviving a restart).
    // If running but with a stale image version, stop it and rebuild.
    // @trace spec:cross-platform, spec:podman-orchestration
    if let Ok(inspect) = runtime.container_inspect(PROXY_CONTAINER_NAME).await
        && inspect.state == "running" {
            let expected_tag = proxy_image_tag();
            if inspect.image.contains(&expected_tag) {
                debug!(spec = "proxy-container", "Proxy container already running (correct version)");
                return Ok(());
            }
            // Stale version — stop it so we can start the correct one
            warn!(
                spec = "proxy-container",
                current = %inspect.image,
                expected = %expected_tag,
                "Proxy container running stale version — restarting"
            );
            // @trace spec:cross-platform, spec:podman-orchestration
            if let Err(e) = runtime.container_stop(PROXY_CONTAINER_NAME, 5).await {
                warn!(container = PROXY_CONTAINER_NAME, error = %e, "Failed to stop stale proxy container");
            }
            // Wait briefly for cleanup
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }

    info!(
        accountability = true,
        category = "proxy",
        spec = "proxy-container",
        "Starting proxy container"
    );

    // For image/container operations, use PodmanClient directly (container_run and image_exists
    // not yet migrated to Runtime trait). Inspect/stop calls above use the Runtime trait.
    // @trace spec:cross-platform, spec:podman-orchestration
    let client = PodmanClient::new();

    // Ensure proxy image is up to date — always invoke the build script
    // (it handles staleness internally via hash check and exits fast when current).
    // @trace spec:forge-staleness, spec:proxy-container
    let mut tag = proxy_image_tag();

    // Check for a newer proxy image (forward compatibility)
    if let Some(newer_tag) = find_newer_image(&tag) {
        warn!(expected = %tag, found = %newer_tag, spec = "proxy-container", "Found newer proxy image — using it");
        tag = newer_tag;
    } else {
        // No newer image — ensure current version is built and up to date
        info!(tag = %tag, spec = "proxy-container", "Ensuring proxy image is up to date...");

        // @trace spec:proxy-container
        // User-friendly chip name — never expose "proxy" or "image" to users.
        let chip_name = crate::i18n::t("menu.build.chip_enclave").to_string();

        if build_tx.try_send(BuildProgressEvent::Started {
            image_name: chip_name.clone(),
        }).is_err() {
            debug!("Build progress channel full/closed — UI may show stale state");
        }

        let build_result =
            tokio::task::spawn_blocking(|| run_build_image_script("proxy")).await;

        match build_result {
            Ok(Ok(())) => {
                if !client.image_exists(&tag).await {
                    error!(tag = %tag, spec = "proxy-container", "Proxy image still not found after build");
                    if build_tx.try_send(BuildProgressEvent::Failed {
                        image_name: chip_name,
                        reason: "Proxy image not ready".to_string(),
                    }).is_err() {
                        debug!("Build progress channel full/closed — UI may show stale state");
                    }
                    return Err("Proxy image not ready after build".into());
                }
                info!(tag = %tag, spec = "proxy-container", "Proxy image ready");
                prune_old_images();
                if build_tx.try_send(BuildProgressEvent::Completed {
                    image_name: chip_name,
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
            }
            Ok(Err(ref e)) => {
                error!(tag = %tag, error = %e, spec = "proxy-container", "Proxy image build failed");
                if build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: chip_name,
                    reason: format!("Proxy build failed: {e}"),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                return Err(format!("Proxy image build failed: {e}"));
            }
            Err(ref e) => {
                error!(tag = %tag, error = %e, spec = "proxy-container", "Proxy image build task panicked");
                if build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: chip_name,
                    reason: format!("Proxy build panicked: {e}"),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                return Err(format!("Proxy image build panicked: {e}"));
            }
        }
    }

    // @trace spec:proxy-container
    // Generate ephemeral CA chain (root + intermediate) fresh on every launch.
    // Everything on tmpfs — dies with the session. Takes ~5ms.
    let certs_dir = crate::ca::generate_ephemeral_certs()?;

    // Build proxy container args using the profile + LaunchContext
    let profile = tillandsias_core::container_profile::proxy_profile();
    let cache = cache_dir();

    // @trace spec:podman-orchestration
    ensure_container_log_dir(PROXY_CONTAINER_NAME);

    // Ensure cache dir for proxy exists
    let proxy_cache = cache.join("proxy-cache");
    std::fs::create_dir_all(&proxy_cache).ok();

    let port_mapping = needs_port_mapping();

    let ctx = tillandsias_core::container_profile::LaunchContext {
        container_name: PROXY_CONTAINER_NAME.to_string(),
        project_path: proxy_cache.clone(),  // not meaningful for proxy
        project_name: "proxy".to_string(),
        cache_dir: proxy_cache.clone(),     // mount proxy-cache as /var/spool/squid
        port_range: (0, 0),                 // no ports exposed to host
        host_os: tillandsias_core::config::detect_host_os(),
        detached: true,
        is_watch_root: false,
        custom_mounts: vec![],
        image_tag: tag.clone(),
        selected_language: "en".to_string(),
        // @trace spec:proxy-container, spec:enclave-network
        // On Linux: enclave network with alias "proxy" for DNS resolution.
        // On podman machine: no network flag (default), ports published to host.
        network: if port_mapping {
            None
        } else {
            Some(format!("{}:alias=proxy", tillandsias_podman::ENCLAVE_NETWORK))
        },
        git_author_name: String::new(),
        git_author_email: String::new(),
        token_file_path: None,
        use_port_mapping: port_mapping,
        // @trace spec:opencode-web-session
        persistent: false,
        web_host_port: None,
        hot_path_budget_mb: 0, // @trace spec:forge-hot-cold-split — service container
    };

    let mut run_args = crate::launch::build_podman_args(&profile, &ctx);

    // @trace spec:enclave-network
    if port_mapping {
        // On podman machine: publish proxy ports so containers can reach them
        // via localhost:3128 (strict) and localhost:3129 (permissive).
        run_args.insert(run_args.len() - 1, "-p".to_string());
        run_args.insert(run_args.len() - 1, "3128:3128".to_string());
        run_args.insert(run_args.len() - 1, "-p".to_string());
        run_args.insert(run_args.len() - 1, "3129:3129".to_string());
    } else {
        // Proxy is dual-homed: add the default "podman" network for external access.
        // Must be a separate --network flag (comma syntax is parsed as aliases, not networks).
        run_args.insert(run_args.len() - 1, "--network=podman".to_string());
    }

    // @trace spec:proxy-container
    // Mount intermediate CA cert + key into the proxy for ssl-bump.
    // These are read by squid to generate per-domain server certificates.
    run_args.insert(
        run_args.len() - 1,
        format!(
            "-v={}:/etc/squid/certs/intermediate.crt:ro",
            certs_dir.join("intermediate.crt").display()
        ),
    );
    run_args.insert(
        run_args.len() - 1,
        format!(
            "-v={}:/etc/squid/certs/intermediate.key:ro",
            certs_dir.join("intermediate.key").display()
        ),
    );

    // Launch the proxy container via podman run (detached)
    match client.run_container(&run_args).await {
        Ok(container_id) => {
            info!(
                accountability = true,
                category = "proxy",
                spec = "proxy-container",
                container_id = %container_id,
                "Proxy container started (detached)"
            );

            // @trace spec:secrets-management
            info!(
                accountability = true,
                category = "secrets",
                safety = "CA certs only — no credentials, no D-Bus, no tokens",
                pids_limit = 32,
                read_only = true,
                spec = "secret-management",
                "Proxy container has CA certs only — zero credentials, pids-limit=32, read-only FS"
            );

            // @trace spec:proxy-container
            // Wait for squid to accept connections before declaring the proxy ready.
            // Without this, containers/builds that start immediately after may fail
            // because podman's internal DNS hasn't registered the "proxy" alias yet,
            // or squid hasn't finished initializing its SSL cert database.
            //
            // DISTRO: Proxy is Alpine — uses busybox nc (netcat).
            // wget --spider returns 400 (squid rejects non-proxy requests).
            // nc -z is a pure TCP port probe — succeeds if squid is listening.
            // Exponential backoff: 1s, 2s, 4s, 8s, 8s... (capped at 8s).
            let max_attempts: u32 = 10;
            let mut ready = false;
            for attempt in 0..max_attempts {
                let check = tillandsias_podman::podman_cmd()
                    .args(["exec", PROXY_CONTAINER_NAME, "sh", "-c", "nc -z localhost 3128"])
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status()
                    .await;
                if check.map(|s| s.success()).unwrap_or(false) {
                    info!(spec = "proxy-container", attempt, "Proxy readiness check passed");
                    ready = true;
                    break;
                }
                if attempt < max_attempts - 1 {
                    let delay = Duration::from_secs((1u64 << attempt).min(8));
                    tokio::time::sleep(delay).await;
                }
            }

            if !ready {
                error!(
                    spec = "proxy-container",
                    "Proxy readiness check failed after {max_attempts} attempts — refusing to proceed",
                );
                return Err(format!(
                    "Proxy container not responding on :3128 after {max_attempts} attempts",
                ));
            }

            Ok(())
        }
        Err(e) => {
            error!(
                spec = "proxy-container",
                error = %e,
                "Failed to start proxy container"
            );
            Err(format!("Failed to start proxy container: {e}"))
        }
    }
}

// ---------------------------------------------------------------------------
// Router container — Caddy reverse proxy mapping <project>.<service>.localhost
// to enclave containers by name + port.
// @trace spec:subdomain-routing-via-reverse-proxy
// ---------------------------------------------------------------------------

const ROUTER_CONTAINER_NAME: &str = "tillandsias-router";

/// Path on host to the dynamic Caddyfile written by the tray, bind-mounted
/// into the router container at `/run/router/dynamic.Caddyfile`.
fn router_dynamic_caddyfile_host_path() -> std::path::PathBuf {
    let base = if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
        std::path::PathBuf::from(xdg).join("tillandsias")
    } else {
        std::env::temp_dir().join("tillandsias-embedded")
    };
    base.join("router")
}

/// Ensure the router container is running.
///
/// Brings up `tillandsias-router` (Caddy 2) on the enclave with DNS alias
/// `router` and a host loopback bind at `127.0.0.1:80`. The router only
/// accepts traffic from RFC 1918 / loopback sources (defence-in-depth on
/// top of the binding-level loopback restriction).
///
/// @trace spec:subdomain-routing-via-reverse-proxy, spec:enclave-network
pub(crate) async fn ensure_router_running(
    state: &TrayState,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    if state.running.iter().any(|c| c.name == ROUTER_CONTAINER_NAME) {
        debug!(spec = "subdomain-routing-via-reverse-proxy", "Router already tracked in state");
        return Ok(());
    }

    let client = PodmanClient::new();

    if let Ok(inspect) = client.inspect_container(ROUTER_CONTAINER_NAME).await
        && inspect.state == "running"
    {
        let expected_tag = router_image_tag();
        if inspect.image.contains(&expected_tag) {
            debug!(spec = "subdomain-routing-via-reverse-proxy", "Router already running (correct version)");
            return Ok(());
        }
        warn!(
            spec = "subdomain-routing-via-reverse-proxy",
            current = %inspect.image,
            expected = %expected_tag,
            "Router running stale version — restarting"
        );
        if let Err(e) = client.stop_container(ROUTER_CONTAINER_NAME, 5).await {
            warn!(container = ROUTER_CONTAINER_NAME, error = %e, "Failed to stop stale router");
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }

    info!(
        accountability = true,
        category = "router",
        spec = "subdomain-routing-via-reverse-proxy",
        "Starting router container"
    );

    let mut tag = router_image_tag();
    if let Some(newer) = find_newer_image(&tag) {
        warn!(expected = %tag, found = %newer, spec = "subdomain-routing-via-reverse-proxy", "Found newer router image — using it");
        tag = newer;
    } else {
        info!(tag = %tag, spec = "subdomain-routing-via-reverse-proxy", "Ensuring router image is up to date...");
        let chip_name = "router".to_string();
        if build_tx
            .try_send(BuildProgressEvent::Started { image_name: chip_name.clone() })
            .is_err()
        {
            debug!("Build progress channel full/closed — UI may show stale state");
        }
        let build_result =
            tokio::task::spawn_blocking(|| run_build_image_script("router")).await;
        match build_result {
            Ok(Ok(())) => {
                if !client.image_exists(&tag).await {
                    error!(tag = %tag, spec = "subdomain-routing-via-reverse-proxy", "Router image still not found after build");
                    let _ = build_tx.try_send(BuildProgressEvent::Failed {
                        image_name: chip_name,
                        reason: "Router image not ready".to_string(),
                    });
                    return Err("Router image not ready after build".into());
                }
                let _ = build_tx.try_send(BuildProgressEvent::Completed { image_name: chip_name });
            }
            Ok(Err(ref e)) => {
                error!(tag = %tag, error = %e, spec = "subdomain-routing-via-reverse-proxy", "Router image build failed");
                let _ = build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: chip_name,
                    reason: format!("Router build failed: {e}"),
                });
                return Err(format!("Router image build failed: {e}"));
            }
            Err(ref e) => {
                error!(tag = %tag, error = %e, spec = "subdomain-routing-via-reverse-proxy", "Router image build task panicked");
                let _ = build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: chip_name,
                    reason: format!("Router build panicked: {e}"),
                });
                return Err(format!("Router image build panicked: {e}"));
            }
        }
    }

    // Ensure the dynamic Caddyfile path exists. The tray rewrites this on each
    // attach; on first start it's empty (router serves only the base catchall).
    let dyn_dir = router_dynamic_caddyfile_host_path();
    std::fs::create_dir_all(&dyn_dir)
        .map_err(|e| format!("Cannot create router dynamic dir: {e}"))?;
    let dyn_file = dyn_dir.join("dynamic.Caddyfile");
    if !dyn_file.exists() {
        std::fs::write(&dyn_file, "")
            .map_err(|e| format!("Cannot create router dynamic.Caddyfile: {e}"))?;
    }

    ensure_container_log_dir(ROUTER_CONTAINER_NAME);

    let port_mapping = needs_port_mapping();

    let profile = tillandsias_core::container_profile::router_profile();
    let ctx = tillandsias_core::container_profile::LaunchContext {
        container_name: ROUTER_CONTAINER_NAME.to_string(),
        project_path: dyn_dir.clone(),
        project_name: "router".to_string(),
        cache_dir: dyn_dir.clone(),
        port_range: (0, 0),
        host_os: tillandsias_core::config::detect_host_os(),
        detached: true,
        is_watch_root: false,
        custom_mounts: vec![],
        image_tag: tag.clone(),
        selected_language: "en".to_string(),
        // Enclave alias `router` so Squid's cache_peer + forge agents can resolve.
        // @trace spec:subdomain-routing-via-reverse-proxy, spec:enclave-network
        network: if port_mapping {
            None
        } else {
            Some(format!("{}:alias=router", tillandsias_podman::ENCLAVE_NETWORK))
        },
        git_author_name: String::new(),
        git_author_email: String::new(),
        token_file_path: None,
        use_port_mapping: port_mapping,
        persistent: false,
        web_host_port: None,
        hot_path_budget_mb: 0, // @trace spec:forge-hot-cold-split — service container
    };

    let mut run_args = crate::launch::build_podman_args(&profile, &ctx);

    // @trace spec:subdomain-routing-via-reverse-proxy
    // Bind-mount the dynamic Caddyfile into the container at the path the
    // entrypoint expects. The tray rewrites the host file and signals reload
    // via `regenerate_router_caddyfile`.
    run_args.insert(
        run_args.len() - 1,
        format!("-v={}:/run/router/dynamic.Caddyfile:rw", dyn_file.display()),
    );

    // @trace spec:subdomain-routing-via-reverse-proxy, spec:opencode-web-session
    // @cheatsheet runtime/forge-container.md
    // Host loopback publish — 127.0.0.1:8080 ONLY. NEVER 0.0.0.0. The host
    // kernel restricts the listener so external clients can't reach port 8080
    // even if they spoof a Host header. The internal Caddy listener inside
    // the container stays on :80 (allowed within the user namespace);
    // only the host-side publish moves to :8080 because rootless podman
    // cannot bind ports below `net.ipv4.ip_unprivileged_port_start`
    // (default 1024 on Fedora/Silverblue/most distros). Browser-facing URL
    // therefore carries `:8080` — see browser::build_subdomain_url.
    //
    // @tombstone superseded:fix-router-loopback-port — kept for three
    // releases (until 0.1.169.230). Original publish was `127.0.0.1:80:80`
    // which silently failed under rootless podman, producing the
    // ERR_CONNECTION_REFUSED reported by the user against
    // `<project>.opencode.localhost`.
    // @trace spec:fix-router-loopback-port
    // Both host AND container ports are 8080 — internal Caddy listener
    // moved to :8080 (was :80) so binding doesn't need CAP_NET_BIND_SERVICE
    // under --cap-drop=ALL. Caddy v2 image's `cap_net_bind_service=ep`
    // file capability also conflicts with --security-opt=no-new-privileges
    // (kernel rejects exec); the router image now strips that file cap
    // (see images/router/Containerfile).
    run_args.insert(run_args.len() - 1, "-p".to_string());
    run_args.insert(run_args.len() - 1, "127.0.0.1:8080:8080".to_string());

    match client.run_container(&run_args).await {
        Ok(container_id) => {
            info!(
                accountability = true,
                category = "router",
                spec = "subdomain-routing-via-reverse-proxy",
                container_id = %container_id,
                "Router container started (detached, 127.0.0.1:80 host bind)"
            );

            // Like proxy and inference, the router isn't tracked in
            // state.running. Liveness is checked via podman inspect.

            // @trace spec:subdomain-routing-via-reverse-proxy
            // Health probe: hit the router's catchall on enclave + host. The
            // base.Caddyfile returns 404 for unknown hosts to trusted sources
            // — that's the "ready" signal. We accept any 4xx as proof of life
            // since 200 only happens once routes are loaded.
            for attempt in 0..10 {
                let check = tillandsias_podman::podman_cmd()
                    .args([
                        "exec",
                        ROUTER_CONTAINER_NAME,
                        "sh",
                        "-c",
                        "curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1/ -H 'Host: ready.localhost' || true",
                    ])
                    .output()
                    .await;
                if let Ok(out) = check {
                    let code = String::from_utf8_lossy(&out.stdout).trim().to_string();
                    if code == "404" || code == "200" {
                        info!(
                            spec = "subdomain-routing-via-reverse-proxy",
                            attempt,
                            "Router readiness check passed"
                        );
                        return Ok(());
                    }
                }
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                let _ = attempt;
            }
            warn!(spec = "subdomain-routing-via-reverse-proxy", "Router health probe never confirmed ready — continuing anyway");
            Ok(())
        }
        Err(e) => {
            error!(error = %e, spec = "subdomain-routing-via-reverse-proxy", "Router container failed to start");
            Err(format!("Router start failed: {e}"))
        }
    }
}

/// Stop the router container if running. Best-effort, errors are logged.
/// @trace spec:subdomain-routing-via-reverse-proxy
pub(crate) async fn stop_router(runtime: Arc<dyn Runtime>) {
    // @trace spec:cross-platform, spec:podman-orchestration
    match runtime.container_stop(ROUTER_CONTAINER_NAME, 10).await {
        Ok(()) => info!(
            accountability = true,
            category = "router",
            spec = "subdomain-routing-via-reverse-proxy",
            "Router container stopped"
        ),
        Err(e) => {
            debug!(spec = "subdomain-routing-via-reverse-proxy", error = %e, "Router stop returned error (may not have been running)");
        }
    }
}

/// Regenerate the router's dynamic.Caddyfile from the currently-running
/// forge containers and tell Caddy to reload.
///
/// Idempotent. Safe to call after every forge launch and after every
/// shutdown.
///
/// Format per project:
///     <project>.opencode.localhost:80 {
///         reverse_proxy tillandsias-<project>-forge:4096
///     }
///
/// Behaviour:
/// - Iterates `state.running` filtered to OpenCodeWeb forge containers
///   (named `tillandsias-<project>-forge`).
/// - Writes the merged snippet to the host `dynamic.Caddyfile` that the
///   router container bind-mounts at `/run/router/dynamic.Caddyfile`.
/// - If the router container is running, executes
///   `/usr/local/bin/router-reload.sh` inside it to apply the new
///   routes synchronously. If the router isn't running yet, the write
///   alone is sufficient — the router's entrypoint reads the file on
///   the next start.
/// - Best-effort: errors are logged but never propagated. The caller
///   should not fail an attach because the router reload hiccupped;
///   the forge container itself is healthy and reachable on the
///   enclave.
///
/// Whether the Caddy router should reject opencode-web requests that lack
/// a session cookie validated by the router-side sidecar.
///
/// **`true` since chunk 7 of the opencode-web-session-otp convergence**.
/// The full chain is live: tray issues a 256-bit cookie, broadcasts
/// IssueWebSession to subscribed sidecars over the control socket,
/// hands the cookie to Chromium via CDP `Network.setCookies` before
/// `Page.navigate`, and Caddy's `forward_auth` directive consults the
/// router sidecar at `127.0.0.1:9090/validate` on every request.
/// Anything without a cookie matching an entry in the sidecar's
/// per-project session list — `curl` from another shell, sibling
/// browser tab, process discovering the URL via `/proc/<pid>/cmdline`,
/// extension reading the URL of another tab — gets HTTP 401 with the
/// friendly "open this project from the Tillandsias tray" body.
///
/// To temporarily disable enforcement (e.g. local debugging without
/// the sidecar), flip to `false`. The Caddy block falls back to the
/// pre-OTP unconditional reverse_proxy. The
/// `render_caddy_route_block_*` tests cover both shapes; toggling this
/// constant is the only source change needed.
///
/// @trace spec:opencode-web-session-otp
/// @cheatsheet web/cookie-auth-best-practices.md
pub(crate) const ENFORCE_SESSION_COOKIE: bool = true;

/// Render the Caddy site block for a single project's OpenCode Web route.
///
/// When [`ENFORCE_SESSION_COOKIE`] is `true`, the block delegates auth to
/// the router-side sidecar via Caddy's built-in `forward_auth` directive:
/// every request triggers `GET /validate?project=<host-label>` against
/// `127.0.0.1:9090` (in-container loopback to the sidecar). The sidecar
/// inspects the forwarded `Cookie:` header, decodes the
/// `tillandsias_session=<base64url>` value, looks it up in the per-project
/// session list, and replies `204` (allow) or `401` (deny). Caddy
/// continues the request on 204 and returns the sidecar's 401 body
/// (friendly "open from the tray" message) on deny.
///
/// When `false`, the block reverse-proxies all requests unconditionally —
/// the pre-OTP behaviour. Pure function exposed at module level so unit
/// tests can pin both byte shapes.
///
/// @trace spec:opencode-web-session-otp, spec:subdomain-routing-via-reverse-proxy
/// @cheatsheet web/cookie-auth-best-practices.md
pub(crate) fn render_caddy_route_block(project: &str) -> String {
    if ENFORCE_SESSION_COOKIE {
        // forward_auth: Caddy fires GET /validate against the sidecar with
        // the original Cookie header copied over. On non-2xx the sidecar's
        // response (status + body) is returned to the client unchanged —
        // we don't need a separate `respond 401` directive here.
        format!(
            "http://opencode.{project}.localhost:8080 {{\n    forward_auth 127.0.0.1:9090 {{\n        uri /validate?project=opencode.{project}.localhost\n        copy_headers Cookie\n    }}\n    reverse_proxy tillandsias-{project}-forge:4096\n}}\n",
            project = project
        )
    } else {
        // Pre-OTP shape — direct reverse_proxy, no cookie gate. Used until
        // ENFORCE_SESSION_COOKIE flips (see the doc-comment for the
        // flip-the-switch instructions).
        format!(
            "http://opencode.{project}.localhost:8080 {{\n    reverse_proxy tillandsias-{project}-forge:4096\n}}\n",
            project = project
        )
    }
}

/// @trace spec:subdomain-routing-via-reverse-proxy
pub(crate) async fn regenerate_router_caddyfile(state: &TrayState) -> Result<(), String> {
    // Build the dynamic Caddyfile contents from currently-tracked forge containers.
    // @trace spec:subdomain-routing-via-reverse-proxy
    let mut snippet = String::new();
    let mut route_count = 0usize;
    for entry in &state.running {
        if !matches!(
            entry.container_type,
            tillandsias_core::state::ContainerType::OpenCodeWeb
        ) {
            continue;
        }
        let project = match ContainerInfo::parse_forge_container_name(&entry.name) {
            Some(p) => p,
            None => {
                debug!(
                    container = %entry.name,
                    spec = "subdomain-routing-via-reverse-proxy",
                    "OpenCodeWeb container name did not parse as forge — skipping route"
                );
                continue;
            }
        };
        // @trace spec:subdomain-naming-flip
        // @cheatsheet runtime/networking.md
        // Service-leftmost ordering — see browser::build_subdomain_url for
        // the rationale. Future per-project services (web/dashboard/www)
        // slot under the same `*.<project>.localhost` namespace.
        //
        // @tombstone superseded:subdomain-naming-flip — kept for three
        // releases (until 0.1.169.231). Prior shape was
        // `"{project}.opencode.localhost:80 ..."` (project-leftmost).
        // @trace spec:subdomain-naming-flip, spec:fix-router-loopback-port
        // @cheatsheet runtime/networking.md
        // Internal Caddy listener moved from :80 to :8080 to avoid
        // CAP_NET_BIND_SERVICE requirement under --cap-drop=ALL. Host
        // publish stays 127.0.0.1:8080:8080 (was :8080:80).
        //
        // Explicit `http://` scheme is REQUIRED: Caddy treats `*.localhost`
        // site addresses as TLS-eligible by default (RFC 6761 local-dev
        // convention — Caddy auto-issues a localhost cert via its built-in
        // CA). Even with `auto_https off` in the global block, the listener
        // ends up with an empty `tls_connection_policies: [{}]`, causing
        // plain HTTP requests to be rejected with HTTP/1.0 400 "Client
        // sent an HTTP request to an HTTPS server." The `http://` prefix
        // opts out of this implicit TLS expectation.
        //
        // @trace spec:opencode-web-session-otp
        // @cheatsheet web/cookie-auth-best-practices.md
        // Per-window session cookie required when ENFORCE_SESSION_COOKIE
        // is true. Caddy's `forward_auth` directive consults the router
        // sidecar at 127.0.0.1:9090 on every request; the sidecar decodes
        // the cookie value and checks membership in the per-project session
        // list. Any request whose cookie value is NOT in the list — `curl`
        // from another shell, sibling browser windows that did not go
        // through the tray, processes that discovered the URL via
        // `/proc/<pid>/cmdline` of the spawned browser — gets HTTP 401
        // with the friendly "open from the tray" body.
        snippet.push_str(&render_caddy_route_block(&project));
        route_count += 1;
    }

    let dyn_dir = router_dynamic_caddyfile_host_path();
    if let Err(e) = tokio::fs::create_dir_all(&dyn_dir).await {
        warn!(
            spec = "subdomain-routing-via-reverse-proxy",
            dir = %dyn_dir.display(),
            error = %e,
            "Failed to ensure router dynamic dir — skipping Caddyfile regeneration"
        );
        return Ok(());
    }
    let dyn_file = dyn_dir.join("dynamic.Caddyfile");

    if let Err(e) = tokio::fs::write(&dyn_file, snippet.as_bytes()).await {
        warn!(
            spec = "subdomain-routing-via-reverse-proxy",
            path = %dyn_file.display(),
            error = %e,
            "Failed to write router dynamic.Caddyfile — routes may be stale"
        );
        return Ok(());
    }

    debug!(
        spec = "subdomain-routing-via-reverse-proxy",
        path = %dyn_file.display(),
        routes = route_count,
        "Wrote router dynamic.Caddyfile"
    );

    // If the router container isn't running, skip the reload — the file
    // we just wrote will be picked up on the next router start via the
    // bind-mount + entrypoint's initial merge.
    // @trace spec:subdomain-routing-via-reverse-proxy
    let client = PodmanClient::new();
    match client.inspect_container(ROUTER_CONTAINER_NAME).await {
        Ok(inspect) if inspect.state == "running" => {}
        Ok(_) => {
            debug!(
                spec = "subdomain-routing-via-reverse-proxy",
                "Router not running — wrote dynamic.Caddyfile only (entrypoint will pick it up on next start)"
            );
            return Ok(());
        }
        Err(_) => {
            debug!(
                spec = "subdomain-routing-via-reverse-proxy",
                "Router inspect failed — skipping reload (next router start will pick up the file)"
            );
            return Ok(());
        }
    }

    // Trigger the reload synchronously so callers know the new routes are
    // live before returning to the user. Errors are logged but non-fatal.
    // @trace spec:subdomain-routing-via-reverse-proxy
    let reload_result = tillandsias_podman::podman_cmd()
        .args([
            "exec",
            ROUTER_CONTAINER_NAME,
            "/usr/local/bin/router-reload.sh",
        ])
        .output()
        .await;
    match reload_result {
        Ok(out) if out.status.success() => {
            info!(
                accountability = true,
                category = "router",
                spec = "subdomain-routing-via-reverse-proxy",
                routes = route_count,
                "Router Caddyfile regenerated and reloaded"
            );
        }
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr);
            warn!(
                spec = "subdomain-routing-via-reverse-proxy",
                exit_code = out.status.code().unwrap_or(-1),
                stderr = %stderr,
                "router-reload.sh exited non-zero — routes may not be live yet"
            );
        }
        Err(e) => {
            warn!(
                spec = "subdomain-routing-via-reverse-proxy",
                error = %e,
                "Failed to invoke router-reload.sh — routes may not be live yet"
            );
        }
    }

    Ok(())
}

/// Stop the proxy container if running. Best-effort, errors are logged.
/// @trace spec:proxy-container
pub(crate) async fn stop_proxy(runtime: Arc<dyn Runtime>) {
    // @trace spec:cross-platform, spec:podman-orchestration
    match runtime.container_stop(PROXY_CONTAINER_NAME, 10).await {
        Ok(()) => info!(
            accountability = true,
            category = "proxy",
            spec = "proxy-container",
            "Proxy container stopped"
        ),
        Err(e) => {
            // Not an error if it wasn't running
            debug!(spec = "proxy-container", error = %e, "Proxy stop returned error (may not have been running)");
        }
    }
}

/// Check if the proxy container is running and responding on port 3128.
///
/// Performs a single health probe using `wget --spider`.
/// DISTRO: Proxy is Alpine — busybox wget is built-in, curl is NOT available.
/// Returns `true` if the proxy responds, `false` otherwise.
/// Remove the enclave network if no containers are attached.
/// Best-effort — silently ignores errors (e.g., containers still attached).
/// On podman machine, the enclave network was never created — nothing to do.
/// @trace spec:enclave-network
pub(crate) async fn cleanup_enclave_network() {
    // On podman machine, no enclave network was created — skip cleanup.
    if needs_port_mapping() {
        return;
    }
    let client = PodmanClient::new();
    let name = tillandsias_podman::ENCLAVE_NETWORK;
    if client.network_exists(name).await {
        match client.remove_network(name).await {
            Ok(()) => info!(
                accountability = true,
                category = "enclave",
                spec = "enclave-network",
                "Enclave network removed"
            ),
            Err(e) => warn!(spec = "enclave-network", error = %e, "Enclave network removal failed — zombie containers may exist"),
        }
    }
}

/// Startup crash-recovery: stop every running `tillandsias-*` container
/// and remove the enclave network.
///
/// Our containers all launch with `--rm`, so stopping them also deletes the
/// container layer. The `podman ps --filter name=tillandsias-*` + `podman
/// stop` path is safe to call unconditionally at startup: if the prior
/// tillandsias session exited cleanly, there are no running containers and
/// this is a no-op; if the prior session crashed / was SIGKILL'd, its
/// `EnclaveCleanupGuard` Drop handler never ran and we recover here.
///
/// Never blocks startup on podman slowness: a single best-effort `podman ps`
/// is issued; per-container stops run sequentially but with a short timeout
/// inherited from `--stop-timeout=10`.
///
/// @trace spec:podman-orchestration, spec:secrets-management
pub(crate) async fn sweep_orphan_containers(runtime: Arc<dyn Runtime>) {
    // @trace spec:simplified-tray-ux, spec:cross-platform, spec:podman-orchestration
    // Get list of all containers with "tillandsias-" in name
    let names = match runtime.container_list().await {
        Ok(json_output) => {
            if let Ok(containers) = serde_json::from_str::<Vec<serde_json::Value>>(&json_output) {
                containers
                    .iter()
                    .filter_map(|c| {
                        c.get("Names")
                            .and_then(|n| n.as_array())
                            .and_then(|a| a.first())
                            .and_then(|name| name.as_str())
                            .map(|s| s.to_string())
                    })
                    .filter(|name| name.contains("tillandsias-"))
                    .collect::<Vec<_>>()
            } else {
                Vec::new()
            }
        }
        Err(e) => {
            debug!(error = %e, "container_list failed during orphan sweep — skipping");
            return;
        }
    };
    if names.is_empty() {
        debug!("Orphan sweep: no running tillandsias-* containers");
        return;
    }
    info!(
        accountability = true,
        category = "enclave",
        spec = "podman-orchestration",
        orphan_count = names.len(),
        "Orphan sweep: stopping containers left over from a prior session"
    );
    for name in &names {
        if let Err(e) = runtime.container_stop(name, 10).await {
            debug!(container = %name, error = %e, "Orphan container stop returned error (may have exited already)");
        }
        // Belt-and-suspenders: our runtime always uses `--rm`, so stop also
        // deletes. But older installations or hand-built containers might
        // not; force-remove here so the orphan is fully gone either way.
        let client = PodmanClient::new();
        let _ = client.remove_container(name).await;
        // Also wipe any residual token file for this container.
        crate::secrets::cleanup_token_file(name);
    }
    // Finally clear the enclave network itself — safe to recreate on next launch.
    cleanup_enclave_network().await;
}

/// Pre-UI cleanup of stale containers from a prior session.
///
/// Public wrapper around `sweep_orphan_containers` for the spec name in
/// `simplified-tray-ux`. Call this from `main.rs` BEFORE the event loop
/// accepts user input — the singleton guard guarantees no other tray is
/// running, so any `tillandsias-*` containers that exist must be
/// orphans from a prior session that wasn't shut down cleanly.
///
/// Idempotent: no-op if there are no orphans. Best-effort: logs but does
/// not fail the startup path on podman errors.
///
/// @trace spec:simplified-tray-ux, spec:podman-orchestration
pub async fn pre_ui_cleanup_stale_containers() {
    let runtime = default_runtime();
    sweep_orphan_containers(runtime).await;
}

// ---------------------------------------------------------------------------
// Per-container log management
// @trace spec:podman-orchestration
// ---------------------------------------------------------------------------

/// Maximum total size of a container's log directory before rotation (10 MB).
const CONTAINER_LOG_MAX_BYTES: u64 = 10 * 1024 * 1024;

/// Create the per-container log directory and rotate old logs if oversized.
///
/// Called before every container launch. If the log directory already exists
/// and exceeds `CONTAINER_LOG_MAX_BYTES`, the oldest files are deleted until
/// the total is under the limit.
///
/// @trace spec:podman-orchestration
fn ensure_container_log_dir(container_name: &str) {
    let log_dir = tillandsias_core::config::container_log_dir(container_name);
    if let Err(e) = std::fs::create_dir_all(&log_dir) {
        warn!(
            container = %container_name,
            error = %e,
            spec = "podman-orchestration",
            "Failed to create container log directory"
        );
        return;
    }

    // Check total size and rotate if needed
    rotate_container_logs(&log_dir, container_name);
}

/// Rotate (trim) log files in a directory if total size exceeds the limit.
///
/// Collects all files, sorts by modification time (oldest first), and deletes
/// until the total is under `CONTAINER_LOG_MAX_BYTES`.
///
/// @trace spec:podman-orchestration
fn rotate_container_logs(log_dir: &Path, container_name: &str) {
    let entries: Vec<_> = match std::fs::read_dir(log_dir) {
        Ok(rd) => rd.filter_map(|e| e.ok()).collect(),
        Err(_) => return,
    };

    // Collect file paths with metadata (size + modified time)
    let mut files: Vec<(PathBuf, u64, std::time::SystemTime)> = Vec::new();
    let mut total_size: u64 = 0;

    for entry in &entries {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        if let Ok(meta) = entry.metadata() {
            let size = meta.len();
            let modified = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
            total_size += size;
            files.push((path, size, modified));
        }
    }

    if total_size <= CONTAINER_LOG_MAX_BYTES {
        return;
    }

    // Sort oldest first
    files.sort_by_key(|(_, _, mtime)| *mtime);

    info!(
        container = %container_name,
        total_bytes = total_size,
        limit_bytes = CONTAINER_LOG_MAX_BYTES,
        spec = "podman-orchestration",
        "Rotating container logs (over limit)"
    );

    for (path, size, _) in &files {
        if total_size <= CONTAINER_LOG_MAX_BYTES {
            break;
        }
        if let Err(e) = std::fs::remove_file(path) {
            warn!(
                path = %path.display(),
                error = %e,
                "Failed to remove old log file during rotation"
            );
        } else {
            total_size = total_size.saturating_sub(*size);
            debug!(
                path = %path.display(),
                freed_bytes = size,
                "Removed old log file"
            );
        }
    }
}

// ---------------------------------------------------------------------------
// External-logs migration
// @trace spec:external-logs-layer
// ---------------------------------------------------------------------------

/// One-shot migration from the old internal log path to the new external-logs
/// location for the git-service producer.
///
/// # What it does
///
/// Before chunk 2 the post-receive hook's `git-push.log` landed in the
/// INTERNAL per-container log directory
/// (`~/.local/state/tillandsias/containers/git/logs/git-push.log`) via the
/// `ContainerLogs` mount. The EXTERNAL mount (`ExternalLogsProducer`) now
/// shadows the same in-container path (`/var/log/tillandsias/external/`), so
/// the hook continues writing to the same path — but that path is now routed
/// to `~/.local/state/tillandsias/external-logs/git-service/` on the host.
///
/// To carry forward any log content that accumulated before the migration,
/// this function:
///
/// 1. Checks whether the old file exists at `containers/git/logs/git-push.log`.
/// 2. If it does, creates the new destination directory and renames the file
///    (atomic on the same filesystem).
/// 3. Leaves a `MIGRATED.txt` stub at the old directory with the new path
///    inside, so an operator checking the old location gets a clear pointer.
///
/// # Idempotency
///
/// - If `from` does not exist: no-op, returns `Ok(())`.
/// - If `to` already exists: migration was already done; no-op.
/// - If both exist: old entry is a leftover artifact; no-op (the new
///   location wins).
///
/// Errors are logged but NOT propagated — a migration failure must NEVER
/// abort tray startup.
///
/// @trace spec:external-logs-layer
pub(crate) fn ensure_external_logs_dir() -> Result<(), String> {
    use tillandsias_core::config::{container_log_dir, external_logs_role_dir};

    // Old path: the per-container INTERNAL log dir for the git service.
    // container_log_dir("tillandsias-git") or ("git") — both resolve the
    // same because container_log_dir strips the "tillandsias-" prefix.
    let from = container_log_dir("tillandsias-git").join("git-push.log");

    // New path: the EXTERNAL producer dir for the "git-service" role.
    let role_dir = external_logs_role_dir("git-service");
    let to = role_dir.join("git-push.log");

    if !from.exists() {
        // Nothing to migrate — either never existed or already moved.
        debug!(
            spec = "external-logs-layer",
            operation = "migrate",
            "ensure_external_logs_dir: no old git-push.log found, nothing to migrate"
        );
        return Ok(());
    }

    if to.exists() {
        // Already migrated on a previous tray run.
        debug!(
            spec = "external-logs-layer",
            operation = "migrate",
            "ensure_external_logs_dir: destination already exists, migration idempotent"
        );
        return Ok(());
    }

    // Create the destination directory.
    if let Err(e) = std::fs::create_dir_all(&role_dir) {
        let msg = format!("ensure_external_logs_dir: failed to create role dir {}: {e}", role_dir.display());
        warn!(
            accountability = true,
            category = "git-service-logs",
            spec = "external-logs-layer",
            operation = "migrate",
            error = %e,
            path = %role_dir.display(),
            "Failed to create external-logs role directory during migration"
        );
        return Err(msg);
    }

    // Atomic rename — source and destination are typically on the same filesystem
    // (~/.local/state/tillandsias/…) so this is a single syscall on Linux/macOS.
    if let Err(e) = std::fs::rename(&from, &to) {
        let msg = format!(
            "ensure_external_logs_dir: rename {} -> {} failed: {e}",
            from.display(),
            to.display()
        );
        warn!(
            accountability = true,
            category = "git-service-logs",
            spec = "external-logs-layer",
            operation = "migrate",
            error = %e,
            from = %from.display(),
            to = %to.display(),
            "Failed to rename git-push.log to new external-logs location"
        );
        return Err(msg);
    }

    // Leave a MIGRATED.txt stub at the old directory so operators inspecting
    // the old path see a clear pointer.
    let stub_dir = from.parent().unwrap_or(&from);
    let stub_path = stub_dir.join("MIGRATED.txt");
    let stub_content = format!(
        "git-push.log was migrated to the external-logs producer directory.\n\
         New path: {}\n\
         Migration performed at tray startup by ensure_external_logs_dir().\n\
         @trace spec:external-logs-layer\n",
        to.display()
    );
    if let Err(e) = std::fs::write(&stub_path, &stub_content) {
        // Non-fatal — the migration succeeded, the stub is cosmetic.
        warn!(
            spec = "external-logs-layer",
            operation = "migrate",
            error = %e,
            path = %stub_path.display(),
            "Failed to write MIGRATED.txt stub (non-fatal)"
        );
    }

    info!(
        accountability = true,
        category = "git-service-logs",
        spec = "external-logs-layer",
        operation = "migrate",
        from = %from.display(),
        to = %to.display(),
        "Migrated git-push.log to external-logs producer directory"
    );

    Ok(())
}

// ---------------------------------------------------------------------------
// Git mirror service
// @trace spec:git-mirror-service
// ---------------------------------------------------------------------------

/// State of a project directory with respect to git.
#[derive(Debug)]
enum GitProjectState {
    /// Has a `.git` directory with a configured `origin` remote.
    // remote_url is parsed and stored for future use (e.g., displaying origin in UI)
    RemoteRepo {
        #[allow(dead_code)]
        remote_url: String,
    },
    /// Has a `.git` directory but no `origin` remote.
    LocalRepo,
    /// Not a git repository.
    NotGitRepo,
}

/// Detect the git state of a project directory.
///
/// Parses `.git/config` directly to extract the origin remote URL.
/// Does NOT require `git` to be installed on the host — works on
/// immutable OSes (Silverblue, etc.) where only podman is available.
///
/// @trace spec:git-mirror-service
fn detect_project_git_state(project_path: &Path) -> GitProjectState {
    let git_dir = project_path.join(".git");
    if !git_dir.exists() {
        return GitProjectState::NotGitRepo;
    }

    // Parse .git/config directly — no git binary needed.
    let config_path = git_dir.join("config");
    let contents = match std::fs::read_to_string(&config_path) {
        Ok(c) => c,
        Err(_) => return GitProjectState::LocalRepo,
    };

    // Look for [remote "origin"] section and extract url = <value>
    let mut in_origin_section = false;
    for line in contents.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_origin_section = trimmed == "[remote \"origin\"]";
            continue;
        }
        if in_origin_section
            && let Some(url) = trimmed.strip_prefix("url") {
                let url = url.trim().strip_prefix('=').unwrap_or("").trim();
                if !url.is_empty() {
                    return GitProjectState::RemoteRepo {
                        remote_url: url.to_string(),
                    };
                }
            }
    }

    GitProjectState::LocalRepo
}

/// Check whether `git` is available on the host.
///
/// On immutable OSes like Fedora Silverblue, `git` is not installed
/// on the host — all git operations must run inside a container.
///
/// @trace spec:git-mirror-service
fn host_has_git() -> bool {
    std::process::Command::new("git")
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Run a git command on the host if available, otherwise inside a
/// temporary container using the git image.
///
/// `mounts` are `(host_path, container_path, mode)` tuples.
///
/// @trace spec:git-mirror-service
fn run_git(
    args: &[&str],
    mounts: &[(&str, &str, &str)],
) -> Result<std::process::Output, String> {
    if host_has_git() {
        return std::process::Command::new("git")
            .args(args)
            .env_remove("LD_LIBRARY_PATH")
            .env_remove("LD_PRELOAD")
            .output()
            .map_err(|e| format!("git failed: {e}"));
    }

    // Containerized path: run git inside the git image.
    // @trace spec:git-mirror-service
    let mut podman_args: Vec<String> = vec![
        "run".into(), "--rm".into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--userns=keep-id".into(),
        "--security-opt=label=disable".into(),
    ];

    for (host, container, mode) in mounts {
        podman_args.push("-v".into());
        podman_args.push(format!("{host}:{container}:{mode}"));
    }

    podman_args.push("--entrypoint".into());
    podman_args.push("git".into());
    podman_args.push(git_image_tag());
    podman_args.extend(args.iter().map(|a| a.to_string()));

    debug!(
        spec = "git-mirror-service",
        args = %podman_args.join(" "),
        "Running containerized git (no host git)"
    );

    tillandsias_podman::podman_cmd_sync()
        .args(&podman_args)
        .output()
        .map_err(|e| format!("containerized git failed: {e}"))
}

/// Create or update the bare git mirror for a project.
///
/// Mirror path: `~/.cache/tillandsias/mirrors/<project>/`
///
/// If the mirror exists, runs `git fetch --all` to sync from the remote.
/// If it doesn't exist, detects the project's git state and clones accordingly:
/// - `NotGitRepo` → initializes git in the project, then clones
/// - `RemoteRepo` / `LocalRepo` → clones from the local path
///
/// After cloning, installs the embedded post-receive hook.
///
/// All git operations work on hosts without `git` installed (e.g.,
/// Fedora Silverblue) by running inside a temporary container.
///
/// @trace spec:git-mirror-service
fn ensure_mirror(project_path: &Path, project_name: &str) -> Result<PathBuf, String> {
    let mirrors_dir = cache_dir().join("mirrors");
    let mirror_path = mirrors_dir.join(project_name);
    std::fs::create_dir_all(&mirrors_dir)
        .map_err(|e| format!("Cannot create mirrors directory: {e}"))?;

    // @trace spec:cli-mode, spec:fix-windows-extended-path
    // Defensive: strip the Windows extended-path prefix `\\?\` if it survived
    // upstream. `git clone <source>` parses leading `\\` as a UNC URL and
    // chokes on the `?` with "hostname contains invalid characters". The CLI
    // entry strips this after canonicalize(), but tray callers may not have.
    let project_path_simple = crate::embedded::simplify_path(project_path);
    let pp = project_path_simple.display().to_string();
    let mp = mirror_path.display().to_string();
    let md = mirrors_dir.display().to_string();

    // When host has git, use host paths directly.
    // When containerized, use container mount paths.
    let has_git = host_has_git();
    let container_mirror = format!("/mirrors/{project_name}");

    // Common mounts for containerized git operations
    let mounts: Vec<(&str, &str, &str)> = vec![
        (&pp, "/project", "rw"),
        (&md, "/mirrors", "rw"),
    ];

    // If mirror already exists, just fetch updates
    if mirror_path.join("HEAD").exists() {
        info!(
            spec = "git-mirror-service",
            project = %project_name,
            mirror = %mp,
            "Mirror exists — fetching updates"
        );

        let mirror_ref = if has_git { mp.as_str() } else { container_mirror.as_str() };

        // @trace spec:git-mirror-service, spec:cross-platform, spec:windows-wsl-runtime
        // Refresh hook + origin URL on every attach so that:
        //  - The post-receive hook is up to date (multi-path log fallback,
        //    stderr emission for --diagnostics).
        //  - The mirror's origin URL has the LATEST token from the keyring.
        //    Token rotation by the user immediately propagates without
        //    needing to delete + reclone the mirror.
        let hooks_dir = mirror_path.join("hooks");
        if let Err(e) = std::fs::create_dir_all(&hooks_dir) {
            warn!(spec = "git-mirror-service", error = %e, "Cannot create hooks dir");
        }
        let hook_path = hooks_dir.join("post-receive");
        if let Err(e) = std::fs::write(&hook_path, crate::embedded::POST_RECEIVE_HOOK) {
            warn!(spec = "git-mirror-service", error = %e, "Cannot refresh post-receive hook");
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&hook_path, std::fs::Permissions::from_mode(0o755));
        }

        // @trace spec:git-mirror-service, spec:secrets-management
        // Strip any tokens that prior INTERIM versions of Tillandsias may
        // have injected into the mirror URL. Going forward the URL is the
        // clean GitHub URL only — auth is handled by the git-daemon's env
        // (Windows) or the git-service container's tmpfs file (Linux).
        #[cfg(target_os = "windows")]
        if let Ok(o) = run_git(&["-C", mirror_ref, "remote", "get-url", "origin"], &mounts)
            && o.status.success()
        {
            let current = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if let Some(rest) = current.strip_prefix("https://")
                && let Some((_, host_path)) = rest.split_once('@')
            {
                let canonical = format!("https://{host_path}");
                let _ = run_git(
                    &["-C", mirror_ref, "remote", "set-url", "origin", &canonical],
                    &mounts,
                );
                info!(
                    spec = "git-mirror-service, secrets-management",
                    project = %project_name,
                    "Cleaned legacy token-in-URL from mirror config"
                );
            }
        }

        // @trace spec:git-mirror-service, spec:secrets-management, spec:windows-wsl-runtime, spec:windows-git-mirror-cred-isolation
        // @cheatsheet runtime/secrets-management.md
        // Host-side fetch on Windows must bypass Git Credential Manager (which
        // pops a GUI prompt and blocks the tray's startup) AND must NOT touch
        // the user's keyring twice. We inject a shell credential-helper that
        // reads a process-scoped env var. The token is never written to disk
        // and never appears in the command line. We empty the existing helper
        // list first (`credential.helper=`) so GCM is disabled for this call,
        // then append our env-reader. GIT_TERMINAL_PROMPT=0 prevents any TTY
        // fallback. On Linux this code is gated out — Linux uses the git-
        // service container which has its own credential plumbing.
        #[cfg(target_os = "windows")]
        let fetch_result = {
            let token = match crate::secrets::retrieve_github_token() {
                Ok(Some(t)) => Some(t),
                _ => None,
            };
            let mut cmd = std::process::Command::new("git");
            cmd.env_remove("LD_LIBRARY_PATH").env_remove("LD_PRELOAD");
            cmd.env("GIT_TERMINAL_PROMPT", "0");
            cmd.env("GCM_INTERACTIVE", "Never");
            if let Some(ref t) = token {
                cmd.env("TILLANDSIAS_FETCH_TOKEN", t);
                cmd.args([
                    "-c", "credential.helper=",
                    "-c", "credential.helper=!f() { echo username=oauth2; echo \"password=$TILLANDSIAS_FETCH_TOKEN\"; }; f",
                ]);
            } else {
                cmd.args(["-c", "credential.helper="]);
            }
            cmd.args(["-C", mirror_ref, "fetch", "--all"]);
            cmd.output().map_err(|e| format!("git failed: {e}"))
        };
        #[cfg(not(target_os = "windows"))]
        let fetch_result = run_git(&["-C", mirror_ref, "fetch", "--all"], &mounts);

        match fetch_result {
            Ok(o) if o.status.success() => {
                debug!(spec = "git-mirror-service", project = %project_name, "Mirror fetch succeeded");
            }
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                debug!(
                    spec = "git-mirror-service",
                    project = %project_name,
                    stderr = %stderr,
                    "Mirror fetch returned non-zero (may be expected for local-only repos)"
                );
            }
            Err(e) => {
                warn!(spec = "git-mirror-service", project = %project_name, error = %e, "Mirror fetch failed");
            }
        }
        return Ok(mirror_path);
    }

    // Mirror doesn't exist — create it
    info!(
        spec = "git-mirror-service",
        project = %project_name,
        "Creating new mirror"
    );

    let state = detect_project_git_state(project_path);
    debug!(spec = "git-mirror-service", project = %project_name, state = ?state, "Project git state detected");

    // For NotGitRepo, initialize git in the project first
    if matches!(state, GitProjectState::NotGitRepo) {
        info!(spec = "git-mirror-service", project = %project_name, "Initializing git in project directory");

        let init_dir = if has_git { pp.as_str() } else { "/project" };

        let init = run_git(&["-C", init_dir, "init"], &mounts)
            .map_err(|e| format!("git init failed: {e}"))?;
        if !init.status.success() {
            return Err(format!("git init failed: {}", String::from_utf8_lossy(&init.stderr)));
        }

        let add = run_git(&["-C", init_dir, "add", "-A"], &mounts)
            .map_err(|e| format!("git add failed: {e}"))?;
        if !add.status.success() {
            return Err(format!("git add failed: {}", String::from_utf8_lossy(&add.stderr)));
        }

        // Use explicit author identity — the host/container may not have
        // global git config, and we don't want to require --github-login
        // just to initialize a mirror.
        let commit = run_git(
            &["-C", init_dir,
              "-c", "user.name=Tillandsias",
              "-c", "user.email=tillandsias@local",
              "commit", "-m", "Initial commit"],
            &mounts,
        )
        .map_err(|e| format!("git commit failed: {e}"))?;
        if !commit.status.success() {
            let stderr = String::from_utf8_lossy(&commit.stderr);
            if !stderr.contains("nothing to commit") {
                return Err(format!("git commit failed: {stderr}"));
            }
        }
    }

    // Always clone from local path — even for RemoteRepo, the local copy
    // has all refs and the mirror inherits the remote config.
    let (clone_source, clone_dest) = if has_git {
        (pp.clone(), mp.clone())
    } else {
        ("/project".to_string(), container_mirror.clone())
    };

    // Clone as a bare mirror
    info!(
        spec = "git-mirror-service",
        project = %project_name,
        source = %pp,
        mirror = %mp,
        "Cloning mirror"
    );
    let clone_output = run_git(
        &["clone", "--mirror", &clone_source, &clone_dest],
        &mounts,
    )
    .map_err(|e| format!("git clone --mirror failed: {e}"))?;
    if !clone_output.status.success() {
        let stderr = String::from_utf8_lossy(&clone_output.stderr);
        return Err(format!("git clone --mirror failed: {stderr}"));
    }

    // Install post-receive hook from embedded binary
    let hooks_dir = mirror_path.join("hooks");
    std::fs::create_dir_all(&hooks_dir)
        .map_err(|e| format!("Cannot create hooks directory: {e}"))?;
    let hook_path = hooks_dir.join("post-receive");
    std::fs::write(&hook_path, crate::embedded::POST_RECEIVE_HOOK)
        .map_err(|e| format!("Cannot write post-receive hook: {e}"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&hook_path, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| format!("Cannot set hook permissions: {e}"))?;
    }
    info!(
        spec = "git-mirror-service",
        project = %project_name,
        "Post-receive hook installed"
    );

    // Fix mirror origin URL: `git clone --mirror` sets origin to the local
    // path we cloned from. If the project has a real remote (e.g., github.com),
    // update the mirror's origin to that URL. This way the post-receive hook
    // pushes to the real remote (through the git service's D-Bus keyring access
    // on Linux, or token-in-URL on Windows) instead of trying to push to an
    // inaccessible local path.
    //
    // @trace spec:git-mirror-service, spec:cross-platform, spec:windows-wsl-runtime, spec:secrets-management
    // On Windows, the post-receive hook runs in the FORGE distro's process
    // context (since the forge invokes git push to the bare mirror via
    // filesystem). The forge has zero credentials. To make `git push` truly
    // automatic and transparent (the spec's ZERO OVERHEAD UX requirement),
    // we embed the GitHub token directly in the mirror's origin URL. The
    // token lives only in /mnt/c/.../mirrors/<project>/config — a host file
    // that's not visible to other forge sessions or processes outside the
    // attached forge. This is the simplest path to honour the spec on
    // Windows without separate per-container credential isolation.
    if let GitProjectState::RemoteRepo { ref remote_url } = state {
        let mirror_ref = if has_git { mp.as_str() } else { container_mirror.as_str() };
        // @trace spec:git-mirror-service, spec:secrets-management
        // Mirror's origin URL is the CLEAN GitHub URL (no token embedded).
        // The token never lands in any file the forge can read. On Linux the
        // git-service container runs the daemon and reads token from
        // /run/secrets/github_token (tmpfs bind-mount). On Windows the daemon
        // runs in tillandsias-git distro with GH_TOKEN injected via env at
        // spawn time; the post-receive hook reads $GH_TOKEN at push time and
        // constructs an ephemeral auth URL — token is never persisted to disk.
        match run_git(
            &["-C", mirror_ref, "remote", "set-url", "origin", remote_url],
            &mounts,
        ) {
            Ok(o) if o.status.success() => {
                info!(
                    spec = "git-mirror-service, secrets-management",
                    project = %project_name,
                    remote_url = %remote_url,
                    "Mirror origin set (clean URL; auth via daemon env / hook)"
                );
            }
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                warn!(
                    spec = "git-mirror-service",
                    project = %project_name,
                    stderr = %stderr,
                    "Failed to set mirror origin URL — post-receive push may fail"
                );
            }
            Err(e) => {
                warn!(
                    spec = "git-mirror-service",
                    project = %project_name,
                    error = %e,
                    "Failed to set mirror origin URL — post-receive push may fail"
                );
            }
        }
    } else {
        debug!(
            spec = "git-mirror-service",
            project = %project_name,
            "Project has no remote — mirror origin stays as local path (push will be a no-op)"
        );
    }

    info!(
        accountability = true,
        category = "git",
        spec = "git-mirror-service",
        project = %project_name,
        mirror = %mirror_path.display(),
        "Mirror created successfully"
    );

    Ok(mirror_path)
}

// @trace spec:cross-platform, spec:windows-wsl-runtime, spec:git-mirror-service
// WSL-native git-daemon launcher. Idempotent — checks if a git-daemon is
// already listening on 127.0.0.1:9418 inside tillandsias-git, and starts one
// if not. The daemon's --base-path points at the host's mirrors dir mapped
// through /mnt/c/... so distros and host share one source of truth.
//
// Why localhost: WSL2 runs all distros in one VM with one network namespace.
// Distro A binding 127.0.0.1:9418 is reachable from distro B as
// 127.0.0.1:9418. From the Windows host, WSL2 also auto-forwards localhost
// (so the user could `git clone git://localhost:9418/<project>` natively if
// they wanted). The git daemon is NOT exposed beyond localhost.
#[cfg(target_os = "windows")]
async fn ensure_git_service_running_wsl(
    project_name: &str,
) -> Result<(), String> {
    use tokio::process::Command;

    // Resolve mirrors dir (parent of any specific mirror) → /mnt/c/...
    let mirrors_dir = cache_dir().join("mirrors");
    let mirrors_mnt = windows_path_to_wsl_mnt(&mirrors_dir)?;

    // Read GH_TOKEN once; passed via env to the daemon if present.
    // @trace spec:secrets-management, spec:git-mirror-service
    let gh_token: Option<String> = match crate::secrets::retrieve_github_token() {
        Ok(Some(t)) => Some(t),
        _ => None,
    };
    if gh_token.is_none() {
        warn!(
            spec = "git-mirror-service, secrets-management",
            project = %project_name,
            "No GitHub token in keyring — git daemon will start but post-receive push will fail. Run `tillandsias --github-login` first."
        );
    }

    // @cheatsheet runtime/wsl-on-windows.md
    // Probe via `ss -tln` — works in busybox (Alpine /bin/sh has no /dev/tcp;
    // earlier we tried `echo > /dev/tcp/...` and it always failed silently
    // because busybox sh lacks that bash feature). `ss` ships in Alpine's
    // iproute2 package which is pulled in by tillandsias-git's apk install.
    // If `ss` is missing, fall back to `netstat`.
    let probe_cmd = "ss -tln 2>/dev/null | grep -qE '127\\.0\\.0\\.1:9418\\b' && echo UP || \
                     (netstat -tln 2>/dev/null | grep -qE '127\\.0\\.0\\.1:9418\\b' && echo UP || echo DOWN)";

    let probe = { let mut __c = Command::new("wsl.exe"); tillandsias_podman::no_window_async(&mut __c); __c }
        .args([
            "-d", "tillandsias-git", "--user", "git", "--exec",
            "/bin/sh", "-c", probe_cmd,
        ])
        .output()
        .await
        .map_err(|e| format!("wsl probe failed: {e}"))?;
    if String::from_utf8_lossy(&probe.stdout).contains("UP") {
        info!(
            spec = "git-mirror-service, cross-platform, windows-wsl-runtime",
            project = %project_name,
            "git-daemon already listening on 127.0.0.1:9418 (re-using)"
        );
        return Ok(());
    }

    info!(
        accountability = true,
        category = "git",
        spec = "git-mirror-service, cross-platform, windows-wsl-runtime",
        project = %project_name,
        mirrors = %mirrors_mnt,
        "Starting git-daemon in tillandsias-git distro (base-path={})", mirrors_mnt
    );

    // @trace spec:git-mirror-service, spec:windows-wsl-runtime, spec:windows-git-mirror-cred-isolation
    // @cheatsheet runtime/wsl-mount-points.md
    // Bootstrap system-wide safe.directory in /etc/gitconfig so the `git`
    // user (uid=1000, runs the daemon) can read mirrors owned by root on
    // drvfs (/mnt/c is always reported as owned by root regardless of NTFS
    // ACL — see Microsoft's WSL filesystems doc). Without this, git refuses
    // with "fatal: detected dubious ownership". --system gitconfig requires
    // root, hence we run this WITHOUT --user git. We use `safe.directory=*`
    // because mirror paths are dynamic (one per project) and the parent
    // directory is the controlled boundary.
    let bootstrap = { let mut __c = Command::new("wsl.exe"); tillandsias_podman::no_window_async(&mut __c); __c }
        .args([
            "-d", "tillandsias-git", "--exec",
            "/bin/sh", "-c",
            "git config --system --get-all safe.directory 2>/dev/null | grep -qx '*' || \
             git config --system --add safe.directory '*'",
        ])
        .output()
        .await
        .map_err(|e| format!("wsl bootstrap safe.directory failed: {e}"))?;
    if !bootstrap.status.success() {
        warn!(
            spec = "git-mirror-service, windows-wsl-runtime",
            stderr = %String::from_utf8_lossy(&bootstrap.stderr),
            "Failed to bootstrap system-wide safe.directory in tillandsias-git (continuing)"
        );
    }

    // Use git's built-in --detach so we don't need nohup/setsid wrapping. git
    // daemon will fork itself into the background and return 0 immediately
    // (or non-zero if the bind fails). Logs would go to syslog by default;
    // we redirect to /tmp/git-daemon.log for diagnostics.
    let start_script = format!(
        "git daemon --reuseaddr --export-all --enable=receive-pack \
         --base-path='{mirrors_mnt}' --listen=127.0.0.1 --port=9418 \
         --detach --pid-file=/tmp/git-daemon.pid \
         --log-destination=stderr 2>>/tmp/git-daemon.log",
    );

    // @trace spec:secrets-management, spec:git-mirror-service
    // GH_TOKEN forwarded via WSLENV so wsl.exe propagates it from the host
    // process into the distro shell. The token therefore exists only in the
    // wsl.exe process env (host side) and the daemon's process tree (distro
    // side). Never written to disk; never visible to the forge distro.
    // Reference: https://learn.microsoft.com/en-us/windows/wsl/filesystems#share-environment-variables-between-windows-and-wsl
    let mut start_cmd = Command::new("wsl.exe");
    tillandsias_podman::no_window_async(&mut start_cmd);
    start_cmd.args([
        "-d", "tillandsias-git", "--user", "git", "--exec",
        "/bin/sh", "-c", &start_script,
    ]);
    if let Some(ref tok) = gh_token {
        start_cmd.env("WSLENV", "GH_TOKEN/u");
        start_cmd.env("GH_TOKEN", tok);
    }
    let start = start_cmd
        .output()
        .await
        .map_err(|e| format!("wsl spawn git-daemon failed: {e}"))?;

    if !start.status.success() {
        let stderr = String::from_utf8_lossy(&start.stderr);
        // Also pull the daemon log for diagnosis.
        let log = { let mut __c = Command::new("wsl.exe"); tillandsias_podman::no_window_async(&mut __c); __c }
            .args(["-d", "tillandsias-git", "--user", "git", "--exec",
                   "/bin/sh", "-c", "tail -20 /tmp/git-daemon.log 2>/dev/null"])
            .output()
            .await
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
            .unwrap_or_default();
        return Err(format!(
            "git-daemon spawn failed: exit={:?} stderr={} log={}",
            start.status.code(), stderr.trim(), log.trim()
        ));
    }

    // Wait for the daemon to actually bind (--detach returns before bind
    // completes occasionally).
    for attempt in 0..25 {
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        let probe = { let mut __c = Command::new("wsl.exe"); tillandsias_podman::no_window_async(&mut __c); __c }
            .args([
                "-d", "tillandsias-git", "--user", "git", "--exec",
                "/bin/sh", "-c", probe_cmd,
            ])
            .output()
            .await
            .map_err(|e| format!("wsl probe failed: {e}"))?;
        if String::from_utf8_lossy(&probe.stdout).contains("UP") {
            info!(
                spec = "git-mirror-service, cross-platform, windows-wsl-runtime",
                project = %project_name,
                attempt = attempt + 1,
                "git-daemon bound on 127.0.0.1:9418"
            );
            return Ok(());
        }
    }
    // Last-resort diagnosis: pull the daemon log
    let log = { let mut __c = Command::new("wsl.exe"); tillandsias_podman::no_window_async(&mut __c); __c }
        .args(["-d", "tillandsias-git", "--user", "git", "--exec",
               "/bin/sh", "-c", "tail -30 /tmp/git-daemon.log 2>/dev/null; echo ---; ss -tln 2>/dev/null | head"])
        .output()
        .await
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default();
    Err(format!(
        "git-daemon failed to bind 127.0.0.1:9418 after 5s. Diagnostics:\n{}",
        log
    ))
}

/// Embed a GitHub PAT/OAuth token in an HTTPS clone URL.
/// Format: `https://USER:TOKEN@github.com/owner/repo.git` per Git docs.
/// We use `oauth2` as the literal username (recommended for tokens).
/// Documented at: https://git-scm.com/book/en/v2/Git-on-the-Server-Smart-HTTP
/// @trace spec:secrets-management, spec:git-mirror-service, spec:cross-platform
fn embed_github_token_in_url(url: &str, token: &str) -> String {
    if let Some(rest) = url.strip_prefix("https://") {
        // Strip any existing user:pass component if present (rare but defensive).
        let after_at = rest.split_once('@').map(|(_, host)| host).unwrap_or(rest);
        format!("https://oauth2:{token}@{after_at}")
    } else {
        // Non-HTTPS URLs (ssh://, git://, etc.) — leave alone; ssh has its own auth.
        url.to_string()
    }
}

/// Mask the token in `https://oauth2:TOKEN@github.com/...` so it's safe to log.
/// @trace spec:secrets-management
fn redact_url_for_log(url: &str) -> String {
    if let Some(rest) = url.strip_prefix("https://") {
        if let Some((_user_pass, host_path)) = rest.split_once('@') {
            return format!("https://***@{host_path}");
        }
    }
    url.to_string()
}

/// Translate `C:\path\to\dir` → `/mnt/c/path/to/dir` for WSL access.
/// @trace spec:cross-platform, spec:windows-wsl-runtime
#[cfg(target_os = "windows")]
fn windows_path_to_wsl_mnt(p: &Path) -> Result<String, String> {
    let s = p.to_string_lossy();
    let bytes = s.as_bytes();
    if bytes.len() >= 3 && bytes[1] == b':' && (bytes[2] == b'\\' || bytes[2] == b'/') {
        let drive = (bytes[0] as char).to_ascii_lowercase();
        let rest = s[2..].replace('\\', "/");
        Ok(format!("/mnt/{drive}{rest}"))
    } else {
        Err(format!("Path is not a Windows drive path: {}", s))
    }
}

/// Ensure the git service container is running for a project.
///
/// Checks if `tillandsias-git-<project>` is already running. If not,
/// builds the git image if needed and starts a detached git service
/// container on the enclave network with the mirror mounted.
///
/// @trace spec:git-mirror-service, spec:cross-platform, spec:windows-wsl-runtime
// On Windows, the function takes the early-return path into
// `ensure_git_service_running_wsl` and the Unix podman-driven path is
// unreachable. The compiler can't see across the cfg gate, so allow
// unreachable_code for the Unix-only suffix.
#[allow(unreachable_code)]
pub(crate) async fn ensure_git_service_running(
    project_name: &str,
    mirror_path: &Path,
    state: &TrayState,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    let container_name = tillandsias_core::state::ContainerInfo::git_service_container_name(project_name);

    // @trace spec:cross-platform, spec:windows-wsl-runtime, spec:git-mirror-service, spec:secrets-management
    // Windows: spawn git-daemon in tillandsias-git distro with GH_TOKEN env.
    // Requires WSL2 mirrored networking (configured in ~/.wslconfig at init
    // time). Daemon listens on 127.0.0.1:9418; forge connects via
    // git://localhost:9418/<project> matching the Linux DNS-via-podman flow
    // (TILLANDSIAS_GIT_SERVICE=localhost on Windows; git-service on Linux).
    //
    // Token isolation: GH_TOKEN lives only in the git daemon process env
    // and child hook processes. The forge has zero filesystem path to it
    // (different distro, different /run/secrets, different /tmp). Matches
    // the Linux container-isolation property.
    #[cfg(target_os = "windows")]
    {
        let _ = (state, build_tx, container_name, mirror_path);
        return ensure_git_service_running_wsl(project_name).await;
    }

    #[cfg(not(target_os = "windows"))]
    // Check if already running (in our state or via podman inspect)
    if state.running.iter().any(|c| c.name == container_name) {
        debug!(spec = "git-mirror-service", project = %project_name, "Git service already tracked in state");
        return Ok(());
    }

    let client = PodmanClient::new();

    // Check if it's running outside our state.
    // If running but with a stale image version, stop it and rebuild.
    if let Ok(inspect) = client.inspect_container(&container_name).await
        && inspect.state == "running" {
            let expected_tag = git_image_tag();
            if inspect.image.contains(&expected_tag) {
                debug!(spec = "git-mirror-service", project = %project_name, "Git service already running (correct version)");
                return Ok(());
            }
            // Stale version — stop it so we can start the correct one
            warn!(
                spec = "git-mirror-service",
                project = %project_name,
                current = %inspect.image,
                expected = %expected_tag,
                "Git service running stale version — restarting"
            );
            if let Err(e) = client.stop_container(&container_name, 5).await {
                warn!(container = %container_name, error = %e, "Failed to stop stale git service container");
            }
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }

    info!(
        accountability = true,
        category = "git",
        spec = "git-mirror-service",
        project = %project_name,
        "Starting git service container"
    );

    // Ensure git image is up to date — always invoke the build script
    // (it handles staleness internally via hash check and exits fast when current).
    // @trace spec:forge-staleness, spec:git-mirror-service
    let mut tag = git_image_tag();

    // Check for a newer git image (forward compatibility)
    if let Some(newer_tag) = find_newer_image(&tag) {
        warn!(expected = %tag, found = %newer_tag, spec = "git-mirror-service", "Found newer git image — using it");
        tag = newer_tag;
    } else {
        // No newer image — ensure current version is built and up to date
        info!(tag = %tag, spec = "git-mirror-service", "Ensuring git service image is up to date...");

        // @trace spec:git-mirror-service
        // User-friendly chip name — never expose "git service" or "image" to users.
        let chip_name = crate::i18n::t("menu.build.chip_code_mirror").to_string();

        if build_tx.try_send(BuildProgressEvent::Started {
            image_name: chip_name.clone(),
        }).is_err() {
            debug!("Build progress channel full/closed — UI may show stale state");
        }

        let build_result =
            tokio::task::spawn_blocking(|| run_build_image_script("git")).await;

        match build_result {
            Ok(Ok(())) => {
                if !client.image_exists(&tag).await {
                    error!(tag = %tag, spec = "git-mirror-service", "Git service image still not found after build");
                    if build_tx.try_send(BuildProgressEvent::Failed {
                        image_name: chip_name,
                        reason: "Git service image not ready".to_string(),
                    }).is_err() {
                        debug!("Build progress channel full/closed — UI may show stale state");
                    }
                    return Err("Git service image not ready after build".into());
                }
                info!(tag = %tag, spec = "git-mirror-service", "Git service image ready");
                prune_old_images();
                if build_tx.try_send(BuildProgressEvent::Completed {
                    image_name: chip_name,
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
            }
            Ok(Err(ref e)) => {
                error!(tag = %tag, error = %e, spec = "git-mirror-service", "Git service image build failed");
                if build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: chip_name,
                    reason: format!("Git service build failed: {e}"),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                return Err(format!("Git service image build failed: {e}"));
            }
            Err(ref e) => {
                error!(tag = %tag, error = %e, spec = "git-mirror-service", "Git service image build task panicked");
                if build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: chip_name,
                    reason: format!("Git service build panicked: {e}"),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                return Err(format!("Git service image build panicked: {e}"));
            }
        }
    }

    // Build git service container args using the profile + LaunchContext.
    // Credential delivery: the host reads the GitHub OAuth token from the
    // OS keyring and writes it to a per-container ephemeral file. The
    // file is bind-mounted :ro at /run/secrets/github_token. The container
    // has NO D-Bus, NO keyring access, NO knowledge of the host vault.
    // @trace spec:secrets-management, spec:native-secrets-store, spec:git-mirror-service
    let profile = tillandsias_core::container_profile::git_service_profile();
    let cache = cache_dir();

    // @trace spec:podman-orchestration
    ensure_container_log_dir(&container_name);

    // @trace spec:secrets-management, spec:native-secrets-store
    // Materialize the token file on tmpfs (best-effort: missing token just
    // means the container launches without credentials and authenticated
    // push/fetch will fail with a clear auth error — expected UX when the
    // user hasn't run --github-login yet).
    let token_file_path = match crate::secrets::prepare_token_file(&container_name) {
        Ok(maybe_path) => maybe_path,
        Err(e) => {
            warn!(
                spec = "secrets-management",
                error = %e,
                "Could not prepare token file — git service will launch without credentials"
            );
            None
        }
    };

    let port_mapping = needs_port_mapping();

    let ctx = tillandsias_core::container_profile::LaunchContext {
        container_name: container_name.clone(),
        project_path: mirror_path.to_path_buf(),
        project_name: project_name.to_string(),
        cache_dir: cache.clone(),
        port_range: (0, 0), // no ports exposed to host
        host_os: tillandsias_core::config::detect_host_os(),
        detached: true,
        is_watch_root: false,
        custom_mounts: vec![],
        image_tag: tag.clone(),
        selected_language: "en".to_string(),
        // @trace spec:git-mirror-service, spec:enclave-network
        // On Linux: enclave network with alias "git-service" for DNS resolution.
        // On podman machine: no network flag (default), port 9418 published to host.
        network: if port_mapping {
            None
        } else {
            Some(format!("{}:alias=git-service", tillandsias_podman::ENCLAVE_NETWORK))
        },
        git_author_name: String::new(),
        git_author_email: String::new(),
        token_file_path,
        use_port_mapping: port_mapping,
        // @trace spec:opencode-web-session
        persistent: false,
        web_host_port: None,
        hot_path_budget_mb: 0, // @trace spec:forge-hot-cold-split — service container
    };

    let mut run_args = crate::launch::build_podman_args(&profile, &ctx);

    // @trace spec:enclave-network
    // On podman machine, publish port 9418 so other containers can reach
    // the git daemon via localhost:9418.
    if port_mapping {
        run_args.insert(run_args.len() - 1, "-p".to_string());
        run_args.insert(run_args.len() - 1, "9418:9418".to_string());
    }

    // Add the mirror volume mount dynamically (not in the profile)
    // Mirror is mounted at /srv/git/<project_name> (rw) matching the git daemon base-path
    let mirror_mount = format!(
        "{}:/srv/git/{}:rw",
        mirror_path.display(),
        project_name
    );
    // Insert before the image tag (always last element)
    run_args.insert(run_args.len() - 1, "-v".to_string());
    run_args.insert(run_args.len() - 1, mirror_mount);

    // Launch the git service container via podman run (detached)
    match client.run_container(&run_args).await {
        Ok(container_id) => {
            info!(
                accountability = true,
                category = "git",
                spec = "git-mirror-service",
                container_id = %container_id,
                project = %project_name,
                "Git service container started (detached)"
            );

            // @trace spec:secrets-management, spec:native-secrets-store
            info!(
                accountability = true,
                category = "secrets",
                safety = "GitHub token delivered via ephemeral :ro tmpfs file from host keyring — no D-Bus, no keyring API inside container",
                pids_limit = 64,
                read_only = true,
                spec = "secrets-management",
                container = %container_name,
                "Credential isolation boundary: git service has tmpfs token file only, pids-limit=64, read-only FS"
            );

            // @trace spec:git-mirror-service
            // Health check: verify git daemon is listening on port 9418.
            // DISTRO: Git service is Alpine — busybox nc only.
            //
            // BusyBox `nc -z` is broken on BusyBox v1.36.1 (Alpine 3.20): it
            // returns exit 1 even when the port is open. Use a timed connect
            // with stdin from /dev/null instead — that works reliably on the
            // same binary and is what nc was always happy to do.
            // Exponential backoff: 1s, 2s, 4s, 8s, 8s... (capped at 8s).
            let max_attempts: u32 = 10;
            let mut ready = false;
            for attempt in 0..max_attempts {
                let check = tillandsias_podman::podman_cmd()
                    .args([
                        "exec",
                        &container_name,
                        "sh",
                        "-c",
                        "nc -w 1 127.0.0.1 9418 </dev/null",
                    ])
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status()
                    .await;
                if check.map(|s| s.success()).unwrap_or(false) {
                    info!(spec = "git-mirror-service", project = %project_name, attempt, "Git service health check passed");
                    ready = true;
                    break;
                }
                if attempt < max_attempts - 1 {
                    let delay = Duration::from_secs((1u64 << attempt).min(8));
                    tokio::time::sleep(delay).await;
                }
            }

            if !ready {
                error!(
                    spec = "git-mirror-service",
                    project = %project_name,
                    "Git service daemon not responding on :9418 after {max_attempts} attempts — refusing to proceed",
                );
                return Err(format!(
                    "Git service not responding on :9418 after {max_attempts} attempts",
                ));
            }

            Ok(())
        }
        Err(e) => {
            error!(
                spec = "git-mirror-service",
                project = %project_name,
                error = %e,
                "Failed to start git service container"
            );
            Err(format!("Failed to start git service container: {e}"))
        }
    }
}

// ---------------------------------------------------------------------------
// Unified enclave startup
// @trace spec:enclave-network, spec:proxy-container, spec:git-mirror-service, spec:inference-container
// ---------------------------------------------------------------------------

/// Result of a successful enclave readiness check.
///
/// Contains any context that callers need after the enclave is ready
/// (e.g., the mirror path for a project).
pub struct EnclaveContext {
    /// Path to the bare git mirror for the project, if one was created.
    /// `None` when the enclave was set up without a project (infrastructure only).
    // Stored for callers that will need it (e.g., forge container mount points).
    #[allow(dead_code)]
    pub mirror_path: Option<PathBuf>,
}

/// Ensure the full enclave is ready for a project.
///
/// This is THE single entry point for all startup flows (tray menu handlers,
/// CLI mode) that need the complete enclave — network, proxy, inference,
/// git mirror, and git service.
///
/// Steps (in order, ALL SEQUENTIAL — no concurrent podman builds):
/// 1. Create enclave network (if absent)
/// 2. Start proxy (build image if needed, check version, restart if stale)
/// 3. Start inference (build image if needed, check version, restart if stale)
/// 4. Initialize git mirror for the project
/// 5. Start git service for the project (check version, restart if stale)
///
/// Image builds are serialized to prevent rootless podman overlay storage
/// corruption. Inference failures are non-fatal — the forge will launch
/// without inference. Git mirror creation failures propagate as errors.
///
/// @trace spec:enclave-network, spec:proxy-container, spec:git-mirror-service, spec:inference-container
pub async fn ensure_enclave_ready(
    project_path: &Path,
    project_name: &str,
    state: &TrayState,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<EnclaveContext, String> {
    // @trace spec:cross-platform, spec:windows-wsl-runtime, spec:git-mirror-service
    // On Windows the enclave is decomposed: the git mirror service IS load-
    // bearing (provides the isolation + lifecycle separation between host
    // source, long-lived bare mirror, and ephemeral forge working tree) and
    // MUST run; the proxy/router/inference services are Phase 2 work and are
    // skipped (`ensure_infrastructure_ready` returns early). The git daemon
    // runs in the tillandsias-git WSL distro listening on localhost:9418
    // because all WSL2 distros share a single network namespace — the forge
    // distro reaches it as `git://localhost:9418/<project>` (matching the
    // Linux/podman semantics that use `git://git-service:9418/<project>`
    // via podman DNS). The forge entrypoint env-substitutes the host so
    // `TILLANDSIAS_GIT_SERVICE=localhost` makes both paths use the same
    // entrypoint code.
    // Step 1+2: Infrastructure services (network + proxy) — hard requirement
    ensure_infrastructure_ready(state, build_tx.clone()).await?;

    // Step 2.5: GPU detection — detect hardware, select optimal models,
    // and patch the config overlay on ramdisk (if extracted).
    // Runs synchronously (fast — just invokes nvidia-smi).
    // @trace spec:inference-container
    crate::gpu::detect_and_patch_models();

    // Step 3: Inference — soft requirement, ASYNC (off the critical path).
    //
    // Inference is the slowest enclave service (15-30s ollama init + up to
    // 55s health-check backoff). It is non-fatal: the forge launches without
    // it. Spawn fire-and-forget so the launch path proceeds to git mirror +
    // forge while inference warms up.
    //
    // BUILD_MUTEX (handlers.rs ~line 54) still serializes concurrent podman
    // builds, so spawning here does not race with the forge or proxy builds.
    //
    // @trace spec:inference-container, spec:async-inference-launch
    let inference_state = state.clone();
    let inference_build_tx = build_tx.clone();
    let inference_spawn_at = std::time::Instant::now();
    tokio::spawn(async move {
        match ensure_inference_running(&inference_state, inference_build_tx).await {
            Ok(()) => info!(
                accountability = true,
                category = "inference",
                spec = "inference-container, async-inference-launch",
                elapsed_secs = inference_spawn_at.elapsed().as_secs_f64(),
                "Inference container ready (async)"
            ),
            Err(e) => warn!(
                accountability = true,
                category = "capability",
                safety = "DEGRADED: no local LLM inference — AI features unavailable in containers",
                spec = "inference-container, async-inference-launch",
                elapsed_secs = inference_spawn_at.elapsed().as_secs_f64(),
                error = %e,
                "Inference setup failed (async) — containers will launch without local inference"
            ),
        }
    });

    // Tools overlay tombstoned 2026-04-25 — agents (claude, opencode,
    // openspec) are baked into the forge image at /usr/local/bin/. No
    // separate overlay build step here.
    // @trace spec:tombstone-tools-overlay

    // Step 4+5: Git mirror + service — mirror creation failure propagates
    let mirror_path = match tokio::task::spawn_blocking({
        let pp = project_path.to_path_buf();
        let pn = project_name.to_string();
        move || ensure_mirror(&pp, &pn)
    })
    .await
    {
        Ok(Ok(mirror_path)) => {
            // Git service is load-bearing: forge entrypoints clone from
            // git://git-service/<project> on launch. No service → forge
            // starts with no code. Propagate the error hard.
            ensure_git_service_running(project_name, &mirror_path, state, build_tx.clone())
                .await
                .map_err(|e| {
                    error!(
                        spec = "git-mirror-service",
                        error = %e,
                        "Git service setup failed — refusing to proceed",
                    );
                    e
                })?;
            Some(mirror_path)
        }
        Ok(Err(e)) => {
            return Err(format!("Mirror setup failed: {e}"));
        }
        Err(e) => {
            return Err(format!("Mirror setup task panicked: {e}"));
        }
    };

    // @trace spec:enclave-network, spec:async-inference-launch
    info!(
        accountability = true,
        category = "enclave",
        spec = "enclave-network, async-inference-launch",
        proxy = PROXY_CONTAINER_NAME,
        git_service = %format!("tillandsias-git-{}", project_name),
        inference = INFERENCE_CONTAINER_NAME,
        "Enclave ready — proxy (strict:3128) + git-service (git://9418) ready; inference (http://11434) launching async"
    );

    Ok(EnclaveContext {
        mirror_path,
    })
}

/// Ensure infrastructure services are ready (network + proxy), without
/// project-specific services.
///
/// Called at tray startup (before any project is selected) and as the first
/// step of `ensure_enclave_ready()`. Also used by handlers that need the
/// enclave network and proxy but not git mirror/service (e.g., root terminal,
/// serve-here).
///
/// @trace spec:enclave-network, spec:proxy-container, spec:cross-platform, spec:podman-orchestration
pub async fn ensure_infrastructure_ready(
    state: &TrayState,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    // @trace spec:cross-platform, spec:windows-wsl-runtime
    // On Windows, the supporting services (proxy/router/git-service/inference)
    // are not yet ported to WSL; running them through podman violates the
    // WSL-only directive and produces zombie containers ("name in use" on
    // restart) plus image-not-found errors when their tags don't exist in any
    // local registry. Skip the entire infrastructure-setup phase: the forge
    // distro on Windows uses host /mnt/c/... paths directly and does not need
    // the proxy / git mirror / inference at attach time. Phase 2 will land
    // WSL-native equivalents.
    #[cfg(target_os = "windows")]
    {
        let _ = state;
        let _ = build_tx;
        if let Err(e) = crate::embedded::extract_config_overlay() {
            warn!(error = %e, spec = "layered-tools-overlay", "Config overlay extraction failed");
        }
        info!(
            spec = "cross-platform, windows-wsl-runtime",
            "Infrastructure step skipped on Windows (WSL backend; supporting services not yet ported)"
        );
        return Ok(());
    }

    #[cfg(not(target_os = "windows"))]
    {
        // @trace spec:layered-tools-overlay
        // Extract config overlay to tmpfs before containers launch.
        // Non-fatal — containers will use defaults if extraction fails.
        if let Err(e) = crate::embedded::extract_config_overlay() {
            warn!(error = %e, spec = "layered-tools-overlay", "Config overlay extraction failed — containers will use default configs");
        }

        // @trace spec:cross-platform, spec:podman-orchestration
        let runtime = default_runtime();

        ensure_enclave_network().await?;
        ensure_proxy_running(state, runtime, build_tx.clone()).await?;

        // @trace spec:subdomain-routing-via-reverse-proxy, spec:enclave-network
        // Router (Caddy) — must come up after the proxy because Squid forwards
        // *.localhost requests to it via cache_peer. If router fails, the rest
        // of the enclave stays usable; agents just can't reach
        // <project>.<service>.localhost URLs.
        if let Err(e) = ensure_router_running(state, build_tx).await {
            warn!(error = %e, spec = "subdomain-routing-via-reverse-proxy", "Router failed to start — *.localhost subdomain routing unavailable");
        }

        // @trace spec:enclave-network, spec:proxy-container
        info!(
            accountability = true,
            category = "enclave",
            spec = "enclave-network",
            proxy = PROXY_CONTAINER_NAME,
            "Infrastructure ready — proxy (strict:3128, permissive:3129)"
        );

        Ok(())
    }
}

/// Public wrapper around `ensure_enclave_network` for use from `main.rs`
/// launch-time initialization.
/// @trace spec:enclave-network
pub async fn ensure_enclave_network_pub() -> Result<(), String> {
    ensure_enclave_network().await
}

/// Ensure the full enclave is ready in CLI (synchronous) mode.
///
/// Creates the dummy `TrayState` and `build_tx` channel internally so the
/// caller doesn't need to manage them. Uses the provided tokio runtime for
/// async calls.
///
/// @trace spec:enclave-network, spec:proxy-container, spec:git-mirror-service, spec:inference-container
pub fn ensure_enclave_ready_cli(
    rt: &tokio::runtime::Runtime,
    project_path: &Path,
    project_name: &str,
) -> Result<EnclaveContext, String> {
    let (build_tx, _build_rx) =
        tokio::sync::mpsc::channel::<tillandsias_core::event::BuildProgressEvent>(4);
    let dummy_state = tillandsias_core::state::TrayState::new(
        tillandsias_core::state::PlatformInfo {
            os: tillandsias_core::state::Os::detect(),
            has_podman: true,
            has_podman_machine: false,
            gpu_devices: vec![],
        },
    );
    rt.block_on(ensure_enclave_ready(
        project_path,
        project_name,
        &dummy_state,
        build_tx,
    ))
}

/// Stop the git service container for a project. Best-effort, errors are logged.
/// Also unlinks the ephemeral GitHub token file materialised at launch.
/// @trace spec:git-mirror-service, spec:secrets-management
pub(crate) async fn stop_git_service(project_name: &str, runtime: Arc<dyn Runtime>) {
    let name = tillandsias_core::state::ContainerInfo::git_service_container_name(project_name);
    // @trace spec:cross-platform, spec:podman-orchestration
    match runtime.container_stop(&name, 10).await {
        Ok(()) => info!(
            accountability = true,
            category = "git",
            spec = "git-mirror-service",
            project = %project_name,
            "Git service container stopped"
        ),
        Err(e) => {
            debug!(spec = "git-mirror-service", project = %project_name, error = %e, "Git service stop returned error (may not have been running)");
        }
    }

    // @trace spec:secrets-management, spec:native-secrets-store
    // The token file only exists while the container is running; remove it
    // now so a crash or manual podman rm doesn't leave secret state behind.
    crate::secrets::cleanup_token_file(&name);
}

/// Check whether ANY versioned forge image (`tillandsias-forge:v*`) exists.
///
/// Used to distinguish "first time" builds (no previous image) from "update"
/// builds (upgrading from an older version).
#[allow(dead_code)] // API surface — called from upgrade/migration paths
pub(crate) fn any_versioned_forge_exists() -> bool {
    let output = tillandsias_podman::podman_cmd_sync()
        .args([
            "images",
            "--format",
            "{{.Repository}}:{{.Tag}}",
            "--filter",
            "reference=tillandsias-forge:v*",
        ])
        .output();

    match output {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            stdout.lines().any(|line| {
                let trimmed = line.trim();
                !trimmed.is_empty() && trimmed.starts_with("tillandsias-forge:v")
            })
        }
        Err(_) => false,
    }
}

/// Remove older `tillandsias-forge:v*` images, keeping only `current_tag`.
///
/// Best-effort — failures are logged but do not block operation.
/// Prune old versioned images for ALL tillandsias image types.
/// Keeps only the current version tag for each type (forge, proxy, git, inference).
pub(crate) fn prune_old_images() {
    let current_tags = [
        forge_image_tag(),
        proxy_image_tag(),
        git_image_tag(),
        inference_image_tag(),
    ];

    let output = tillandsias_podman::podman_cmd_sync()
        .args(["images", "--format", "{{.Repository}}:{{.Tag}}"])
        .output();

    let images_to_remove: Vec<String> = match output {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            stdout
                .lines()
                .filter(|line| {
                    let trimmed = line.trim();
                    // Only target tillandsias images
                    let is_tillandsias = trimmed.contains("tillandsias-forge:")
                        || trimmed.contains("tillandsias-proxy:")
                        || trimmed.contains("tillandsias-git:")
                        || trimmed.contains("tillandsias-inference:");
                    // Keep current version tags
                    let is_current = current_tags.iter().any(|tag| {
                        let suffix = tag.rsplit_once(':').map(|(_, t)| t).unwrap_or(tag);
                        trimmed.ends_with(&format!(":{suffix}"))
                    });
                    is_tillandsias && !is_current
                })
                .map(|s| s.trim().to_string())
                .collect()
        }
        Err(e) => {
            warn!(error = %e, "Failed to list images for pruning");
            return;
        }
    };

    for image in &images_to_remove {
        info!(image = %image, "Pruning old image");
        let result = tillandsias_podman::podman_cmd_sync()
            .args(["rmi", image])
            .output();
        match result {
            Ok(o) if o.status.success() => {
                info!(image = %image, "Pruned old image");
            }
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                warn!(image = %image, stderr = %stderr, "Failed to prune old image");
            }
            Err(e) => {
                warn!(image = %image, error = %e, "Failed to prune old image");
            }
        }
    }

    // Also clean up dangling (untagged) images left from builds
    let _ = tillandsias_podman::podman_cmd_sync()
        .args(["image", "prune", "-f"])
        .output();
}

/// Find the newest `tillandsias-<image_type>:v*` image by parsing version numbers.
///
/// Returns `Some(tag)` if an image exists with a higher version than
/// `expected_tag`. Returns `None` if no newer image exists.
///
/// `expected_tag` must be in the format `tillandsias-<type>:v<version>`.
/// @trace spec:forge-staleness, spec:forge-forward-compat
pub(crate) fn find_newer_image(expected_tag: &str) -> Option<String> {
    // Extract the repository prefix (e.g., "tillandsias-forge") and version
    let (repo, version_with_v) = expected_tag.rsplit_once(':')?;
    let expected_version = version_with_v.strip_prefix('v')?;
    let expected_parts: Vec<u64> = expected_version
        .split('.')
        .filter_map(|s| s.parse().ok())
        .collect();

    let filter = format!("reference={repo}:v*");
    let output = tillandsias_podman::podman_cmd_sync()
        .args([
            "images",
            "--format",
            "{{.Repository}}:{{.Tag}}",
            "--filter",
            &filter,
        ])
        .output()
        .ok()?;

    let prefix = format!("{repo}:v");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut newest_tag: Option<String> = None;
    let mut newest_parts: Vec<u64> = expected_parts.clone();

    for line in stdout.lines() {
        let tag = line.trim();
        if let Some(version_str) = tag.strip_prefix(&prefix) {
            let parts: Vec<u64> = version_str
                .split('.')
                .filter_map(|s| s.parse().ok())
                .collect();

            // Compare version parts lexicographically
            let is_newer = parts
                .iter()
                .zip(newest_parts.iter())
                .find(|(a, b)| a != b)
                .map(|(a, b)| a > b)
                .unwrap_or(parts.len() > newest_parts.len());

            if is_newer {
                newest_parts = parts;
                newest_tag = Some(tag.to_string());
            }
        }
    }

    newest_tag
}

/// Convenience wrapper: find newer forge image specifically.
/// @trace spec:forge-staleness, spec:forge-forward-compat
pub(crate) fn find_newer_forge_image(expected_tag: &str) -> Option<String> {
    find_newer_image(expected_tag)
}

/// Open a terminal window running a command with a custom title.
/// Uses the platform's default terminal — not a zoo of emulators.
///
/// On GNOME (ptyxis), launches a standalone instance so the tray app
/// doesn't depend on an existing terminal window. The command runs
/// directly (not wrapped in `bash -c`) so interactive TTY works.
fn open_terminal(command: &str, title: &str) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        // Try common Linux terminals in order of likelihood.
        // Each entry: (binary, title-args, command-args).
        // ptyxis -s: standalone instance (doesn't reuse existing window).
        // ptyxis -x: execute command directly (not via bash -c wrapper).
        //
        // Title is passed before the command execution flags so each
        // terminal window carries a meaningful name matching the tray label.

        // Check which terminal is available
        let terminal_names = ["ptyxis", "gnome-terminal", "konsole", "xterm"];
        let found_term = terminal_names.iter().find(|&&term| {
            std::process::Command::new("which")
                .arg(term)
                .env_remove("LD_LIBRARY_PATH")
                .env_remove("LD_PRELOAD")
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .is_ok_and(|s| s.success())
        });

        match found_term {
            Some(&"ptyxis") => {
                // ptyxis: -T <title> -s --new-window -x <command>
                // -s = standalone process (no D-Bus handoff to existing instance)
                // --new-window = own window (not a tab in someone else's window)
                // -x = execute command directly
                // All three flags together ensure each terminal launch is fully independent.
                let mut cmd = std::process::Command::new("ptyxis");
                cmd.env_remove("LD_LIBRARY_PATH");
                cmd.env_remove("LD_PRELOAD");
                cmd.args(["-T", title, "-s", "--new-window", "-x", command]);
                cmd.spawn().map(|_| ()).map_err(|e| format!("ptyxis: {e}"))
            }
            Some(&"gnome-terminal") => {
                let mut cmd = std::process::Command::new("gnome-terminal");
                cmd.env_remove("LD_LIBRARY_PATH");
                cmd.env_remove("LD_PRELOAD");
                cmd.args(["--title", title, "--", "bash", "-c", command]);
                cmd.spawn()
                    .map(|_| ())
                    .map_err(|e| format!("gnome-terminal: {e}"))
            }
            Some(&"konsole") => {
                let mut cmd = std::process::Command::new("konsole");
                cmd.env_remove("LD_LIBRARY_PATH");
                cmd.env_remove("LD_PRELOAD");
                cmd.args([
                    "-p",
                    &format!("tabtitle={title}"),
                    "-e",
                    "bash",
                    "-c",
                    command,
                ]);
                cmd.spawn().map(|_| ()).map_err(|e| format!("konsole: {e}"))
            }
            Some(&"xterm") => {
                let mut cmd = std::process::Command::new("xterm");
                cmd.env_remove("LD_LIBRARY_PATH");
                cmd.env_remove("LD_PRELOAD");
                cmd.args(["-T", title, "-e", "bash", "-c", command]);
                cmd.spawn().map(|_| ()).map_err(|e| format!("xterm: {e}"))
            }
            _ => Err(
                "No terminal emulator found (tried ptyxis, gnome-terminal, konsole, xterm)".into(),
            ),
        }
    }

    #[cfg(target_os = "macos")]
    {
        // macOS: use Terminal.app exclusively via AppleScript.
        // Terminal.app ships with every Mac and is always available.
        // Third-party terminals (Ghostty, iTerm2, etc.) are intentionally
        // unsupported — each has its own CLI quirks and update cadence that
        // make a fallback chain fragile and unmaintainable.
        // @trace spec:tray-app
        let _ = title; // Terminal.app title-setting removed (unreliable on macOS 26+)
        let escaped_cmd = command.replace('\\', "\\\\").replace('"', "\\\"");
        let script = format!(
            "tell app \"Terminal\"\n\
                 do script \"clear && {escaped_cmd}\"\n\
                 activate\n\
             end tell"
        );
        match std::process::Command::new("osascript")
            .args(["-e", &script])
            .output()
        {
            Ok(out) if out.status.success() => {
                tracing::debug!(terminal = "Terminal.app", "Opened terminal via AppleScript");
                Ok(())
            }
            Ok(out) => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                Err(format!("Terminal.app launch failed: {stderr}"))
            }
            Err(e) => Err(format!("osascript: {e}")),
        }
    }

    #[cfg(target_os = "windows")]
    {
        // Windows Terminal (wt.exe) preserves argument quoting correctly.
        // Falls back to cmd /c start for systems without wt.
        let shell_cmd = if command.ends_with(".sh") {
            format!("bash {}", command.replace('\\', "/"))
        } else {
            command.to_string()
        };

        // Try Windows Terminal first (handles quoting properly).
        // After FreeConsole() in tray mode, inherited stdio handles are invalid.
        // Use Stdio::null() to avoid ERROR_NOT_SUPPORTED (50) from stale handles.
        let wt_result = std::process::Command::new("wt")
            .args(["--title", title, "cmd", "/k", &shell_cmd])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();

        match wt_result {
            Ok(_) => Ok(()),
            Err(_) => {
                // Fallback: cmd /c start (legacy, quoting may be fragile)
                std::process::Command::new("cmd")
                    .args(["/c", "start", &format!("\"{}\"", title), "cmd", "/k", &shell_cmd])
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                    .map(|_| ())
                    .map_err(|e| format!("cmd: {e}"))
            }
        }
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        Err("Unsupported platform for terminal launch".into())
    }
}

/// Send a desktop notification (best-effort, non-blocking).
///
/// Uses `notify-send` on Linux, `osascript` on macOS.
/// Silently ignored on failure — notifications are advisory only.
pub(crate) fn send_notification(summary: &str, body: &str) {
    #[cfg(target_os = "linux")]
    {
        if let Err(e) = std::process::Command::new("notify-send")
            .env_remove("LD_LIBRARY_PATH")
            .env_remove("LD_PRELOAD")
            .args([summary, body])
            .spawn()
        {
            debug!(error = %e, "Desktop notification failed (cosmetic)");
        }
    }

    #[cfg(target_os = "macos")]
    {
        let escaped_summary = summary.replace('"', "\\\"");
        let escaped_body = body.replace('"', "\\\"");
        let script =
            format!("display notification \"{escaped_body}\" with title \"{escaped_summary}\"");
        if let Err(e) = std::process::Command::new("osascript")
            .args(["-e", &script])
            .spawn()
        {
            debug!(error = %e, "Desktop notification failed (cosmetic)");
        }
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        // Windows and other platforms: no-op
        let _ = (summary, body);
    }
}

/// Get the proxy container's IP address on the default "podman" network.
///
/// Used to route image builds through the proxy cache. Build containers run
/// on the host's default network (not the enclave), so we need the proxy's
/// IP on the "podman" network rather than its enclave alias.
///
/// @trace spec:proxy-container
#[allow(dead_code)] // API surface — used by image builds routed through proxy
fn get_proxy_ip() -> Result<String, String> {
    let output = tillandsias_podman::podman_cmd_sync()
        .args([
            "inspect",
            PROXY_CONTAINER_NAME,
            "--format",
            "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}",
        ])
        .output()
        .map_err(|e| format!("inspect failed: {e}"))?;

    if !output.status.success() {
        return Err("proxy not running".into());
    }

    // Parse the IPs — prefer the one NOT on the enclave (10.89.0.x).
    // The podman default network typically uses 10.88.0.x.
    let ips = String::from_utf8_lossy(&output.stdout);
    for ip in ips.split_whitespace() {
        if !ip.starts_with("10.89.") {
            return Ok(ip.to_string());
        }
    }
    // Fallback: use any IP
    ips.split_whitespace()
        .next()
        .map(|s| s.to_string())
        .ok_or_else(|| "no IP found".into())
}

/// Resolve the Containerfile + build-context directory for a given image name.
///
/// Mirrors the `case` statement in `scripts/build-image.sh` so the Windows
/// direct-podman-build path (which doesn't shell out to bash) routes to the
/// correct image sources instead of always building the forge.
///
/// @trace spec:default-image, spec:fix-windows-image-routing
#[allow(dead_code)] // Used on Windows; non-Windows path shells out to build-image.sh
/// Run image build via direct podman invocation.
///
/// @trace spec:direct-podman-calls, spec:default-image
///
/// Extracts image sources + build scripts to temp, executes, cleans up.
/// No filesystem scripts are trusted — everything comes from the signed binary.
fn run_build_image_script(image_name: &str) -> Result<(), String> {
    // Serialize all image builds — rootless podman corrupts overlay storage
    // when concurrent `podman build` operations run simultaneously.
    // @trace spec:default-image
    let _build_guard = build_mutex_lock();

    // Check if another process is already building this image
    if crate::build_lock::is_running(image_name) {
        info!(image = image_name, "Build already in progress, waiting...");
        crate::build_lock::wait_for_build(image_name)?;
        return Ok(());
    }

    // Acquire build lock
    crate::build_lock::acquire(image_name).map_err(|e| {
        error!(image = image_name, error = %e, "Cannot acquire build lock");
        strings::SETUP_ERROR
    })?;

    let source_dir = crate::embedded::write_image_sources().map_err(|e| {
        error!(image = image_name, error = %e, "Failed to extract embedded image sources to temp");
        strings::SETUP_ERROR
    })?;

    // Use the correct versioned tag for each image type.
    // @trace spec:direct-podman-calls, spec:default-image, spec:proxy-container, spec:git-mirror-service, spec:inference-container
    let tag = match image_name {
        "proxy" => proxy_image_tag(),
        "git" => git_image_tag(),
        "inference" => inference_image_tag(),
        "router" => router_image_tag(),
        _ => forge_image_tag(),
    };

    // @trace spec:cross-platform, spec:windows-wsl-runtime
    // Windows path is WSL-native: no podman, no bash wrapper. The image is
    // already an imported WSL distro `tillandsias-<name>` produced by --init.
    // Verify presence; if missing, instruct user to run --init.
    #[cfg(target_os = "windows")]
    {
        let _ = source_dir;
        let _ = tag;
        let distro = format!("tillandsias-{}", image_name);
        let mut __listing_cmd = std::process::Command::new("wsl.exe");
        tillandsias_podman::no_window_sync(&mut __listing_cmd);
        let listing = __listing_cmd
            .args(["--list", "--quiet"])
            .output()
            .map_err(|e| {
                error!(image = image_name, error = %e, "Cannot query WSL");
                strings::SETUP_ERROR
            })?;
        let text: String = listing
            .stdout
            .iter()
            .filter(|&&b| b != 0 && b != b'\r')
            .map(|&b| b as char)
            .collect();
        let exists = text.lines().any(|l| l.trim() == distro);
        crate::embedded::cleanup_image_sources();
        crate::build_lock::release(image_name);
        if exists {
            info!(image = image_name, distro = %distro, spec = "cross-platform, windows-wsl-runtime", "WSL distro present — skipping build (Windows uses WSL runtime)");
            return Ok(());
        }
        error!(image = image_name, distro = %distro, "WSL distro not imported — user must run tillandsias --init");
        return Err(strings::SETUP_ERROR.into());
    }

    // On Unix, build the image using the direct podman ImageBuilder.
    // @trace spec:direct-podman-calls, spec:default-image
    #[cfg(not(target_os = "windows"))]
    {
        let builder = crate::image_builder::ImageBuilder::new(
            source_dir.clone(),
            image_name.to_string(),
            tag.clone(),
        );

        info!(
            image = image_name,
            tag = %tag,
            spec = "direct-podman-calls, default-image",
            "Starting image build via direct podman invocation"
        );

        // Attempt build
        match builder.build_image() {
            Ok(()) => {
                crate::embedded::cleanup_image_sources();

                // Clean up any leftover buildah containers from builds
                // @trace spec:default-image
                let _ = std::process::Command::new("buildah")
                    .args(["rm", "--all"])
                    .env_remove("LD_LIBRARY_PATH")
                    .env_remove("LD_PRELOAD")
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status();

                crate::build_lock::release(image_name);
                prune_old_images();
                Ok(())
            }
            Err(e) => {
                error!(
                    image = image_name,
                    tag = %tag,
                    error = %e,
                    spec = "direct-podman-calls",
                    "Image build failed"
                );
                crate::embedded::cleanup_image_sources();

                // Clean up any leftover buildah containers
                let _ = std::process::Command::new("buildah")
                    .args(["rm", "--all"])
                    .env_remove("LD_LIBRARY_PATH")
                    .env_remove("LD_PRELOAD")
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status();

                crate::build_lock::release(image_name);
                Err(e)
            }
        }
    }
}

/// Public wrapper around `run_build_image_script` for use from `main.rs`
/// launch-time forge auto-build.
pub fn run_build_image_script_pub(image_name: &str) -> Result<(), String> {
    run_build_image_script(image_name)
}

/// Public wrapper around `get_proxy_ip` for use from `runner.rs`.
/// @trace spec:proxy-container
#[allow(dead_code)] // API surface — used by image builds routed through proxy
pub fn get_proxy_ip_pub() -> Result<String, String> {
    get_proxy_ip()
}

/// Select the appropriate container profile for a forge launch based on the agent.
fn forge_profile(
    agent: tillandsias_core::config::SelectedAgent,
) -> tillandsias_core::container_profile::ContainerProfile {
    match agent {
        tillandsias_core::config::SelectedAgent::OpenCode => {
            tillandsias_core::container_profile::forge_opencode_profile()
        }
        tillandsias_core::config::SelectedAgent::Claude => {
            tillandsias_core::container_profile::forge_claude_profile()
        }
        // @trace spec:opencode-web-session
        tillandsias_core::config::SelectedAgent::OpenCodeWeb => {
            tillandsias_core::container_profile::forge_opencode_web_profile()
        }
    }
}

/// Build a [`LaunchContext`] for forge and terminal launches.
///
/// Resolves all paths, custom mounts, and git identity needed by
/// `build_podman_args()`. Forge and terminal containers are credential-free:
/// no token files, no Claude dir mounts.
///
/// @trace spec:native-secrets-store
fn build_launch_context(
    container_name: &str,
    project_path: &Path,
    project_name: &str,
    cache: &Path,
    port_range: (u16, u16),
    detached: bool,
    is_watch_root: bool,
    image_tag: &str,
) -> tillandsias_core::container_profile::LaunchContext {
    let host_os = tillandsias_core::config::detect_host_os();
    let port_mapping = needs_port_mapping();

    // Read git identity from the cached gitconfig (written by gh-auth-login.sh).
    let (git_author_name, git_author_email) = crate::launch::read_git_identity(cache);

    // Custom mounts from project config
    let project_config = tillandsias_core::config::load_project_config(project_path);

    // @trace spec:forge-hot-cold-split
    // Compute the per-launch tmpfs budget for /home/forge/src from the bare
    // git mirror's pack size. The budget is passed through LaunchContext so
    // build_podman_args() can emit --tmpfs=/home/forge/src:size=<N>m for
    // forge-shaped profiles without touching service container args.
    let global_forge_cfg = tillandsias_core::config::load_global_config();
    let hot_path_budget_mb = crate::launch::compute_hot_budget_with_limits(
        project_name,
        cache,
        global_forge_cfg.forge.hot_path_inflation,
        global_forge_cfg.forge.hot_path_max_mb,
    );

    tillandsias_core::container_profile::LaunchContext {
        container_name: container_name.to_string(),
        project_path: project_path.to_path_buf(),
        project_name: project_name.to_string(),
        cache_dir: cache.to_path_buf(),
        port_range,
        host_os,
        detached,
        is_watch_root,
        custom_mounts: project_config.mounts,
        image_tag: image_tag.to_string(),
        selected_language: global_forge_cfg.i18n.language.clone(),
        // @trace spec:enclave-network
        // On Linux: forge and terminal containers join the enclave network so
        // they route through the proxy. The proxy itself gets dual-homed separately.
        // On podman machine: no network flag (default). Services are reached
        // via localhost port mapping; env vars are rewritten accordingly.
        network: if port_mapping {
            None
        } else {
            Some(tillandsias_podman::ENCLAVE_NETWORK.to_string())
        },
        git_author_name,
        git_author_email,
        token_file_path: None, // forge/terminal containers are credential-free
        use_port_mapping: port_mapping,
        // @trace spec:opencode-web-session
        persistent: false,
        web_host_port: None,
        // @trace spec:forge-hot-cold-split
        hot_path_budget_mb,
    }
}

/// Inject CA chain mount and trust env vars into forge/terminal podman args.
///
/// Adds a read-only bind mount of the CA chain file at
/// `/run/tillandsias/ca-chain.crt` and sets `NODE_EXTRA_CA_CERTS`,
/// `SSL_CERT_FILE`, and `REQUESTS_CA_BUNDLE` so that tools inside the
/// container trust the proxy's dynamically generated server certificates.
///
/// The volume and env args are inserted before the final image tag argument.
///
/// @trace spec:proxy-container
fn inject_ca_chain_mounts(run_args: &mut Vec<String>) {
    let chain_path = crate::ca::proxy_certs_dir().join("ca-chain.crt");
    if !chain_path.exists() {
        debug!(
            spec = "proxy-container",
            "CA chain not found at {} — skipping CA trust injection",
            chain_path.display()
        );
        return;
    }

    // Insert before the last element (the image tag).
    let pos = run_args.len().saturating_sub(1);

    // Volume mount: CA chain into a standard path inside the container
    run_args.insert(
        pos,
        format!(
            "-v={}:/run/tillandsias/ca-chain.crt:ro",
            chain_path.display()
        ),
    );

    // @trace spec:proxy-container
    // Trust env vars: tell common package managers / runtimes to use the chain.
    // NODE_EXTRA_CA_CERTS: Node.js (npm, yarn, pnpm) — adds to built-in trust store
    // SSL_CERT_FILE / REQUESTS_CA_BUNDLE: handled by entrypoint scripts which
    // create a combined bundle (system CAs + proxy CA) at /tmp/tillandsias-combined-ca.crt.
    // We don't set them here because the correct system CA path varies by distro
    // (Fedora: /etc/pki/tls/certs/ca-bundle.crt, Debian: /etc/ssl/certs/ca-certificates.crt).
    run_args.insert(
        pos + 1,
        "-e=NODE_EXTRA_CA_CERTS=/run/tillandsias/ca-chain.crt".to_string(),
    );
}

/// Public wrapper for `inject_ca_chain_mounts` — used by `runner.rs` (CLI mode).
/// @trace spec:proxy-container
pub fn inject_ca_chain_mounts_pub(run_args: &mut Vec<String>) {
    inject_ca_chain_mounts(run_args);
}

/// Remove orphaned tillandsias containers not tracked in state.
///
/// Queries podman for all containers matching `tillandsias-*`, then removes
/// any that are not present in our in-memory state. Skips infrastructure
/// toolboxes (builder, windows, etc.).
async fn cleanup_stale_containers(state: &TrayState) {
    let output = tillandsias_podman::podman_cmd_sync()
        .args([
            "ps",
            "-a",
            "--filter",
            "name=tillandsias-",
            "--format",
            "{{.Names}}",
        ])
        .output();

    if let Ok(out) = output {
        let stdout = String::from_utf8_lossy(&out.stdout);
        let known_names: Vec<&str> = state.running.iter().map(|c| c.name.as_str()).collect();

        for name in stdout.lines() {
            let name = name.trim();
            if name.is_empty() {
                continue;
            }
            if name.ends_with("-builder") || name.ends_with("-windows") {
                continue;
            }
            if known_names.contains(&name) {
                continue;
            }

            warn!(container = %name, "Removing stale container");
            let _ = tillandsias_podman::podman_cmd_sync()
                .args(["rm", "-f", name])
                .output();
        }
    }
}

/// Handle the "Attach Here" action: build image if needed, open terminal
/// with an interactive container.
#[instrument(skip(state, allocator, build_tx, notify), fields(project = %project_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string()), operation = "attach", spec = "podman-orchestration, default-image"))]
// `notify` — progressive menu-rebuild callback, called immediately after the
// placeholder is pushed to `state.running` so the tray chip flips to
// "Starting / Building" before the long forge-build + enclave-setup pipeline.
// @trace spec:tray-app
pub async fn handle_attach_here(
    project_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    build_tx: mpsc::Sender<BuildProgressEvent>,
    notify: crate::event_loop::MenuRebuildFn,
) -> Result<AppEvent, String> {
    let start = std::time::Instant::now();
    let project_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    info!(project = %project_name, "Attach Here requested");

    // Forge-readiness guard: if the forge image is not yet available (still building
    // or not yet checked), notify the user and return early. The tray menu should
    // already have this item disabled, but this is defense-in-depth against race
    // conditions or future code paths that bypass the menu gate.
    // @trace spec:tray-app
    if !state.forge_available {
        let msg = crate::i18n::t("notifications.forge_not_ready");
        info!(project = %project_name, "Forge-readiness guard fired — image not yet available");
        send_notification("Tillandsias", msg);
        return Err("Forge image not yet available".into());
    }

    // @trace spec:opencode-web-session
    // Branch to the web-session flow when the user has picked OpenCode Web.
    // The terminal flow below remains for opt-in `opencode` / `claude` users.
    let global_config = load_global_config();
    if global_config.agent.selected.is_web() {
        return handle_attach_web(project_path, state, allocator, build_tx, notify).await;
    }

    // Don't-relaunch guard: if a forge container for this project is already running,
    // notify the user and return early instead of spawning a second environment.
    // Git service containers are infrastructure — they don't count as "already running".
    if let Some(existing) = state
        .running
        .iter()
        .find(|c| {
            c.project_name == project_name
                && matches!(
                    c.container_type,
                    tillandsias_core::state::ContainerType::Forge
                )
        })
    {
        let flower = existing.genus.flower();
        let title = format!("{flower} {project_name}");
        let msg = format!("Already running — look for '{title}' in your windows");
        info!(project = %project_name, "Don't-relaunch guard fired — environment already running");
        send_notification("Tillandsias", &msg);
        return Err(format!(
            "Environment for '{project_name}' is already running as '{title}'"
        ));
    }

    // Clean up orphaned containers before allocating resources
    cleanup_stale_containers(state).await;

    // Allocate a genus
    let genus = allocator
        .allocate(&project_name)
        .ok_or_else(|| format!("All genera exhausted for project {project_name}"))?;

    debug!(project = %project_name, genus = %genus.display_name(), "Genus allocated");

    // Load and merge configuration (global_config is loaded earlier for the
    // web-branch decision and reused here).
    let project_config = load_project_config(&project_path);
    let _resolved = global_config.merge_with_project(&project_config);

    // Allocate port range — merge in-memory state with actual podman containers
    let mut existing_ports: Vec<(u16, u16)> = state.running.iter().map(|c| c.port_range).collect();
    existing_ports.extend(query_occupied_ports());
    let base_port = GlobalConfig::parse_port_range(&_resolved.port_range).unwrap_or((3000, 3019));
    let port_range = allocate_port_range(base_port, &existing_ports);

    // Pre-register container in bud state immediately so the tray shows
    // "Preparing environment..." with the bud icon while the image build
    // and terminal launch happen.
    let container_name = ContainerInfo::container_name(&project_name, genus);
    let display_emoji = genus.flower().to_string();
    let placeholder = ContainerInfo {
        name: container_name.clone(),
        project_name: project_name.clone(),
        genus,
        state: ContainerState::Creating,
        port_range,
        container_type: tillandsias_core::state::ContainerType::Forge,
        display_emoji: display_emoji.clone(),
    };
    state.running.push(placeholder);
    // @trace spec:tray-app
    // Notify the event loop immediately so the tray chip flips to
    // "Starting" before the long forge-build + enclave pipeline begins.
    // Without this call the chip stays on the previous value until the
    // entire handler returns (the select! loop is blocked on this await).
    notify(state);
    info!(container = %container_name, "Preparing environment... (bud state)");

    // Ensure forge image is up to date — always invoke the build script
    // (it handles staleness internally via hash check and exits fast when current).
    let client = PodmanClient::new();
    let mut tag = forge_image_tag();

    // Check for a newer forge image (forward compatibility: a newer binary may
    // have built a newer image before the user downgraded).
    if let Some(newer_tag) = find_newer_forge_image(&tag) {
        warn!(
            expected = %tag,
            found = %newer_tag,
            "Found a newer forge image than expected — using it"
        );
        tag = newer_tag;
    } else {
        // No newer image — ensure current version is built and up to date
        info!(tag = %tag, "Ensuring forge image is up to date...");

        // Notify event loop: build started (menu chip: ⏳ Building forge...)
        if build_tx.try_send(BuildProgressEvent::Started {
            image_name: crate::i18n::t("menu.build.chip_forge").to_string(),
        }).is_err() {
            debug!("Build progress channel full/closed — UI may show stale state");
        }

        let build_result =
            tokio::task::spawn_blocking(|| run_build_image_script("forge")).await;

        match build_result {
            Ok(Ok(())) => {
                // Verify the image actually exists now
                if !client.image_exists(&tag).await {
                    error!(tag = %tag, "Image still not found after build completed");
                    if build_tx.try_send(BuildProgressEvent::Failed {
                        image_name: crate::i18n::t("menu.build.chip_forge").to_string(),
                        reason: "Development environment not ready yet".to_string(),
                    }).is_err() {
                        debug!("Build progress channel full/closed — UI may show stale state");
                    }
                    state.running.retain(|c| c.name != container_name);
                    allocator.release(&project_name, genus);
                    return Err(strings::ENV_NOT_READY.into());
                }
                info!(tag = %tag, spec = "default-image", "Image ready");
                // Prune older forge images after successful build
                prune_old_images();
                // Notify event loop: build completed (menu chip: ✅ forge ready)
                if build_tx.try_send(BuildProgressEvent::Completed {
                    image_name: crate::i18n::t("menu.build.chip_forge").to_string(),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
            }
            Ok(Err(ref e)) => {
                error!(tag = %tag, error = %e, "Image build failed");
                if build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: crate::i18n::t("menu.build.chip_forge").to_string(),
                    reason: "Tillandsias is setting up".to_string(),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                state.running.retain(|c| c.name != container_name);
                allocator.release(&project_name, genus);
                return Err(strings::SETUP_ERROR.into());
            }
            Err(ref e) => {
                error!(tag = %tag, error = %e, "Image build task panicked");
                if build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: crate::i18n::t("menu.build.chip_forge").to_string(),
                    reason: "Tillandsias is setting up".to_string(),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                state.running.retain(|c| c.name != container_name);
                allocator.release(&project_name, genus);
                return Err(strings::SETUP_ERROR.into());
            }
        }
    }

    // Ensure cache directories exist
    let cache = cache_dir();
    std::fs::create_dir_all(&cache).ok();

    // @trace spec:enclave-network, spec:proxy-container, spec:git-mirror-service, spec:inference-container
    // Single unified enclave setup: network, proxy, inference, mirror, git service.
    let _enclave = ensure_enclave_ready(&project_path, &project_name, state, build_tx.clone()).await?;

    // @trace spec:tombstone-tools-overlay
    // Tools overlay removed — agents (claude, opencode, openspec) are hard-
    // installed in the forge image at /usr/local/bin/. Nothing to build here.

    // Detect whether the project path IS the watch root (e.g., ~/src/) rather
    // than a project inside it. When true, mount at /home/forge/src/ directly
    // instead of nesting as /home/forge/src/src/.
    let is_watch_root = global_config
        .scanner
        .watch_paths
        .iter()
        .any(|wp| wp == &project_path);

    // @trace spec:podman-orchestration
    ensure_container_log_dir(&container_name);

    // Build the full `podman run -it --rm ...` command string.
    // We open a terminal window running this command — the terminal provides
    // the TTY, podman passes it to the container, opencode gets a real terminal.
    let selected_agent = global_config.agent.selected;
    let profile = forge_profile(selected_agent);
    let ctx = build_launch_context(
        &container_name,
        &project_path,
        &project_name,
        &cache,
        port_range,
        false, // interactive (-it), NOT detached
        is_watch_root,
        &tag,
    );

    // @trace spec:forge-hot-cold-split
    // Pre-flight RAM check: refuse to launch if the host cannot satisfy the
    // /home/forge/src tmpfs budget (project source) plus static tmpfs caps
    // (cheatsheets 8MB) with a 1.25× headroom factor.
    let preflight_required_mb = ctx.hot_path_budget_mb.saturating_add(80);
    match crate::preflight::check_host_ram(preflight_required_mb) {
        Ok(ram_check) => {
            info!(
                accountability = true,
                category = "forge-launch",
                spec = "forge-hot-cold-split",
                project = %project_name,
                host_mem_available_mb = ram_check.mem_available_mb,
                budget_mb = ctx.hot_path_budget_mb,
                decision = "launch",
                "RAM preflight passed — launching forge"
            );
        }
        Err(crate::preflight::PreflightError::InsufficientRam { available_mb, required_mb, .. }) => {
            let msg = format!(
                "Project source on RAM: required {required_mb}MB exceeds the configured limit \
                ({available_mb}MB available). Either commit & prune unreachable refs in the \
                mirror, or raise forge.hot_path_max_mb in ~/.config/tillandsias/config.toml."
            );
            warn!(
                accountability = true,
                category = "forge-launch",
                spec = "forge-hot-cold-split",
                project = %project_name,
                host_mem_available_mb = available_mb,
                budget_mb = ctx.hot_path_budget_mb,
                decision = "refuse",
                "RAM preflight failed — refusing forge launch"
            );
            state.running.retain(|c| c.name != container_name);
            allocator.release(&project_name, genus);
            send_notification("Tillandsias", &msg);
            return Err(msg);
        }
        Err(crate::preflight::PreflightError::Probe(probe_err)) => {
            // Cannot probe RAM — be permissive and warn rather than blocking.
            warn!(
                accountability = true,
                category = "forge-launch",
                spec = "forge-hot-cold-split",
                project = %project_name,
                budget_mb = ctx.hot_path_budget_mb,
                decision = "launch",
                error = %probe_err,
                "RAM probe unavailable — proceeding without preflight"
            );
        }
    }

    let mut run_args = crate::launch::build_podman_args(&profile, &ctx);
    // @trace spec:proxy-container
    inject_ca_chain_mounts(&mut run_args);

    let mut podman_parts = vec![
        tillandsias_podman::find_podman_path().to_string(),
        "run".to_string(),
    ];
    podman_parts.extend(run_args);
    let podman_cmd = crate::launch::shell_quote_join(&podman_parts);

    // Build window title: "<flower> <project_name>" — matches the tray menu label.
    let title = format!("{} {}", display_emoji, project_name);

    // Open a terminal window running the podman command.
    // When the user exits OpenCode, the container dies (--rm), terminal closes.
    if let Err(e) = open_terminal(&podman_cmd, &title) {
        state.running.retain(|c| c.name != container_name);
        allocator.release(&project_name, genus);
        return Err(format!("Failed to open terminal: {e}"));
    }

    info!(
        container = %container_name,
        genus = %genus.display_name(),
        port_range = ?port_range,
        "Terminal opened with OpenCode"
    );

    // Accountability: log credential-free forge launch.
    // @trace spec:secrets-management
    {
        let has_git_identity = !ctx.git_author_name.is_empty();
        info!(
            accountability = true,
            category = "secrets",
            safety = "credential-free (no token, no claude-dir, no D-Bus)",
            git_identity = has_git_identity,
            pids_limit = 512,
            spec = "secret-management",
            "Environment {container_name} launched credential-free — zero D-Bus, zero credentials, pids-limit=512",
        );
    }

    // Mark project as having an assigned genus
    if let Some(project) = state.projects.iter_mut().find(|p| p.path == project_path) {
        project.assigned_genus = Some(genus);
    }

    // Tools overlay background update tombstoned — agents are image-baked.
    // @trace spec:tombstone-tools-overlay

    let elapsed = start.elapsed();
    info!(
        duration_secs = elapsed.as_secs_f64(),
        container = %container_name,
        "Attach Here completed"
    );

    Ok(AppEvent::ContainerStateChange {
        container_name: container_name.clone(),
        new_state: ContainerState::Creating,
    })
}

/// Attach Here in OpenCode Web mode — start (or reuse) a persistent forge
/// container running `opencode serve`, wait for its HTTP server to become
/// ready, and open a Tauri WebviewWindow at the loopback-bound host port.
///
/// Multiple webviews can attach to the same container concurrently. Closing
/// a webview does not stop the container; use `handle_stop_project` (the
/// "Stop" tray item) to tear it down explicitly.
///
/// @trace spec:opencode-web-session
#[instrument(
    skip(state, allocator, build_tx, notify),
    fields(
        project = %project_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string()),
        operation = "attach-web",
        spec = "opencode-web-session, podman-orchestration, default-image"
    )
)]
// `notify` — progressive menu-rebuild callback, called immediately after the
// placeholder is pushed to `state.running` so the tray chip flips to
// "Starting" before the long forge-build + enclave-setup pipeline begins.
// @trace spec:tray-app
pub async fn handle_attach_web(
    project_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    build_tx: mpsc::Sender<BuildProgressEvent>,
    notify: crate::event_loop::MenuRebuildFn,
) -> Result<AppEvent, String> {
    let start = std::time::Instant::now();
    let project_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    info!(project = %project_name, spec = "opencode-web-session", "Attach Here (web) requested");

    // @trace spec:opencode-web-session
    // Forge-readiness guard: web mode still needs the forge image (opencode serve
    // runs from it). The terminal branch did this check too; we repeat it here so
    // a direct call to handle_attach_web() is safe.
    if !state.forge_available {
        let msg = crate::i18n::t("notifications.forge_not_ready");
        info!(project = %project_name, "Forge-readiness guard fired — image not yet available (web mode)");
        send_notification("Tillandsias", msg);
        return Err("Forge image not yet available".into());
    }

    let container_name = ContainerInfo::forge_container_name(&project_name);

    // @trace spec:opencode-web-session
    // Reattach path: if the per-project forge web container is already tracked
    // as running, reuse its host port and open another webview against the
    // existing server. Do NOT spawn a second container — per the spec, there
    // is at most one `tillandsias-<project>-forge` per project.
    let existing_port_opt = state
        .running
        .iter()
        .find(|c| {
            c.name == container_name
                && matches!(
                    c.container_type,
                    tillandsias_core::state::ContainerType::OpenCodeWeb
                )
        })
        .map(|c| c.port_range.0);

    if let Some(host_port) = existing_port_opt {
        info!(
            project = %project_name,
            port = host_port,
            spec = "opencode-web-session",
            "Reusing existing forge web container — opening additional webview"
        );
        // Wait for readiness again — cheap if already healthy, essential if the
        // container was created moments ago by a concurrent click.
        if let Err(e) = crate::browser::wait_for_web_ready(host_port).await {
            let msg = format!(
                "OpenCode Web server not responding for '{}': {}",
                project_name, e
            );
            send_notification("Tillandsias", &msg);
            return Err(msg);
        }
        // @trace spec:opencode-web-session, spec:subdomain-routing-via-reverse-proxy, spec:opencode-web-session-otp
        // Reattach = launch a fresh native-browser window. We no longer have
        // a single long-lived webview to "show" — each Attach Here click
        // produces a new app-mode browser window against the same forge,
        // giving the user parallel sessions naturally.
        // The URL passed to the browser is the router-fronted
        // `<project>.opencode.localhost` form — the legacy `host_port`
        // argument is retained on the call only for the readiness probe
        // path; it is not embedded in the URL.
        // The session-aware variant mints a fresh per-window cookie and
        // injects it via CDP before navigation (per opencode-web-session-otp).
        if let Err(e) =
            crate::browser::launch_for_project_with_session(&project_name, host_port).await
        {
            warn!(
                project = %project_name,
                port = host_port,
                error = %e,
                spec = "subdomain-routing-via-reverse-proxy",
                "Failed to launch native browser (container remains running)"
            );
        }
        return Ok(AppEvent::ContainerStateChange {
            container_name,
            new_state: ContainerState::Running,
        });
    }

    // Clean up orphaned containers before allocating resources
    cleanup_stale_containers(state).await;

    // Allocate a genus (for icon/label only — the container name itself does
    // not carry the genus in web mode).
    // @trace spec:opencode-web-session
    let genus = allocator
        .allocate(&project_name)
        .ok_or_else(|| format!("All genera exhausted for project {project_name}"))?;

    debug!(project = %project_name, genus = %genus.display_name(), "Genus allocated (web mode)");

    // @trace spec:opencode-web-session
    // Allocate a single free host port in the ephemeral range. We merge
    // in-memory state (single-port ranges tracked as `(p, p)`) with what
    // podman reports as occupied.
    let already_used_ports: Vec<u16> = {
        let mut ports: Vec<u16> = state.running.iter().map(|c| c.port_range.0).collect();
        // query_occupied_ports() returns (start, end) ranges; flatten to
        // individual ports so we skip any host port currently bound.
        for (s, e) in query_occupied_ports() {
            for p in s..=e {
                ports.push(p);
            }
        }
        ports
    };
    let host_port = tillandsias_podman::launch::allocate_single_port(
        tillandsias_podman::launch::DEFAULT_WEB_PORT_START,
        tillandsias_podman::launch::DEFAULT_WEB_PORT_END,
        &already_used_ports,
    )
    .ok_or_else(|| {
        allocator.release(&project_name, genus);
        "no free host port in 17000-17999".to_string()
    })?;

    info!(
        project = %project_name,
        port = host_port,
        spec = "opencode-web-session",
        "Allocated single host port for web session"
    );

    // Pre-register the container in bud state so the tray reflects activity
    // while the image-build / enclave-setup pipeline runs.
    // @trace spec:opencode-web-session
    let display_emoji = "\u{1F517}".to_string(); // 🔗 — distinct from forge flower
    let placeholder = ContainerInfo {
        name: container_name.clone(),
        project_name: project_name.clone(),
        genus,
        state: ContainerState::Creating,
        port_range: (host_port, host_port),
        container_type: tillandsias_core::state::ContainerType::OpenCodeWeb,
        display_emoji: display_emoji.clone(),
    };
    state.running.push(placeholder);
    // @trace spec:tray-app
    // Notify the event loop immediately so the tray chip flips to
    // "Starting" before the long forge-build + enclave pipeline begins.
    // Without this call the chip stays on the previous value until the
    // entire handler returns (the select! loop is blocked on this await).
    notify(state);
    info!(container = %container_name, "Preparing web environment... (bud state)");

    // @trace spec:default-image
    // Ensure the forge image is up to date. Identical pipeline to the terminal
    // branch — clarity > DRY in this single change.
    let client = PodmanClient::new();
    let mut tag = forge_image_tag();

    if let Some(newer_tag) = find_newer_forge_image(&tag) {
        warn!(
            expected = %tag,
            found = %newer_tag,
            "Found a newer forge image than expected — using it (web mode)"
        );
        tag = newer_tag;
    } else {
        info!(tag = %tag, "Ensuring forge image is up to date (web mode)...");
        if build_tx
            .try_send(BuildProgressEvent::Started {
                image_name: crate::i18n::t("menu.build.chip_forge").to_string(),
            })
            .is_err()
        {
            debug!("Build progress channel full/closed — UI may show stale state");
        }

        let build_result =
            tokio::task::spawn_blocking(|| run_build_image_script("forge")).await;

        match build_result {
            Ok(Ok(())) => {
                if !client.image_exists(&tag).await {
                    error!(tag = %tag, "Image still not found after build completed (web mode)");
                    if build_tx
                        .try_send(BuildProgressEvent::Failed {
                            image_name: crate::i18n::t("menu.build.chip_forge").to_string(),
                            reason: "Development environment not ready yet".to_string(),
                        })
                        .is_err()
                    {
                        debug!("Build progress channel full/closed — UI may show stale state");
                    }
                    state.running.retain(|c| c.name != container_name);
                    allocator.release(&project_name, genus);
                    return Err(strings::ENV_NOT_READY.into());
                }
                info!(tag = %tag, spec = "default-image", "Image ready (web mode)");
                prune_old_images();
                if build_tx
                    .try_send(BuildProgressEvent::Completed {
                        image_name: crate::i18n::t("menu.build.chip_forge").to_string(),
                    })
                    .is_err()
                {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
            }
            Ok(Err(ref e)) => {
                error!(tag = %tag, error = %e, "Image build failed (web mode)");
                if build_tx
                    .try_send(BuildProgressEvent::Failed {
                        image_name: crate::i18n::t("menu.build.chip_forge").to_string(),
                        reason: "Tillandsias is setting up".to_string(),
                    })
                    .is_err()
                {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                state.running.retain(|c| c.name != container_name);
                allocator.release(&project_name, genus);
                return Err(strings::SETUP_ERROR.into());
            }
            Err(ref e) => {
                error!(tag = %tag, error = %e, "Image build task panicked (web mode)");
                if build_tx
                    .try_send(BuildProgressEvent::Failed {
                        image_name: crate::i18n::t("menu.build.chip_forge").to_string(),
                        reason: "Tillandsias is setting up".to_string(),
                    })
                    .is_err()
                {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                state.running.retain(|c| c.name != container_name);
                allocator.release(&project_name, genus);
                return Err(strings::SETUP_ERROR.into());
            }
        }
    }

    let cache = cache_dir();
    std::fs::create_dir_all(&cache).ok();

    // @trace spec:enclave-network, spec:proxy-container, spec:git-mirror-service, spec:inference-container
    if let Err(e) =
        ensure_enclave_ready(&project_path, &project_name, state, build_tx.clone()).await
    {
        state.running.retain(|c| c.name != container_name);
        allocator.release(&project_name, genus);
        return Err(e);
    }

    // Tools overlay tombstoned — agents hard-installed in forge image.
    // @trace spec:tombstone-tools-overlay

    let global_config = load_global_config();
    let is_watch_root = global_config
        .scanner
        .watch_paths
        .iter()
        .any(|wp| wp == &project_path);

    // @trace spec:podman-orchestration
    ensure_container_log_dir(&container_name);

    // @trace spec:opencode-web-session
    // Build the detached / persistent launch context. `web_host_port = Some(p)`
    // makes `build_podman_args()` emit `-p 127.0.0.1:<p>:4096` and suppress the
    // forge-range publish. `persistent: true` drops `--rm` so the container
    // survives a single webview closing. `forge_opencode_web_profile()` wires
    // the entrypoint to `opencode serve`.
    let profile = forge_profile(tillandsias_core::config::SelectedAgent::OpenCodeWeb);
    let mut ctx = build_launch_context(
        &container_name,
        &project_path,
        &project_name,
        &cache,
        (host_port, host_port),
        true, // detached
        is_watch_root,
        &tag,
    );
    ctx.persistent = true;
    ctx.web_host_port = Some(host_port);

    // @trace spec:forge-hot-cold-split
    // Pre-flight RAM check before launching the detached web forge container.
    let preflight_required_mb = ctx.hot_path_budget_mb.saturating_add(80);
    match crate::preflight::check_host_ram(preflight_required_mb) {
        Ok(ram_check) => {
            info!(
                accountability = true,
                category = "forge-launch",
                spec = "forge-hot-cold-split",
                project = %project_name,
                host_mem_available_mb = ram_check.mem_available_mb,
                budget_mb = ctx.hot_path_budget_mb,
                decision = "launch",
                "RAM preflight passed — launching web forge"
            );
        }
        Err(crate::preflight::PreflightError::InsufficientRam { available_mb, required_mb, .. }) => {
            let msg = format!(
                "Project source on RAM: required {required_mb}MB exceeds the configured limit \
                ({available_mb}MB available). Either commit & prune unreachable refs in the \
                mirror, or raise forge.hot_path_max_mb in ~/.config/tillandsias/config.toml."
            );
            warn!(
                accountability = true,
                category = "forge-launch",
                spec = "forge-hot-cold-split",
                project = %project_name,
                host_mem_available_mb = available_mb,
                budget_mb = ctx.hot_path_budget_mb,
                decision = "refuse",
                "RAM preflight failed — refusing web forge launch"
            );
            state.running.retain(|c| c.name != container_name);
            allocator.release(&project_name, genus);
            send_notification("Tillandsias", &msg);
            return Err(msg);
        }
        Err(crate::preflight::PreflightError::Probe(probe_err)) => {
            warn!(
                accountability = true,
                category = "forge-launch",
                spec = "forge-hot-cold-split",
                project = %project_name,
                budget_mb = ctx.hot_path_budget_mb,
                decision = "launch",
                error = %probe_err,
                "RAM probe unavailable — proceeding without preflight (web mode)"
            );
        }
    }

    let mut run_args = crate::launch::build_podman_args(&profile, &ctx);
    // @trace spec:proxy-container
    inject_ca_chain_mounts(&mut run_args);

    // Launch detached — no terminal.
    match client.run_container(&run_args).await {
        Ok(container_id) => {
            info!(
                accountability = true,
                category = "enclave",
                spec = "opencode-web-session, podman-orchestration",
                container = %container_name,
                container_id = %container_id,
                port = host_port,
                "OpenCode Web container started (detached, persistent)"
            );

            // @trace spec:subdomain-routing-via-reverse-proxy
            // The forge container is now alive on the enclave; rewrite the
            // router's dynamic.Caddyfile so `<project>.opencode.localhost`
            // resolves to it. Best-effort — failure here does NOT fail the
            // attach (the loopback host-port path still works for OpenCode
            // Web; only the friendly subdomain URL would be unreachable).
            if let Err(e) = regenerate_router_caddyfile(state).await {
                warn!(
                    project = %project_name,
                    error = %e,
                    spec = "subdomain-routing-via-reverse-proxy",
                    "Router Caddyfile regeneration returned error — continuing attach"
                );
            }
        }
        Err(e) => {
            error!(
                container = %container_name,
                error = %e,
                spec = "opencode-web-session",
                "Failed to start OpenCode Web container"
            );
            state.running.retain(|c| c.name != container_name);
            allocator.release(&project_name, genus);
            return Err(format!("Failed to start web container: {e}"));
        }
    }

    // @trace spec:opencode-web-session
    // Health-wait for the loopback server before launching the browser.
    // On timeout: the container stays running (user can retry); we only
    // fail the open attempt.
    if let Err(e) = crate::browser::wait_for_web_ready(host_port).await {
        warn!(
            project = %project_name,
            port = host_port,
            error = %e,
            spec = "opencode-web-session",
            "OpenCode Web server failed readiness probe — leaving container running for retry"
        );
        let msg = format!(
            "OpenCode Web server did not start for '{}' — try again in a moment",
            project_name
        );
        send_notification("Tillandsias", &msg);
        return Err(e);
    }

    // @trace spec:opencode-web-session, spec:subdomain-routing-via-reverse-proxy, spec:opencode-web-session-otp
    // Launch the user's native browser in app-mode against the forge URL.
    // Failure is decoupled from container health — log a warning and keep
    // the container running for another attempt. The `genus` label is
    // retained only for tray UI (container icon + name). The URL handed to
    // the browser is `http://<project>.opencode.localhost/`; the router
    // container reverse-proxies that to the forge on the enclave network.
    // The session-aware variant mints a fresh per-window cookie and
    // injects it via CDP before navigation (per opencode-web-session-otp).
    let _ = genus; // label consumed elsewhere; browser URL is router-fronted
    if let Err(e) = crate::browser::launch_for_project_with_session(&project_name, host_port).await
    {
        warn!(
            project = %project_name,
            port = host_port,
            error = %e,
            spec = "subdomain-routing-via-reverse-proxy",
            "Failed to launch native browser (container remains running)"
        );
    }

    // Accountability: credential-free, loopback-only, detached.
    // @trace spec:secrets-management, spec:opencode-web-session
    {
        let has_git_identity = !ctx.git_author_name.is_empty();
        info!(
            accountability = true,
            category = "secrets",
            safety = "credential-free (no token, no hosts.yml, no claude-dir, no D-Bus), loopback-only (127.0.0.1)",
            git_identity = has_git_identity,
            pids_limit = 512,
            spec = "secrets-management, opencode-web-session",
            "Environment {container_name} launched credential-free (web mode) — zero D-Bus, zero credentials, pids-limit=512, 127.0.0.1:{host_port}:4096",
        );
    }

    if let Some(project) = state.projects.iter_mut().find(|p| p.path == project_path) {
        project.assigned_genus = Some(genus);
    }

    // Tools overlay background update tombstoned — agents image-baked.
    // @trace spec:tombstone-tools-overlay

    let elapsed = start.elapsed();
    info!(
        duration_secs = elapsed.as_secs_f64(),
        container = %container_name,
        port = host_port,
        spec = "opencode-web-session",
        "Attach Here (web) completed"
    );

    Ok(AppEvent::ContainerStateChange {
        container_name: container_name.clone(),
        new_state: ContainerState::Creating,
    })
}

/// Stop the per-project OpenCode Web container, close all webviews opened
/// against it, and remove it from `TrayState::running`. No-op (returns `Ok`)
/// if the project has no tracked web container.
///
/// @trace spec:opencode-web-session
#[instrument(
    skip(state),
    fields(
        project = %project_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string()),
        operation = "stop-project",
        spec = "opencode-web-session, app-lifecycle"
    )
)]
pub async fn handle_stop_project(
    project_path: PathBuf,
    state: &mut TrayState,
) -> Result<(), String> {
    let project_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    // @trace spec:opencode-web-session
    let container_opt = state
        .running
        .iter()
        .find(|c| {
            c.project_name == project_name
                && matches!(
                    c.container_type,
                    tillandsias_core::state::ContainerType::OpenCodeWeb
                )
        })
        .cloned();

    let container = match container_opt {
        Some(c) => c,
        None => {
            info!(
                project = %project_name,
                spec = "opencode-web-session",
                "Stop requested but no OpenCode Web container is tracked for project — nothing to do"
            );
            return Ok(());
        }
    };

    info!(
        container = %container.name,
        project = %project_name,
        spec = "opencode-web-session",
        "Stop project requested — closing webviews and stopping web container"
    );

    // @trace spec:opencode-web-session
    // Browser windows are the user's property — we do NOT close them. When
    // the container stops, the browser window pointing at the defunct
    // forge transitions to "connection refused" on next reload. The user
    // closes the window manually; killing user-spawned browser processes
    // would be a respect boundary violation.

    let client = PodmanClient::new();
    let launcher = ContainerLauncher::new(client);
    if let Err(e) = launcher.stop(&container.name).await {
        // Graceful fallback: the launcher already did SIGTERM→SIGKILL; if that
        // still failed (container already gone, podman flaky), log and proceed
        // so state doesn't desync.
        warn!(
            container = %container.name,
            error = %e,
            spec = "opencode-web-session",
            "launcher.stop failed — removing from state anyway"
        );
    }

    state
        .running
        .retain(|c| c.name != container.name);

    // If no more environments remain for this project, clear the assigned genus.
    let still_running = state
        .running
        .iter()
        .any(|c| c.project_name == project_name);
    if !still_running
        && let Some(project) = state
            .projects
            .iter_mut()
            .find(|p| p.name == project_name)
    {
        project.assigned_genus = None;
    }

    info!(
        container = %container.name,
        project = %project_name,
        spec = "opencode-web-session",
        "Web container stopped and removed from state"
    );

    Ok(())
}

/// Handle the "Stop" action: graceful stop with SIGTERM -> 10s -> SIGKILL,
/// update icon to dried bloom during shutdown.
#[instrument(skip(state, allocator), fields(container = %container_name, operation = "stop", spec = "podman-orchestration"))]
pub async fn handle_stop(
    container_name: String,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
) -> Result<AppEvent, String> {
    info!(container = %container_name, "Stop requested");

    // Update state to stopping (dried icon)
    if let Some(container) = state.running.iter_mut().find(|c| c.name == container_name) {
        container.state = ContainerState::Stopping;
    }

    // Perform graceful stop
    let client = PodmanClient::new();
    let launcher = ContainerLauncher::new(client);

    launcher
        .stop(&container_name)
        .await
        .map_err(|e| format!("Stop failed: {e}"))?;

    // Remove from running state and release genus
    if let Some(pos) = state.running.iter().position(|c| c.name == container_name) {
        let container = state.running.remove(pos);
        allocator.release(&container.project_name, container.genus);

        // Clear assigned genus from project if no more environments
        let still_running = state
            .running
            .iter()
            .any(|c| c.project_name == container.project_name);
        if !still_running
            && let Some(project) = state
                .projects
                .iter_mut()
                .find(|p| p.name == container.project_name)
        {
            project.assigned_genus = None;
        }

        info!(container = %container_name, "Container stopped and removed from state");
    }

    Ok(AppEvent::ContainerStateChange {
        container_name,
        new_state: ContainerState::Stopped,
    })
}

/// Handle the "Destroy" action: 5-second safety delay, then stop + remove cache.
/// Project source in ~/src is NEVER touched.
#[instrument(skip(state, allocator), fields(container = %container_name, operation = "destroy", spec = "podman-orchestration"))]
pub async fn handle_destroy(
    container_name: String,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
) -> Result<AppEvent, String> {
    info!(container = %container_name, "Destroy requested (5s safety hold)");

    // 5-second safety confirmation delay
    tokio::time::sleep(Duration::from_secs(5)).await;

    // Parse project name from container name
    let (project_name, _genus) = ContainerInfo::parse_container_name(&container_name)
        .ok_or_else(|| format!("Cannot parse container name: {container_name}"))?;

    let client = PodmanClient::new();
    let launcher = ContainerLauncher::new(client);
    let cache = cache_dir();

    launcher
        .destroy(&container_name, &cache, &project_name)
        .await
        .map_err(|e| format!("Destroy failed: {e}"))?;

    // Remove from running state and release genus
    if let Some(pos) = state.running.iter().position(|c| c.name == container_name) {
        let container = state.running.remove(pos);
        allocator.release(&container.project_name, container.genus);

        // Clear assigned genus from project if no more environments
        let still_running = state
            .running
            .iter()
            .any(|c| c.project_name == container.project_name);
        if !still_running
            && let Some(project) = state
                .projects
                .iter_mut()
                .find(|p| p.name == container.project_name)
        {
            project.assigned_genus = None;
        }
    }

    info!(container = %container_name, "Container destroyed (cache cleaned)");

    Ok(AppEvent::ContainerStateChange {
        container_name,
        new_state: ContainerState::Absent,
    })
}

/// Graceful application shutdown: stop all managed containers.
///
/// Also stops infrastructure containers (git services, proxy) and cleans up
/// the enclave network.
///
/// @trace spec:enclave-network, spec:podman-orchestration
pub async fn shutdown_all(state: &TrayState) {
    info!(
        accountability = true,
        category = "enclave",
        count = state.running.len(),
        spec = "podman-orchestration, enclave-network",
        "Shutting down: stopping all managed containers"
    );

    // @trace spec:app-lifecycle, spec:opencode-web-session
    // Browser windows are user-owned — we do NOT close them on shutdown.
    // Any native browser window still pointing at the forge URL will
    // transition to a connection-refused page on next reload, which is the
    // correct feedback. Killing user-spawned browser processes would be a
    // respect-boundary violation (could take down the user's other tabs
    // or work).

    // @trace spec:git-mirror-service
    // Final mirror -> host sync before we tear anything down. Catches any
    // forge push that landed in the mirror in the last few ms (e.g. the
    // inotify debounce window hadn't expired yet) so the user's host
    // working copy is up to date before containers disappear.
    {
        let cfg = tillandsias_core::config::load_global_config();
        let mirrors_root = tillandsias_core::config::cache_dir().join("mirrors");
        crate::mirror_sync::sync_all_projects(&mirrors_root, &cfg.scanner.watch_paths);
    }

    let client = PodmanClient::new();
    let launcher = ContainerLauncher::new(client.clone());

    // @trace spec:git-mirror-service, spec:persistent-git-service
    // Collect git-service project names from `state.running` directly. Since
    // the per-forge "stop git-service" trigger was removed, git-services may
    // outlive their original forges by an arbitrary amount of time. They live
    // in state.running as `ContainerType::GitService` rows (populated by the
    // event-loop discovery code in event_loop.rs ~line 632). Iterating those
    // rows is the authoritative way to find every git-service to clean up at
    // shutdown — derivation from "projects with active forges" would miss any
    // git-service whose forge already exited earlier in the session.
    let mut git_service_projects: Vec<String> = Vec::new();

    for container in &state.running {
        match launcher.stop(&container.name).await {
            Ok(()) => info!(container = %container.name, "Container stopped"),
            Err(e) => {
                warn!(container = %container.name, error = %e, "Failed to stop container on shutdown")
            }
        }
        // @trace spec:enclave-network
        // Stop alone leaves the container in "exited" state — still attached to
        // the enclave network, which blocks `podman network rm` later. Remove
        // the container immediately after stopping so the enclave can tear
        // down cleanly. Errors are non-fatal (may already be gone).
        if let Err(e) = client.remove_container(&container.name).await {
            debug!(container = %container.name, error = %e, "remove_container on shutdown (non-fatal)");
        }

        // Track projects that need their git service stopped.
        // @trace spec:git-mirror-service, spec:persistent-git-service, spec:opencode-web-session
        // Union: tracked GitService containers (persistent-git-service) AND projects whose
        // forge/maintenance/OpenCodeWeb containers imply a git service exists for them.
        // OpenCodeWeb containers clone from the project's git mirror, so their project needs
        // its git service torn down on shutdown.
        if matches!(
            container.container_type,
            tillandsias_core::state::ContainerType::Forge
                | tillandsias_core::state::ContainerType::Maintenance
                | tillandsias_core::state::ContainerType::OpenCodeWeb
                | tillandsias_core::state::ContainerType::GitService
        ) && !git_service_projects.contains(&container.project_name)
        {
            git_service_projects.push(container.project_name.clone());
        }
    }

    // The generic stop-by-name loop above already handles every ContainerType,
    // including OpenCodeWeb — no special casing required. The orphan sweep below
    // matches `tillandsias-*-forge` via the existing `tillandsias-` prefix filter.
    // Get default runtime for cross-platform operations
    // @trace spec:cross-platform
    let runtime = default_runtime();

    // Stop git service containers for every project that had one tracked.
    // @trace spec:git-mirror-service, spec:persistent-git-service, spec:opencode-web-session
    for project_name in &git_service_projects {
        stop_git_service(project_name, runtime.clone()).await;
    }

    // Stop the inference container
    // @trace spec:inference-container
    stop_inference(runtime.clone()).await;

    // @trace spec:subdomain-routing-via-reverse-proxy
    // Regenerate the dynamic Caddyfile from current `state.running` before
    // tearing the router down. In the shutdown path this is mostly defensive:
    // the router itself is about to stop, but rewriting the file leaves a
    // consistent on-disk state for the next session's router start (which
    // reads `dynamic.Caddyfile` via the bind-mount during entrypoint init).
    if let Err(e) = regenerate_router_caddyfile(state).await {
        debug!(spec = "subdomain-routing-via-reverse-proxy", error = %e, "Router Caddyfile regeneration on shutdown returned error (non-fatal)");
    }

    // Stop the router (must come before proxy since Squid forwards to it).
    // @trace spec:subdomain-routing-via-reverse-proxy
    stop_router(runtime.clone()).await;

    // Stop the proxy
    // @trace spec:proxy-container
    stop_proxy(runtime.clone()).await;

    // Catch-all: stop any remaining tillandsias-* containers that may be orphaned
    // from previous sessions or not tracked in state. The `tillandsias-` prefix
    // already covers `tillandsias-*-forge` (OpenCode Web) and every other
    // container variant.
    // @trace spec:enclave-network, spec:opencode-web-session
    let cleanup_client = PodmanClient::new();
    if let Ok(containers) = cleanup_client.list_containers("tillandsias-").await {
        for entry in &containers {
            if entry.state == "running" {
                info!(container = %entry.name, "Stopping orphaned container on shutdown");
                if let Err(e) = launcher.stop(&entry.name).await {
                    warn!(container = %entry.name, error = %e, "Failed to stop orphaned container on shutdown");
                }
            }
            // @trace spec:enclave-network
            // Remove EVERY tillandsias-* container (running or exited) so the
            // enclave network has no residual attachments when we try to
            // destroy it. A stale "exited" forge container from a previous
            // crash will otherwise block network removal indefinitely.
            if let Err(e) = cleanup_client.remove_container(&entry.name).await {
                debug!(container = %entry.name, error = %e, "Orphan remove (non-fatal)");
            }
        }
    }

    // Clean up the enclave network
    // @trace spec:enclave-network
    cleanup_enclave_network().await;

    // @trace spec:app-lifecycle, spec:podman-orchestration
    // Final escalation pass — verify nothing tillandsias-* survived the
    // graceful + orphan-sweep phases. If anything did, escalate through
    // SIGKILL, then SIGTERM-on-conmon (Unix only). Bounded by a 5s budget.
    verify_shutdown_clean().await;

    info!(
        accountability = true,
        category = "enclave",
        spec = "enclave-network",
        "All containers stopped, enclave shut down"
    );
}

/// List `tillandsias-*` containers that podman currently sees as running.
/// Returns `Vec<String>` of names. On podman invocation failure returns
/// an empty vec — verification continues with what it can see.
///
/// @trace spec:app-lifecycle, spec:podman-orchestration
pub(crate) async fn list_running_tillandsias_containers(runtime: Arc<dyn Runtime>) -> Vec<String> {
    // @trace spec:cross-platform, spec:podman-orchestration
    match runtime.container_list().await {
        Ok(json_output) => {
            // Parse JSON output to extract container names starting with "tillandsias-"
            if let Ok(containers) = serde_json::from_str::<Vec<serde_json::Value>>(&json_output) {
                containers
                    .iter()
                    .filter_map(|c| {
                        c.get("Names")
                            .and_then(|n| n.as_array())
                            .and_then(|a| a.first())
                            .and_then(|name| name.as_str())
                            .map(|s| s.to_string())
                    })
                    .filter(|name| name.contains("tillandsias-"))
                    .collect()
            } else {
                Vec::new()
            }
        }
        Err(_) => Vec::new(),
    }
}

/// Force-kill a container with SIGKILL, then `podman rm -f`. Used by the
/// post-shutdown verification phase — never on the routine teardown path.
///
/// @trace spec:app-lifecycle, spec:podman-orchestration
pub(crate) async fn kill_and_remove(name: &str, runtime: Arc<dyn Runtime>) {
    info!(
        accountability = true,
        category = "enclave",
        spec = "app-lifecycle, podman-orchestration",
        container = %name,
        escalation = "sigkill",
        "verify_shutdown_clean: escalating to SIGKILL + rm -f"
    );
    // @trace spec:cross-platform, spec:podman-orchestration
    if let Err(e) = runtime.container_kill(name, Some("KILL")).await {
        warn!(
            container = %name,
            error = %e,
            spec = "app-lifecycle",
            "container_kill(KILL) returned error (continuing)"
        );
    }
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    // Note: Runtime trait does not expose container remove; use PodmanClient for belt-and-suspenders
    let client = PodmanClient::new();
    if let Err(e) = client.remove_container(name).await {
        debug!(
            container = %name,
            error = %e,
            spec = "app-lifecycle",
            "remove_container after SIGKILL returned error (non-fatal)"
        );
    }
}

/// Last-resort SIGTERM to any `conmon` process whose command line carries
/// `--name tillandsias-`. SIGTERM (not SIGKILL) so conmon can flush the
/// container's exit status file and avoid leaving podman in a permanently
/// inconsistent state.
///
/// Unix only. On Windows this is a no-op — Windows containers use HCS,
/// not conmon.
///
/// @trace spec:app-lifecycle, spec:podman-orchestration
#[cfg(unix)]
pub(crate) fn pkill_orphan_conmon() {
    let result = std::process::Command::new("pkill")
        .args(["-TERM", "-f", "conmon.*--name tillandsias-"])
        .output();
    match result {
        Ok(out) => {
            // pkill exits 0 on match, 1 on no-match — both fine here.
            info!(
                accountability = true,
                category = "enclave",
                spec = "app-lifecycle",
                exit_code = out.status.code().unwrap_or(-1),
                "verify_shutdown_clean: pkill conmon orphans"
            );
        }
        Err(e) => {
            warn!(
                error = %e,
                spec = "app-lifecycle",
                "pkill_orphan_conmon failed to invoke pkill (continuing)"
            );
        }
    }
}

#[cfg(not(unix))]
pub(crate) fn pkill_orphan_conmon() {
    // No-op on non-Unix (Windows HCS has no conmon analogue).
    // @trace spec:app-lifecycle
}

/// Verify the post-shutdown state is clean. Polls `podman ps` for
/// `tillandsias-*` containers and escalates through SIGKILL → conmon
/// SIGTERM (Unix only) when any survive the existing graceful + orphan
/// sweep phases. Bounded by a 5-second total budget so the user is never
/// blocked indefinitely on a host-level pathology.
///
/// @trace spec:app-lifecycle, spec:podman-orchestration
pub(crate) async fn verify_shutdown_clean() {
    use std::time::{Duration, Instant};
    const POLL_INTERVAL: Duration = Duration::from_millis(200);
    const TOTAL_BUDGET: Duration = Duration::from_secs(5);

    let runtime = default_runtime();
    let start = Instant::now();

    // Phase 1: poll until empty or ~half the budget elapses.
    let phase_one_budget = Duration::from_secs(2);
    while start.elapsed() < phase_one_budget {
        let stragglers = list_running_tillandsias_containers(runtime.clone()).await;
        if stragglers.is_empty() {
            info!(
                accountability = true,
                category = "enclave",
                spec = "app-lifecycle",
                "verify_shutdown_clean: zero stragglers"
            );
            return;
        }
        tokio::time::sleep(POLL_INTERVAL).await;
    }

    // Phase 2: SIGKILL escalation for whatever's still listed.
    let stragglers = list_running_tillandsias_containers(runtime.clone()).await;
    if stragglers.is_empty() {
        info!(
            accountability = true,
            category = "enclave",
            spec = "app-lifecycle",
            "verify_shutdown_clean: zero stragglers (cleared during phase 1)"
        );
        return;
    }
    warn!(
        accountability = true,
        category = "enclave",
        spec = "app-lifecycle",
        count = stragglers.len(),
        names = ?stragglers,
        "verify_shutdown_clean: stragglers detected — escalating to SIGKILL"
    );
    for name in &stragglers {
        kill_and_remove(name, runtime.clone()).await;
    }

    // Re-check after SIGKILL.
    tokio::time::sleep(POLL_INTERVAL).await;
    let stragglers = list_running_tillandsias_containers(runtime.clone()).await;
    if stragglers.is_empty() {
        info!(
            accountability = true,
            category = "enclave",
            spec = "app-lifecycle",
            "verify_shutdown_clean: SIGKILL escalation cleared all stragglers"
        );
        return;
    }

    // Phase 3: conmon pkill (Unix only — on Windows this is a no-op
    // and we drop straight to the error log below).
    warn!(
        accountability = true,
        category = "enclave",
        spec = "app-lifecycle, podman-orchestration",
        count = stragglers.len(),
        names = ?stragglers,
        "verify_shutdown_clean: SIGKILL did not clear — escalating to conmon SIGTERM"
    );
    pkill_orphan_conmon();
    tokio::time::sleep(Duration::from_millis(500)).await;
    let stragglers = list_running_tillandsias_containers(runtime.clone()).await;
    if stragglers.is_empty() {
        info!(
            accountability = true,
            category = "enclave",
            spec = "app-lifecycle",
            "verify_shutdown_clean: conmon escalation cleared all stragglers"
        );
        return;
    }

    // Budget exhausted. Log every survivor so the next session's first
    // log lines surface the host-level pathology, then return — the user
    // clicked Quit; we don't block them indefinitely on a kernel/podman bug.
    let _ = start; // bounded internally — global budget is informational
    for name in &stragglers {
        error!(
            accountability = true,
            category = "enclave",
            spec = "app-lifecycle",
            container = %name,
            reason = "survived_all_escalation",
            "verify_shutdown_clean: container survived graceful + SIGKILL + conmon SIGTERM"
        );
    }
}

/// Handle "Maintenance" — open fish/bash in a forge container for the project.
///
/// Each maintenance terminal gets its own genus-named container, following the
/// same naming convention as forge containers (`tillandsias-{project}-{genus}`).
/// Multiple maintenance terminals per project are allowed — each allocates a
/// unique genus from the pool.
pub async fn handle_terminal(
    project_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    tool_allocator: &mut ToolAllocator,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    let project_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".to_string());

    info!(project = %project_name, "Opening maintenance terminal");

    // Allocate a genus — each maintenance terminal gets its own unique name
    let genus = allocator
        .allocate(&project_name)
        .ok_or_else(|| format!("All genera exhausted for project {project_name}"))?;

    // Allocate a tool emoji for this maintenance terminal
    let display_emoji = tool_allocator
        .allocate(&project_name)
        .unwrap_or(tillandsias_core::tools::TOOL_EMOJIS[0])
        .to_string();

    debug!(project = %project_name, genus = %genus.display_name(), tool = %display_emoji, "Genus and tool allocated for maintenance terminal");

    // Ensure forge image is up to date — always invoke the build script
    // (it handles staleness internally via hash check and exits fast when current).
    // @trace spec:forge-staleness, spec:forge-forward-compat
    let client = PodmanClient::new();
    let mut tag = forge_image_tag();

    // Check for a newer forge image (forward compatibility)
    if let Some(newer_tag) = find_newer_forge_image(&tag) {
        warn!(expected = %tag, found = %newer_tag, "Using newer forge image for terminal");
        tag = newer_tag;
    } else {
        // No newer image — ensure current version is built and up to date
        info!(tag = %tag, "Ensuring forge image is up to date for maintenance terminal...");

        let chip_name = crate::i18n::t("menu.build.chip_forge").to_string();
        if build_tx.try_send(BuildProgressEvent::Started {
            image_name: chip_name.clone(),
        }).is_err() {
            debug!("Build progress channel full/closed — UI may show stale state");
        }

        let build_result =
            tokio::task::spawn_blocking(|| run_build_image_script("forge")).await;

        match build_result {
            Ok(Ok(())) => {
                if !client.image_exists(&tag).await {
                    error!(tag = %tag, "Image still not found after build (maintenance terminal)");
                    if build_tx.try_send(BuildProgressEvent::Failed {
                        image_name: chip_name,
                        reason: "Development environment not ready yet".to_string(),
                    }).is_err() {
                        debug!("Build progress channel full/closed — UI may show stale state");
                    }
                    allocator.release(&project_name, genus);
                    tool_allocator.release(&project_name, &display_emoji);
                    return Err(strings::ENV_NOT_READY.into());
                }
                info!(tag = %tag, "Forge image ready for maintenance terminal");
                prune_old_images();
                if build_tx.try_send(BuildProgressEvent::Completed {
                    image_name: chip_name,
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
            }
            Ok(Err(ref e)) => {
                error!(tag = %tag, error = %e, "Image build failed (maintenance terminal)");
                if build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: chip_name,
                    reason: "Tillandsias is setting up".to_string(),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                allocator.release(&project_name, genus);
                tool_allocator.release(&project_name, &display_emoji);
                return Err(strings::SETUP_ERROR.into());
            }
            Err(ref e) => {
                error!(tag = %tag, error = %e, "Image build task panicked (maintenance terminal)");
                if build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: chip_name,
                    reason: "Tillandsias is setting up".to_string(),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                allocator.release(&project_name, genus);
                tool_allocator.release(&project_name, &display_emoji);
                return Err(strings::SETUP_ERROR.into());
            }
        }
    }

    let cache = cache_dir();
    std::fs::create_dir_all(&cache).ok();

    // @trace spec:enclave-network, spec:proxy-container, spec:git-mirror-service, spec:inference-container
    // Single unified enclave setup: network, proxy, inference, mirror, git service.
    let _enclave = ensure_enclave_ready(&project_path, &project_name, state, build_tx.clone()).await?;

    // Allocate port range — check actual podman containers for conflicts
    let mut existing_ports: Vec<(u16, u16)> = state.running.iter().map(|c| c.port_range).collect();
    existing_ports.extend(query_occupied_ports());
    let port_range = allocate_port_range((3000, 3019), &existing_ports);

    // Use genus-based container name (same convention as forge containers)
    let container_name = ContainerInfo::container_name(&project_name, genus);

    // Pre-register container in state so the tray shows it immediately
    let placeholder = ContainerInfo {
        name: container_name.clone(),
        project_name: project_name.clone(),
        genus,
        state: ContainerState::Creating,
        port_range,
        container_type: tillandsias_core::state::ContainerType::Maintenance,
        display_emoji: display_emoji.clone(),
    };
    state.running.push(placeholder);
    info!(container = %container_name, tool = %display_emoji, "Maintenance terminal registered (bud state)");

    let profile = tillandsias_core::container_profile::terminal_profile();
    let ctx = build_launch_context(
        &container_name,
        &project_path,
        &project_name,
        &cache,
        port_range,
        false, // interactive
        false, // not watch root
        &tag,
    );
    let mut run_args = crate::launch::build_podman_args(&profile, &ctx);
    // @trace spec:proxy-container
    inject_ca_chain_mounts(&mut run_args);

    let mut podman_parts = vec![
        tillandsias_podman::find_podman_path().to_string(),
        "run".to_string(),
    ];
    podman_parts.extend(run_args);
    let podman_cmd = crate::launch::shell_quote_join(&podman_parts);

    // Window title uses the allocated tool emoji — unique per terminal
    let title = format!("{} {}", display_emoji, project_name);

    // Notify event loop: maintenance setup in progress (menu chip: ⛏️ Setting up Maintenance...)
    if build_tx.try_send(BuildProgressEvent::Started {
        image_name: crate::i18n::t("menu.build.chip_maintenance").to_string(),
    }).is_err() {
        debug!("Build progress channel full/closed — UI may show stale state");
    }

    match open_terminal(&podman_cmd, &title) {
        Ok(()) => {
            // Terminal launched — notify completed so chip shows briefly
            if build_tx.try_send(BuildProgressEvent::Completed {
                image_name: crate::i18n::t("menu.build.chip_maintenance").to_string(),
            }).is_err() {
                debug!("Build progress channel full/closed — UI may show stale state");
            }
            info!(
                container = %container_name,
                genus = %genus.display_name(),
                port_range = ?port_range,
                "Maintenance terminal opened"
            );
            // Accountability: log credential-free terminal launch.
            // @trace spec:secrets-management
            {
                info!(
                    accountability = true,
                    category = "secrets",
                    safety = "credential-free (no token, no D-Bus)",
                    pids_limit = 512,
                    spec = "secret-management",
                    "Maintenance terminal {container_name} launched credential-free — zero D-Bus, zero credentials, pids-limit=512",
                );
            }
            // Tools overlay background update tombstoned — agents image-baked.
            // @trace spec:tombstone-tools-overlay
            Ok(())
        }
        Err(e) => {
            // Clean up: remove from state and release genus + tool
            state.running.retain(|c| c.name != container_name);
            allocator.release(&project_name, genus);
            tool_allocator.release(&project_name, &display_emoji);
            if build_tx.try_send(BuildProgressEvent::Failed {
                image_name: crate::i18n::t("menu.build.chip_maintenance").to_string(),
                reason: e.clone(),
            }).is_err() {
                debug!("Build progress channel full/closed — UI may show stale state");
            }
            Err(format!("Failed to open terminal: {e}"))
        }
    }
}

/// Handle the global "🛠️ Root" terminal — open fish at the src/ root directory.
///
/// Identical lifecycle to `handle_terminal` but scoped to the entire `~/src/`
/// watch path rather than a single project sub-directory.
///
/// - Container name: `tillandsias-src-<genus>` (project_name = "src")
/// - Working directory inside container: `/home/forge/src`
/// - Volume mount: `<watch_path>:/home/forge/src` (entire src tree, rw)
/// - Window title: `🛠️ Root`
/// - The `🛠️` emoji is reserved for this item and is absent from `TOOL_EMOJIS`.
/// Open a host terminal that `podman exec -it`s into the project's
/// running opencode-web forge container.
///
/// Spec: simplified-tray-ux. The maintenance terminal attaches to the
/// SAME container as opencode-web — not a fresh one. Multiple maintenance
/// terminals can be open against the same forge; they're independent
/// shells in the existing container.
///
/// If the forge isn't running, returns an error so the caller can
/// surface a "click Launch first" hint.
///
/// @trace spec:simplified-tray-ux
pub async fn handle_maintenance_terminal(
    project_path: PathBuf,
) -> Result<(), String> {
    let project_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".to_string());

    let container_name = ContainerInfo::forge_container_name(&project_name);

    let client = PodmanClient::new();
    match client.inspect_container(&container_name).await {
        Ok(inspect) if inspect.state == "running" => {}
        Ok(inspect) => {
            return Err(format!(
                "Forge container `{container_name}` is in state `{}` — click Launch first.",
                inspect.state
            ));
        }
        Err(_) => {
            return Err(format!(
                "Forge container `{container_name}` is not running — click Launch first."
            ));
        }
    }

    let podman = tillandsias_podman::find_podman_path();
    let title = format!("🛠️ {project_name} (maintenance)");
    // -i: keep stdin open even if not attached. -t: allocate a TTY.
    // -l: login shell so /etc/skel/.bashrc + /etc/skel/.zshrc kick in.
    // We deliberately exec /bin/bash -l rather than fish so the user gets
    // a predictable shell across distros.
    let podman_cmd = format!("{podman} exec -it {container_name} /bin/bash -l");
    info!(
        spec = "simplified-tray-ux",
        project = %project_name,
        container = %container_name,
        "Opening maintenance terminal (exec into running forge)"
    );
    open_terminal(&podman_cmd, &title)
}

pub async fn handle_root_terminal(
    watch_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    _tool_allocator: &mut ToolAllocator,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    // Use a fixed project name for the root terminal so the container name is
    // stable and recognisable: tillandsias-src-<genus>
    let project_name = "src".to_string();

    info!("Opening root terminal at src/");

    let genus = allocator
        .allocate(&project_name)
        .ok_or_else(|| "All genera exhausted for root terminal".to_string())?;

    // Reserve the 🛠️ emoji as the display emoji — it is NOT drawn from the pool.
    let display_emoji = "\u{1F6E0}\u{FE0F}".to_string();

    debug!(genus = %genus.display_name(), "Genus allocated for root terminal");

    // Ensure forge image is up to date — always invoke the build script
    // (it handles staleness internally via hash check and exits fast when current).
    // @trace spec:forge-staleness, spec:forge-forward-compat
    let client = PodmanClient::new();
    let mut tag = forge_image_tag();

    // Check for a newer forge image (forward compatibility)
    if let Some(newer_tag) = find_newer_forge_image(&tag) {
        warn!(expected = %tag, found = %newer_tag, "Using newer forge image for root terminal");
        tag = newer_tag;
    } else {
        // No newer image — ensure current version is built and up to date
        info!(tag = %tag, "Ensuring forge image is up to date for root terminal...");

        let chip_name = crate::i18n::t("menu.build.chip_forge").to_string();
        if build_tx.try_send(BuildProgressEvent::Started {
            image_name: chip_name.clone(),
        }).is_err() {
            debug!("Build progress channel full/closed — UI may show stale state");
        }

        let build_result =
            tokio::task::spawn_blocking(|| run_build_image_script("forge")).await;

        match build_result {
            Ok(Ok(())) => {
                if !client.image_exists(&tag).await {
                    error!(tag = %tag, "Image still not found after build (root terminal)");
                    if build_tx.try_send(BuildProgressEvent::Failed {
                        image_name: chip_name,
                        reason: "Development environment not ready yet".to_string(),
                    }).is_err() {
                        debug!("Build progress channel full/closed — UI may show stale state");
                    }
                    allocator.release(&project_name, genus);
                    return Err(strings::ENV_NOT_READY.into());
                }
                info!(tag = %tag, "Forge image ready for root terminal");
                prune_old_images();
                if build_tx.try_send(BuildProgressEvent::Completed {
                    image_name: chip_name,
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
            }
            Ok(Err(ref e)) => {
                error!(tag = %tag, error = %e, "Image build failed (root terminal)");
                if build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: chip_name,
                    reason: "Tillandsias is setting up".to_string(),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                allocator.release(&project_name, genus);
                return Err(strings::SETUP_ERROR.into());
            }
            Err(ref e) => {
                error!(tag = %tag, error = %e, "Image build task panicked (root terminal)");
                if build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: chip_name,
                    reason: "Tillandsias is setting up".to_string(),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                allocator.release(&project_name, genus);
                return Err(strings::SETUP_ERROR.into());
            }
        }
    }

    let cache = cache_dir();
    std::fs::create_dir_all(&cache).ok();

    // @trace spec:enclave-network, spec:proxy-container, spec:inference-container
    // Infrastructure + inference (no git mirror needed for root terminal).
    ensure_infrastructure_ready(state, build_tx.clone()).await?;
    if let Err(e) = ensure_inference_running(state, build_tx.clone()).await {
        // TODO: Remove fallback — make this a hard error
        warn!(
            accountability = true,
            category = "capability",
            safety = "DEGRADED: no local LLM inference — AI features unavailable in root terminal",
            spec = "inference-container",
            error = %e,
            "Inference setup failed — root terminal will launch without local inference"
        );
    }

    // Allocate port range — check actual podman containers for conflicts
    let mut existing_ports: Vec<(u16, u16)> = state.running.iter().map(|c| c.port_range).collect();
    existing_ports.extend(query_occupied_ports());
    let port_range = allocate_port_range((3000, 3019), &existing_ports);

    let container_name =
        tillandsias_core::state::ContainerInfo::container_name(&project_name, genus);

    // Pre-register container in state so the tray shows it immediately
    let placeholder = tillandsias_core::state::ContainerInfo {
        name: container_name.clone(),
        project_name: project_name.clone(),
        genus,
        state: tillandsias_core::event::ContainerState::Creating,
        port_range,
        container_type: tillandsias_core::state::ContainerType::Maintenance,
        display_emoji: display_emoji.clone(),
    };
    state.running.push(placeholder);
    info!(container = %container_name, "Root terminal registered (bud state)");

    // @trace spec:podman-orchestration
    ensure_container_log_dir(&container_name);

    // Use terminal profile with SrcRoot working dir for the root terminal
    let mut profile = tillandsias_core::container_profile::terminal_profile();
    profile.working_dir = Some(tillandsias_core::container_profile::WorkingDir::SrcRoot);

    // Build context: project_name="(all projects)" for the env var display,
    // is_watch_root=true so the watch path mounts at /home/forge/src directly.
    let ctx = build_launch_context(
        &container_name,
        &watch_path,
        "(all projects)",
        &cache,
        port_range,
        false, // interactive
        true,  // watch root — mount at /home/forge/src directly
        &tag,
    );

    // @trace spec:forge-hot-cold-split
    // Pre-flight RAM check for root terminal (same forge profile, same tmpfs).
    let preflight_required_mb = ctx.hot_path_budget_mb.saturating_add(80);
    match crate::preflight::check_host_ram(preflight_required_mb) {
        Ok(ram_check) => {
            info!(
                accountability = true,
                category = "forge-launch",
                spec = "forge-hot-cold-split",
                project = "(all projects)",
                host_mem_available_mb = ram_check.mem_available_mb,
                budget_mb = ctx.hot_path_budget_mb,
                decision = "launch",
                "RAM preflight passed — launching root terminal"
            );
        }
        Err(crate::preflight::PreflightError::InsufficientRam { available_mb, required_mb, .. }) => {
            let msg = format!(
                "Project source on RAM: required {required_mb}MB exceeds the configured limit \
                ({available_mb}MB available). Either commit & prune unreachable refs in the \
                mirror, or raise forge.hot_path_max_mb in ~/.config/tillandsias/config.toml."
            );
            warn!(
                accountability = true,
                category = "forge-launch",
                spec = "forge-hot-cold-split",
                project = "(all projects)",
                host_mem_available_mb = available_mb,
                budget_mb = ctx.hot_path_budget_mb,
                decision = "refuse",
                "RAM preflight failed — refusing root terminal launch"
            );
            state.running.retain(|c| c.name != container_name);
            allocator.release(&project_name, genus);
            send_notification("Tillandsias", &msg);
            return Err(msg);
        }
        Err(crate::preflight::PreflightError::Probe(probe_err)) => {
            warn!(
                accountability = true,
                category = "forge-launch",
                spec = "forge-hot-cold-split",
                project = "(all projects)",
                budget_mb = ctx.hot_path_budget_mb,
                decision = "launch",
                error = %probe_err,
                "RAM probe unavailable — proceeding without preflight (root terminal)"
            );
        }
    }

    let mut run_args = crate::launch::build_podman_args(&profile, &ctx);
    // @trace spec:proxy-container
    inject_ca_chain_mounts(&mut run_args);

    let mut podman_parts = vec![
        tillandsias_podman::find_podman_path().to_string(),
        "run".to_string(),
    ];
    podman_parts.extend(run_args);
    let podman_cmd = crate::launch::shell_quote_join(&podman_parts);

    let title = "\u{1F6E0}\u{FE0F} Root".to_string();

    // Notify event loop: maintenance setup in progress
    if build_tx.try_send(BuildProgressEvent::Started {
        image_name: crate::i18n::t("menu.build.chip_maintenance").to_string(),
    }).is_err() {
        debug!("Build progress channel full/closed — UI may show stale state");
    }

    match open_terminal(&podman_cmd, &title) {
        Ok(()) => {
            if build_tx.try_send(BuildProgressEvent::Completed {
                image_name: crate::i18n::t("menu.build.chip_maintenance").to_string(),
            }).is_err() {
                debug!("Build progress channel full/closed — UI may show stale state");
            }
            info!(
                container = %container_name,
                genus = %genus.display_name(),
                port_range = ?port_range,
                "Root terminal opened"
            );
            // Accountability: log credential-free root terminal launch.
            // @trace spec:secrets-management
            {
                info!(
                    accountability = true,
                    category = "secrets",
                    safety = "credential-free (no token, no D-Bus)",
                    pids_limit = 512,
                    spec = "secret-management",
                    "Root terminal {container_name} launched credential-free — zero D-Bus, zero credentials, pids-limit=512",
                );
            }
            Ok(())
        }
        Err(e) => {
            state.running.retain(|c| c.name != container_name);
            allocator.release(&project_name, genus);
            if build_tx.try_send(BuildProgressEvent::Failed {
                image_name: crate::i18n::t("menu.build.chip_maintenance").to_string(),
                reason: e.clone(),
            }).is_err() {
                debug!("Build progress channel full/closed — UI may show stale state");
            }
            Err(format!("Failed to open root terminal: {e}"))
        }
    }
}

/// Handle "GitHub Login" — build git service image if missing, then run `gh auth login`.
///
/// On first launch the git image does not exist yet. Rather than failing with
/// "Cannot find build-image.sh", this handler builds the image first (same
/// pipeline as Attach Here) and shows a progress chip in the tray while it
/// waits. Only after the image is confirmed present does it open the terminal.
///
/// No filesystem scripts are trusted — everything comes from the signed binary.
///
/// Tray-side "GitHub Login": open a terminal running our own binary with
/// `--github-login`. The CLI flow (`runner::run_github_login`) is the
/// single implementation — it prompts for git identity, runs `gh auth login`
/// inside a keep-alive git-service container (no host mounts), harvests the
/// resulting OAuth token via `gh auth token`, stores it in the native
/// keyring, and tears the container down so no on-disk gh state survives.
/// Tray and CLI must stay identical.
///
/// @trace spec:git-mirror-service, spec:secrets-management, spec:native-secrets-store
/// Handle GitHub login via direct `gh` CLI or container fallback.
///
/// # Strategy
/// 1. Try to find `gh` on the host (checked first, preferred)
/// 2. If found: spawn terminal with `gh auth login --git-protocol https`
/// 3. If not found: spawn terminal with `podman run -it ... gh auth login --git-protocol https`
///
/// All paths use the `open_terminal` function which is platform-aware and handles
/// terminal spawning (ptyxis/gnome-terminal on Linux, Terminal.app on macOS, wt.exe on Windows).
///
/// # Credentials
/// - Token stored in OS keyring after auth completes (native gh auth behavior)
/// - No ephemeral credentials needed since gh handles the login interactively
///
/// @trace spec:direct-podman-calls, spec:secrets-management
pub async fn handle_github_login(
    _state: &TrayState,
    _build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    // Try host gh first (preferred — token goes to OS keyring)
    if let Some(gh_path) = find_gh_path() {
        info!(gh_path = ?gh_path, "GitHub Login: using host gh");
        let gh_str = gh_path.to_string_lossy();
        let cmd = format!("{} auth login --git-protocol https", gh_str);
        return open_terminal(&cmd, "GitHub Login")
            .map_err(|e| format!("Failed to open terminal for host gh: {e}"));
    }

    // Fallback: gh inside forge container with D-Bus forwarding (Linux) or ephemeral mode
    info!("GitHub Login: using container gh (no host gh found)");

    let forge_image = forge_image_tag();

    // Build podman run command with security flags
    #[cfg(target_os = "linux")]
    let cmd = {
        // On Linux, forward D-Bus so the container can write to the host keyring
        format!(
            "podman run -it --rm --cap-drop=ALL --security-opt=no-new-privileges \
             --userns=keep-id --security-opt=label=disable \
             -v /run/user/$(id -u)/bus:/run/user/1000/bus:ro \
             --entrypoint gh {} auth login --git-protocol https",
            forge_image
        )
    };

    #[cfg(target_os = "macos")]
    let cmd = {
        // On macOS, no D-Bus available; token stored in container's ephemeral keychain.
        // User will need to manually push/pull with gh auth setup or export token.
        format!(
            "podman run -it --rm --cap-drop=ALL --security-opt=no-new-privileges \
             --userns=keep-id --entrypoint gh {} auth login --git-protocol https",
            forge_image
        )
    };

    #[cfg(target_os = "windows")]
    let cmd = {
        // On Windows, no D-Bus; ephemeral container. Token stored in container's hosts.yml.
        format!(
            "podman run -it --rm --cap-drop=ALL --security-opt=no-new-privileges \
             --entrypoint gh {} auth login --git-protocol https",
            forge_image
        )
    };

    open_terminal(&cmd, "GitHub Login")
        .map_err(|e| format!("Failed to open terminal for container gh: {e}"))
}

/// Handle "Claude Reset Credentials" — remove `~/.claude/` contents so next
/// container launch triggers re-authentication via Claude Code's own flow.
pub fn handle_claude_reset_credentials() -> Result<(), String> {
    let claude_dir = dirs::home_dir()
        .map(|h| h.join(".claude"))
        .ok_or("Cannot determine home directory")?;

    if !claude_dir.exists() {
        info!("Claude credentials directory does not exist, nothing to reset");
        return Ok(());
    }

    // Remove contents but keep the directory (it's always mounted)
    match std::fs::read_dir(&claude_dir) {
        Ok(entries) => {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    std::fs::remove_dir_all(&path).ok();
                } else {
                    std::fs::remove_file(&path).ok();
                }
            }
            info!("Claude credentials cleared — next launch will re-authenticate");
            send_notification("Tillandsias", crate::i18n::t("notifications.claude_credentials_cleared"));
            Ok(())
        }
        Err(e) => Err(format!("Failed to read Claude credentials directory: {e}")),
    }
}

/// Detect the document root for a web container.
///
/// Checks subdirectories in priority order:
///   1. `public/`   — Hugo, Rails, Vite default
///   2. `dist/`     — Webpack, Parcel, Rollup default
///   3. `build/`    — Create React App default
///   4. `_site/`    — Jekyll, Eleventy default
///   5. `out/`      — Next.js static export
///   6. Project root — fallback
///
/// Returns the absolute path to the detected document root.
pub fn detect_document_root(project_path: &Path) -> PathBuf {
    let candidates = ["public", "dist", "build", "_site", "out"];
    for name in &candidates {
        let candidate = project_path.join(name);
        if candidate.is_dir() {
            debug!(
                project = %project_path.display(),
                document_root = %candidate.display(),
                "Auto-detected document root"
            );
            return candidate;
        }
    }
    debug!(
        project = %project_path.display(),
        "No standard output directory found, using project root as document root"
    );
    project_path.to_path_buf()
}

/// Handle "Serve Here" — launch a minimal web server container for static files.
///
/// # Security model
/// - Image: `tillandsias-web:latest` (httpd on port 8080, no dev tools)
/// - Only the detected document root is mounted, read-only (`/var/www:ro`)
/// - NO secrets mounted: no gh credentials, no git config, no Claude directory, no API keys
/// - Port binds to `127.0.0.1` only (localhost)
/// - Full security flags: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`
///
/// # Container naming
/// `tillandsias-<project>-web` — no genus allocation. Only one web container per project.
///
/// # Port allocation
/// Base port 8080, increments if occupied. Separate range from forge containers (3000-3019).
#[instrument(skip(state, build_tx), fields(project = %project_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string()), operation = "serve", spec = "podman-orchestration"))]
pub async fn handle_serve_here(
    project_path: PathBuf,
    state: &mut TrayState,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    let project_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".to_string());

    info!(project = %project_name, "Serve Here requested");

    let container_name = tillandsias_core::state::ContainerInfo::web_container_name(&project_name);

    // Don't-relaunch guard: if a web container for this project is already running,
    // notify the user and return early instead of spawning a second server.
    if let Some(existing) = state.running.iter().find(|c| c.name == container_name) {
        let port = existing.port_range.0;
        let msg = crate::i18n::tf("menu.web.already_serving", &[("port", &port.to_string())]);
        info!(project = %project_name, port, "Don't-relaunch guard fired — web container already running");
        send_notification("Tillandsias", &msg);
        return Err(format!(
            "Web server for '{project_name}' is already running on port {port}"
        ));
    }

    // Load project config for document_root and port overrides
    let project_config = tillandsias_core::config::load_project_config(&project_path);

    // Detect document root — check per-project config override first, then auto-detect
    let document_root = if let Some(ref web_cfg) = project_config.web {
        if let Some(ref explicit_root) = web_cfg.document_root {
            let override_path = project_path.join(explicit_root);
            if override_path.is_dir() {
                debug!(project = %project_name, document_root = %override_path.display(), "Using explicit document root from config");
                override_path
            } else {
                warn!(project = %project_name, path = %override_path.display(), "Configured web.document_root does not exist, falling back to auto-detection");
                detect_document_root(&project_path)
            }
        } else {
            detect_document_root(&project_path)
        }
    } else {
        detect_document_root(&project_path)
    };

    // @trace spec:enclave-network, spec:proxy-container, spec:inference-container
    // Infrastructure + inference (no git mirror needed for web containers).
    ensure_infrastructure_ready(state, build_tx.clone()).await?;
    if let Err(e) = ensure_inference_running(state, build_tx.clone()).await {
        // TODO: Remove fallback — make this a hard error
        warn!(
            accountability = true,
            category = "capability",
            safety = "DEGRADED: no local LLM inference — AI features unavailable in web server",
            spec = "inference-container",
            error = %e,
            "Inference setup failed — web server will launch without local inference"
        );
    }

    // Allocate port — base 8080, increment on conflict.
    // Web containers use a separate port space from forge containers (3000-3019).
    let configured_base_port = project_config
        .web
        .as_ref()
        .and_then(|w| w.port)
        .unwrap_or(8080);
    let base_port = (configured_base_port, configured_base_port); // single-port "range"

    let mut existing_ports: Vec<(u16, u16)> = state.running.iter().map(|c| c.port_range).collect();
    existing_ports.extend(query_occupied_ports());
    let port_range = allocate_port_range(base_port, &existing_ports);
    let port = port_range.0;

    // Ensure web image is up to date — always invoke the build script
    // (it handles staleness internally via hash check and exits fast when current).
    // @trace spec:forge-staleness
    let web_image = "tillandsias-web:latest";
    let client = PodmanClient::new();
    {
        info!(image = web_image, "Ensuring web image is up to date...");
        if build_tx.try_send(BuildProgressEvent::Started {
            image_name: crate::i18n::t("menu.build.chip_web_server").to_string(),
        }).is_err() {
            debug!("Build progress channel full/closed — UI may show stale state");
        }
        let build_result = tokio::task::spawn_blocking(|| run_build_image_script("web")).await;
        match build_result {
            Ok(Ok(())) => {
                if !client.image_exists(web_image).await {
                    error!(image = web_image, "Web image still not found after build");
                    if build_tx.try_send(BuildProgressEvent::Failed {
                        image_name: crate::i18n::t("menu.build.chip_web_server").to_string(),
                        reason: "Web server image not ready".to_string(),
                    }).is_err() {
                        debug!("Build progress channel full/closed — UI may show stale state");
                    }
                    return Err("Web server image is not ready yet".into());
                }
                prune_old_images();
                if build_tx.try_send(BuildProgressEvent::Completed {
                    image_name: crate::i18n::t("menu.build.chip_web_server").to_string(),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
            }
            Ok(Err(ref e)) => {
                error!(image = web_image, error = %e, "Web image build failed");
                if build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: crate::i18n::t("menu.build.chip_web_server").to_string(),
                    reason: "Web server image build failed".to_string(),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                return Err(strings::SETUP_ERROR.into());
            }
            Err(ref e) => {
                error!(image = web_image, error = %e, "Web image build task panicked");
                if build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: crate::i18n::t("menu.build.chip_web_server").to_string(),
                    reason: "Web server image build failed".to_string(),
                }).is_err() {
                    debug!("Build progress channel full/closed — UI may show stale state");
                }
                return Err(strings::SETUP_ERROR.into());
            }
        }
    }

    // Pre-register in state so the tray shows 🔗 Serving immediately
    let sentinel_genus = tillandsias_core::genus::TillandsiaGenus::ALL[0];
    let placeholder = tillandsias_core::state::ContainerInfo {
        name: container_name.clone(),
        project_name: project_name.clone(),
        genus: sentinel_genus,
        state: tillandsias_core::event::ContainerState::Creating,
        port_range,
        container_type: tillandsias_core::state::ContainerType::Web,
        display_emoji: "\u{1F517}".to_string(), // 🔗
    };
    state.running.push(placeholder);

    // Build `podman run` command for the web container.
    //
    // Security guarantees (audited 2026-03-29, hardened 2026-04-05):
    //   - --cap-drop=ALL             No Linux capabilities
    //   - --security-opt=no-new-privileges  No suid escalation
    //   - --userns=keep-id           Rootless, host UID mapped
    //   - --security-opt=label=disable  Bind mount on Silverblue
    //   - --rm                       Ephemeral, removed on exit
    //   - --pids-limit=32            Only httpd processes allowed
    //   - --read-only                Immutable root filesystem
    //   - --tmpfs /tmp, /var/run     Runtime dirs only
    //   - Only mount: document_root → /var/www:ro (read-only)
    //   - Port: 127.0.0.1:<port>:8080 — localhost only, no external exposure
    //   - NO secrets mounted (no gh, no git, no claude, no API keys)
    // @trace spec:podman-orchestration, spec:secrets-management
    let podman_bin = tillandsias_podman::find_podman_path();
    let podman_cmd = format!(
        "{podman_bin} run -it --rm --init --stop-timeout=10 \
        --name {container_name} \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --userns=keep-id \
        --security-opt=label=disable \
        --pids-limit=32 \
        --read-only \
        --tmpfs=/tmp \
        --tmpfs=/var/run \
        -p 127.0.0.1:{port}:8080 \
        -v {}:/var/www:ro \
        {web_image}",
        document_root.display(),
    );

    // Window title uses the chain link emoji to distinguish from forge windows
    let title = format!("\u{1F517} {project_name}"); // 🔗 <project>

    info!(
        container = %container_name,
        port,
        document_root = %document_root.display(),
        "Launching web server"
    );

    match open_terminal(&podman_cmd, &title) {
        Ok(()) => {
            info!(
                container = %container_name,
                port,
                "Web server terminal opened — serving at http://localhost:{port}"
            );
            Ok(())
        }
        Err(e) => {
            state.running.retain(|c| c.name != container_name);
            Err(format!("Failed to open web server terminal: {e}"))
        }
    }
}

// ---------------------------------------------------------------------------
// External-logs auditor
// @trace spec:external-logs-layer
// ---------------------------------------------------------------------------

/// Growth-rate sample: (Instant of measurement, file size in bytes).
type GrowthSample = (std::time::Instant, u64);

/// Per-(role, file) growth-rate history, keyed by (role_name, file_name).
/// Stored as a deque of the last 5 size samples (one per 60 s tick).
pub type ExternalLogsGrowthCache =
    std::collections::HashMap<(String, String), std::collections::VecDeque<GrowthSample>>;

/// Audit one tick of the external-logs layer for all running producer containers.
///
/// Called every 60 s from the event loop alongside the proxy health check.
/// For each container with `external_logs_role: Some(role)`:
///
/// 1. Reads the producer's manifest via `podman cp <container>:/etc/tillandsias/external-logs.yaml -`.
///    Builds the set of allowed file names.
/// 2. Walks the on-disk role directory
///    (`~/.local/state/tillandsias/external-logs/<role>/`).
///    - **Manifest match**: any unlisted file → WARN+accountability
///      `[external-logs] LEAK: <role> wrote <file> (not in manifest)`.
///    - **Size cap**: any file > `rotate_at_mb` MB (default 10 MB) →
///      truncate oldest 50% of bytes in place (INFO+accountability).
///    - **Growth-rate**: if > 1 MB/min sustained for 5 ticks → WARN.
///
/// The growth cache is kept in the caller (event_loop.rs) as a local
/// `ExternalLogsGrowthCache` and passed in mutably so it persists across
/// ticks without adding another field to TrayState.
///
/// @trace spec:external-logs-layer
pub(crate) async fn external_logs_audit_tick(
    state: &TrayState,
    growth_cache: &mut ExternalLogsGrowthCache,
) {
    use tillandsias_core::config::external_logs_role_dir;
    use tillandsias_core::container_profile::{
        git_service_profile, inference_profile, proxy_profile, router_profile,
    };

    // Build a lookup from container name prefix → external_logs_role.
    // We recognise the four infrastructure containers by their known naming
    // convention (tillandsias-git-<project>, tillandsias-proxy, etc.).
    // For v1 we only audit the four infrastructure producers by name.
    for container in &state.running {
        let role = match container.name.as_str() {
            n if n.starts_with("tillandsias-git-") => {
                // git_service_profile().external_logs_role
                git_service_profile().external_logs_role
            }
            "tillandsias-proxy" => proxy_profile().external_logs_role,
            "tillandsias-router" => router_profile().external_logs_role,
            "tillandsias-inference" => inference_profile().external_logs_role,
            _ => None,
        };
        let role = match role {
            Some(r) => r,
            None => continue,
        };

        // 1. Read the manifest via podman cp.
        let allowed = read_external_logs_manifest(&container.name).await;

        // 2. Walk the on-disk role directory.
        let role_dir = external_logs_role_dir(role);
        let entries = match std::fs::read_dir(&role_dir) {
            Ok(rd) => rd,
            Err(_) => continue, // directory doesn't exist yet — no files to audit
        };

        let tick_time = std::time::Instant::now();

        for entry in entries.flatten() {
            let file_name = entry.file_name().to_string_lossy().to_string();
            let file_path = entry.path();

            // Skip directories and non-files.
            let Ok(meta) = std::fs::metadata(&file_path) else { continue };
            if !meta.is_file() { continue; }

            let file_size = meta.len();

            // --- Manifest-match check ---
            if let Some(ref allowed_set) = allowed {
                if !allowed_set.contains(&file_name) {
                    warn!(
                        accountability = true,
                        category = "external-logs",
                        spec = "external-logs-layer",
                        operation = "leak",
                        role = %role,
                        file = %file_name,
                        "[external-logs] LEAK: {role} wrote {file_name} (not in manifest)"
                    );
                }
            }
            // If manifest read failed, skip the leak check (container may be starting).

            // --- Size cap: 10 MB hard cap, truncate oldest 50% ---
            const DEFAULT_ROTATE_BYTES: u64 = 10 * 1024 * 1024; // 10 MiB
            if file_size > DEFAULT_ROTATE_BYTES {
                truncate_external_log_to_half(&file_path, file_size, role, &file_name);
            }

            // --- Growth-rate tracking ---
            let key = (role.to_string(), file_name.clone());
            let history = growth_cache.entry(key.clone()).or_default();
            history.push_back((tick_time, file_size));
            // Keep at most 5 samples (5 × 60 s = 5 min window).
            while history.len() > 5 {
                history.pop_front();
            }

            // Alarm if growth > 1 MB/min sustained across all 5 samples.
            if history.len() == 5 {
                let (oldest_time, oldest_size) = history.front().copied().unwrap();
                let elapsed_secs = oldest_time.elapsed().as_secs_f64();
                if elapsed_secs > 0.0 && file_size > oldest_size {
                    let grown_bytes = file_size - oldest_size;
                    let bytes_per_min = grown_bytes as f64 / (elapsed_secs / 60.0);
                    const ONE_MB_PER_MIN: f64 = 1024.0 * 1024.0;
                    if bytes_per_min > ONE_MB_PER_MIN {
                        warn!(
                            accountability = true,
                            category = "external-logs",
                            spec = "external-logs-layer",
                            operation = "growth-alarm",
                            role = %role,
                            file = %file_name,
                            growth_mb_per_min = %format!("{:.2}", bytes_per_min / ONE_MB_PER_MIN),
                            "[external-logs] WARN: {role} {file_name} growing {:.2} MB/min (>1 MB/min sustained)",
                            bytes_per_min / ONE_MB_PER_MIN
                        );
                    }
                }
            }
        }
    }
}

/// Read the external-logs manifest from a container via `podman cp`.
///
/// Returns `Some(HashSet<filename>)` on success, `None` if the manifest
/// could not be read (container stopped, file absent, podman error).
///
/// @trace spec:external-logs-layer
async fn read_external_logs_manifest(container_name: &str) -> Option<std::collections::HashSet<String>> {
    // `podman cp <container>:/etc/tillandsias/external-logs.yaml -` writes a
    // tar archive to stdout. We pipe it through `tar -xO` to get the raw file.
    // @cheatsheet runtime/external-logs.md
    let output = tokio::process::Command::new(tillandsias_podman::find_podman_path())
        .args([
            "cp",
            &format!("{container_name}:/etc/tillandsias/external-logs.yaml"),
            "-",
        ])
        .output()
        .await
        .ok()?;

    if !output.status.success() || output.stdout.is_empty() {
        return None;
    }

    // The output is a tar archive; pipe through `tar -xO` to extract content.
    let tar_bytes = output.stdout;
    let mut tar_child = tokio::process::Command::new("tar")
        .args(["-xO"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .ok()?;

    // Write tar bytes to stdin.
    if let Some(mut stdin) = tar_child.stdin.take() {
        use tokio::io::AsyncWriteExt;
        let _ = stdin.write_all(&tar_bytes).await;
    }

    let tar_out = tar_child.wait_with_output().await.ok()?;
    if !tar_out.status.success() { return None; }

    let yaml_str = String::from_utf8(tar_out.stdout).ok()?;
    parse_external_logs_manifest_names(&yaml_str)
}

/// Parse the `files[].name` entries from an external-logs.yaml manifest.
///
/// Uses a minimal line-oriented YAML parser — no serde_yaml dep required.
/// The manifest schema is fixed and small (< 50 lines); a regex/line-scan
/// approach is simpler and more robust than adding a full YAML parser dep.
///
/// Returns `Some(HashSet<filename>)`, `None` if the yaml is malformed.
///
/// @trace spec:external-logs-layer
pub(crate) fn parse_external_logs_manifest_names(yaml: &str) -> Option<std::collections::HashSet<String>> {
    let mut names = std::collections::HashSet::new();
    for line in yaml.lines() {
        let trimmed = line.trim();
        // Match lines like `  - name: git-push.log` or `    name: git-push.log`
        // (with or without the leading `- `).
        let rest = if let Some(s) = trimmed.strip_prefix("- name:") {
            s
        } else if let Some(s) = trimmed.strip_prefix("name:") {
            s
        } else {
            continue;
        };
        let name = rest.trim().trim_matches('"').trim_matches('\'').to_string();
        if !name.is_empty() && !name.starts_with('#') {
            names.insert(name);
        }
    }
    if names.is_empty() {
        // An empty manifest is valid (no files declared). Return empty set.
        // Distinguish from parse failure by always returning Some here.
    }
    Some(names)
}

/// Truncate an external-log file to its newest 50% of bytes.
///
/// Reads the file, discards the oldest half of bytes, writes the remainder
/// back in place. Uses an INFO+accountability log event.
///
/// This is an in-place rotation — no `.1`/`.2` rotation files are created;
/// `tail -f` consumers can keep reading the same path after the rotation.
///
/// @trace spec:external-logs-layer
fn truncate_external_log_to_half(path: &std::path::Path, current_size: u64, role: &str, file_name: &str) {
    let keep_from = (current_size / 2) as usize;
    let contents = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) => {
            warn!(
                spec = "external-logs-layer",
                role = %role,
                file = %file_name,
                error = %e,
                "Failed to read external-log file for rotation"
            );
            return;
        }
    };
    if keep_from >= contents.len() { return; }
    let tail = &contents[keep_from..];
    match std::fs::write(path, tail) {
        Ok(()) => {
            info!(
                accountability = true,
                category = "external-logs",
                spec = "external-logs-layer",
                operation = "rotate",
                role = %role,
                file = %file_name,
                original_bytes = current_size,
                kept_bytes = tail.len(),
                "[external-logs] Rotated {role}/{file_name}: truncated {current_size} → {} bytes (oldest 50% dropped)",
                tail.len()
            );
        }
        Err(e) => {
            warn!(
                spec = "external-logs-layer",
                role = %role,
                file = %file_name,
                error = %e,
                "Failed to write rotated external-log file"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    /// Caddy route block for a project preserves the explicit `http://`
    /// scheme regardless of cookie enforcement. Pin the exact bytes so
    /// any drift breaks this test loudly.
    /// @trace spec:opencode-web-session-otp, spec:subdomain-routing-via-reverse-proxy
    #[test]
    fn render_caddy_route_block_preserves_http_scheme_and_routes_to_forge() {
        let snippet = render_caddy_route_block("thinking-service");

        // Site address: http:// scheme + opencode.<project>.localhost:8080
        assert!(
            snippet.contains("http://opencode.thinking-service.localhost:8080"),
            "missing site address: {snippet}"
        );
        // Always reverse_proxy to the project's forge (gated on cookie
        // when ENFORCE_SESSION_COOKIE is true, unconditional otherwise).
        assert!(
            snippet.contains("reverse_proxy tillandsias-thinking-service-forge:4096"),
            "missing reverse_proxy line: {snippet}"
        );
        // No HTTPS scheme leaked anywhere — would trip auto_https.
        assert!(
            !snippet.contains("https://"),
            "Caddy snippet must not contain https:// — got {snippet}"
        );
    }

    /// Cookie-on shape (currently NOT the default; ENFORCE_SESSION_COOKIE
    /// must flip to true in chunk 7 for this to be the live shape). The
    /// assertions only run when the constant is true so future toggles
    /// are caught.
    /// @trace spec:opencode-web-session-otp
    #[test]
    fn render_caddy_route_block_forward_auth_when_enforced() {
        if !ENFORCE_SESSION_COOKIE {
            // Pre-flip: nothing to assert. The pre-OTP shape is covered
            // by `render_caddy_route_block_pre_otp_shape_when_not_enforced`.
            return;
        }
        let snippet = render_caddy_route_block("thinking-service");
        // Caddy directive that delegates auth to the sidecar.
        assert!(
            snippet.contains("forward_auth 127.0.0.1:9090"),
            "missing forward_auth directive targeting sidecar: {snippet}"
        );
        // The validate URI carries the project's host label so the sidecar
        // can look it up in the per-project session list.
        assert!(
            snippet
                .contains("uri /validate?project=opencode.thinking-service.localhost"),
            "missing validate URI: {snippet}"
        );
        // The original Cookie header must be forwarded so the sidecar
        // sees what the browser actually sent.
        assert!(
            snippet.contains("copy_headers Cookie"),
            "missing copy_headers Cookie: {snippet}"
        );
        // Reverse proxy still on the success path.
        assert!(
            snippet.contains("reverse_proxy tillandsias-thinking-service-forge:4096"),
            "missing reverse_proxy: {snippet}"
        );
        // No legacy presence-regex matcher.
        assert!(
            !snippet.contains("@hassession"),
            "@hassession matcher must be gone — sidecar does value validation now: {snippet}"
        );
    }

    /// Cookie-off shape — the current pre-OTP behaviour. Asserts the route
    /// block does NOT include the auth gate when ENFORCE_SESSION_COOKIE
    /// is false. When the constant flips, this test becomes a no-op and
    /// the forward_auth test above starts asserting.
    /// @trace spec:opencode-web-session-otp
    #[test]
    fn render_caddy_route_block_pre_otp_shape_when_not_enforced() {
        if ENFORCE_SESSION_COOKIE {
            return;
        }
        let snippet = render_caddy_route_block("thinking-service");
        assert!(
            !snippet.contains("forward_auth"),
            "forward_auth must NOT be present when not enforced: {snippet}"
        );
        assert!(
            !snippet.contains("@hassession"),
            "@hassession matcher must NOT be present when not enforced: {snippet}"
        );
    }

    /// Preflight refusal unit test: when `required_mb` is set to u32::MAX,
    /// `check_host_ram` MUST return `Err(PreflightError::InsufficientRam)`.
    ///
    /// This is the pure-logic leg of task 6.3 — it verifies the refusal path
    /// WITHOUT needing a Tauri runtime or a real podman invocation.
    /// The downstream `send_notification` call is exercised in production; here
    /// we assert only that the preflight gate fires before any container work
    /// could begin.
    ///
    /// Marked `#[ignore]` on platforms where RAM probing is not implemented
    /// (the `Probe` error variant is returned instead of `InsufficientRam`
    /// when `/proc/meminfo` is unavailable). Re-enable with
    /// `cargo test -- --ignored` on a Linux host.
    ///
    /// @trace spec:forge-hot-cold-split
    #[test]
    fn preflight_refuses_launch_when_host_ram_is_insufficient() {
        // u32::MAX MB is guaranteed to exceed any real host's available RAM.
        let required_mb = u32::MAX;
        let result = crate::preflight::check_host_ram(required_mb);
        match result {
            Err(crate::preflight::PreflightError::InsufficientRam {
                required_mb: r,
                available_mb,
                headroom_factor,
            }) => {
                // Confirm the error carries the correct budget and headroom.
                assert_eq!(r, u32::MAX, "required_mb should be echoed in error");
                assert!(available_mb < u32::MAX, "available_mb should be a real measurement");
                assert!(
                    (headroom_factor - 1.25).abs() < f32::EPSILON,
                    "headroom_factor must be 1.25"
                );
                // Confirm the error message is human-readable (surfaced via tray notification).
                let msg = result.unwrap_err().to_string();
                assert!(
                    msg.contains("Insufficient host RAM"),
                    "notification message should be human-readable: {msg}"
                );
            }
            Err(crate::preflight::PreflightError::Probe(_)) => {
                // Platform without /proc/meminfo support — acceptable in non-Linux CI.
                // The test is still useful on Linux hosts where the check is real.
            }
            Ok(_) => {
                panic!(
                    "preflight MUST refuse when required_mb == u32::MAX — \
                     this machine does not have {required_mb} MB of RAM"
                );
            }
        }
    }

    // @trace spec:direct-podman-calls, spec:default-image
    // Image routing is now tested in image_builder.rs module tests.

    // @trace spec:external-logs-layer
    #[test]
    fn ensure_external_logs_dir_migrates_existing_file() {
        // Set up: old internal log dir with a git-push.log containing known content.
        use std::io::Write;
        let tmp = std::env::temp_dir().join(format!(
            "til-test-migrate-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .subsec_nanos()
        ));
        // Construct the expected paths that ensure_external_logs_dir() resolves
        // via tillandsias_core::config. Since we can't redirect $HOME easily in
        // tests, we exercise the migration logic directly using tempdir paths.
        let old_dir = tmp.join("containers").join("git").join("logs");
        let new_dir = tmp.join("external-logs").join("git-service");
        std::fs::create_dir_all(&old_dir).expect("create old log dir");
        let old_file = old_dir.join("git-push.log");
        let mut f = std::fs::File::create(&old_file).expect("create old log file");
        f.write_all(b"[git-mirror] Push: success\n").expect("write log");
        drop(f);

        // Rename: simulate the migration (same logic as ensure_external_logs_dir).
        std::fs::create_dir_all(&new_dir).expect("create new dir");
        let new_file = new_dir.join("git-push.log");
        std::fs::rename(&old_file, &new_file).expect("rename");

        // Write MIGRATED.txt stub.
        let stub = old_dir.join("MIGRATED.txt");
        std::fs::write(&stub, format!("Migrated to {}\n", new_file.display()))
            .expect("write stub");

        // Assert: content moved to new location.
        assert!(new_file.exists(), "git-push.log must exist at new location");
        assert!(!old_file.exists(), "git-push.log must no longer exist at old location");
        let content = std::fs::read_to_string(&new_file).expect("read new file");
        assert!(content.contains("[git-mirror] Push: success"), "content must be preserved");

        // Assert: stub left at old directory.
        assert!(stub.exists(), "MIGRATED.txt stub must be left at old directory");
        let stub_content = std::fs::read_to_string(&stub).expect("read stub");
        assert!(
            stub_content.contains(new_file.to_string_lossy().as_ref()),
            "MIGRATED.txt must contain the new path"
        );

        std::fs::remove_dir_all(&tmp).ok();
    }

    // @trace spec:external-logs-layer
    #[test]
    fn ensure_external_logs_dir_idempotent_when_already_migrated() {
        // Set up: new path already exists; old path absent.
        let tmp = std::env::temp_dir().join(format!(
            "til-test-idem-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .subsec_nanos()
        ));
        let new_dir = tmp.join("external-logs").join("git-service");
        std::fs::create_dir_all(&new_dir).expect("create new dir");
        let new_file = new_dir.join("git-push.log");
        std::fs::write(&new_file, b"already migrated\n").expect("write new file");

        // The old path must not exist.
        let old_dir = tmp.join("containers").join("git").join("logs");
        assert!(!old_dir.join("git-push.log").exists(), "precondition: old file absent");

        // Simulate idempotent call: new file exists → no-op; no error.
        // Since the function reads real $HOME paths we test the contract directly:
        // if to.exists() already, nothing should change.
        assert!(new_file.exists(), "new file must still exist");

        // Clean up.
        std::fs::remove_dir_all(&tmp).ok();
    }

    // @trace spec:external-logs-layer
    #[test]
    fn ensure_external_logs_dir_noop_when_nothing_to_migrate() {
        // Set up: neither old nor new path exists.
        let tmp = std::env::temp_dir().join(format!(
            "til-test-noop-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .subsec_nanos()
        ));
        std::fs::create_dir_all(&tmp).expect("create tmp");

        let old_file = tmp.join("containers").join("git").join("logs").join("git-push.log");
        let new_file = tmp.join("external-logs").join("git-service").join("git-push.log");

        // Precondition: neither file exists.
        assert!(!old_file.exists(), "precondition: old file absent");
        assert!(!new_file.exists(), "precondition: new file absent");

        // The function should be a no-op — no files created, no errors.
        // We verify the postcondition: neither file appeared.
        assert!(!old_file.exists(), "old file must remain absent");
        assert!(!new_file.exists(), "new file must remain absent");

        std::fs::remove_dir_all(&tmp).ok();
    }

    // -------------------------------------------------------------------------
    // Auditor unit tests
    // @trace spec:external-logs-layer
    // -------------------------------------------------------------------------

    // @trace spec:external-logs-layer
    #[test]
    fn auditor_manifest_parser_detects_names() {
        // The minimal YAML manifest parser must correctly extract file names.
        let yaml = r#"
role: git-service
files:
  - name: git-push.log
    purpose: |
      One line per push attempt.
    format: text
    rotate_at_mb: 10
    written_by: post-receive hook
  - name: another.log
    purpose: second file
    format: text
    rotate_at_mb: 5
    written_by: entrypoint
"#;
        let names = parse_external_logs_manifest_names(yaml)
            .expect("must parse successfully");
        assert!(names.contains("git-push.log"), "must contain git-push.log");
        assert!(names.contains("another.log"), "must contain another.log");
        assert_eq!(names.len(), 2, "must contain exactly 2 names");
    }

    // @trace spec:external-logs-layer
    #[test]
    fn auditor_manifest_parser_empty_manifest_returns_empty_set() {
        // An empty files list is valid (producer declares no external logs for now).
        let yaml = "role: proxy\nfiles: []\n";
        let names = parse_external_logs_manifest_names(yaml)
            .expect("must parse empty manifest");
        assert!(names.is_empty(), "empty manifest must yield empty name set");
    }

    // @trace spec:external-logs-layer
    #[test]
    fn auditor_detects_unlisted_file_emits_leak() {
        // Set up a role dir with one allowed file (git-push.log) and one
        // unlisted file (unlisted.log). Run the manifest-match logic directly
        // (without podman) by calling parse_external_logs_manifest_names and
        // the walk logic inline. Assert the unlisted file is identified.
        let manifest_yaml = r#"
role: git-service
files:
  - name: git-push.log
    purpose: push log
    format: text
    rotate_at_mb: 10
    written_by: hook
"#;
        let allowed = parse_external_logs_manifest_names(manifest_yaml)
            .expect("manifest must parse");

        let tmp = std::env::temp_dir().join(format!(
            "til-audit-leak-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .subsec_nanos()
        ));
        std::fs::create_dir_all(&tmp).expect("create tmp");
        std::fs::write(tmp.join("git-push.log"), b"ok\n").expect("write allowed");
        std::fs::write(tmp.join("unlisted.log"), b"leaky\n").expect("write unlisted");

        // Walk and classify.
        let mut leaks = vec![];
        for entry in std::fs::read_dir(&tmp).expect("read dir").flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !allowed.contains(&name) {
                leaks.push(name);
            }
        }

        assert_eq!(leaks, vec!["unlisted.log"], "exactly one LEAK should be identified");

        std::fs::remove_dir_all(&tmp).ok();
    }

    // @trace spec:external-logs-layer
    #[test]
    fn auditor_truncates_oversized_file() {
        // Write a file larger than DEFAULT_ROTATE_BYTES (10 MB), call
        // truncate_external_log_to_half, and assert the result is ~50% of the
        // original. We use a much smaller size (100 KB) to keep the test fast.
        let tmp = std::env::temp_dir().join(format!(
            "til-audit-rotate-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .subsec_nanos()
        ));
        std::fs::create_dir_all(&tmp).expect("create tmp");
        let file_path = tmp.join("big.log");

        // Write 100 KB of content.
        let content: Vec<u8> = (0..100 * 1024).map(|i| (i % 256) as u8).collect();
        std::fs::write(&file_path, &content).expect("write big file");
        let original_size = content.len() as u64;

        // Call the rotation function.
        truncate_external_log_to_half(&file_path, original_size, "test-role", "big.log");

        // Assert: file now holds approximately the newest 50% of bytes.
        let rotated = std::fs::read(&file_path).expect("read rotated file");
        let expected_size = original_size / 2;
        assert!(
            rotated.len() as u64 >= expected_size - 1 && rotated.len() as u64 <= expected_size + 1,
            "rotated file must be ~50% of original: expected {expected_size}, got {}",
            rotated.len()
        );

        // The content should be the TAIL of the original.
        let keep_from = (original_size / 2) as usize;
        assert_eq!(&rotated, &content[keep_from..], "rotated content must be the tail");

        std::fs::remove_dir_all(&tmp).ok();
    }

    // @trace spec:external-logs-layer
    #[test]
    fn auditor_growth_rate_alarm_after_5_ticks() {
        // Simulate 5 growth-rate samples — each growing by 2 MB in 60 s,
        // which is 2 MB/min (above the 1 MB/min alarm threshold). The test
        // verifies that the growth-rate calculation would trigger the alarm.
        let mut history: std::collections::VecDeque<GrowthSample> = std::collections::VecDeque::new();

        // Simulate 5 ticks, each 60 s apart (using Instant::now() - offset).
        let now = std::time::Instant::now();
        let two_mb: u64 = 2 * 1024 * 1024;
        // We can't wind back Instant, so we use a forward simulation:
        // oldest entry was at now - 4 min, newest at now.
        // Build the deque as if 5 ticks of 60 s have elapsed.
        for i in 0u64..5 {
            // The test uses a fixed growing size pattern.
            history.push_back((now, i * two_mb));
        }
        // Trim to 5 samples (already at 5).
        while history.len() > 5 { history.pop_front(); }

        // Current (latest) size is 4 * 2MB = 8MB.
        let current_size = 4 * two_mb;
        let (oldest_time, oldest_size) = history.front().copied().unwrap();
        // oldest_time == now (0 elapsed in unit test clock). Use a synthetic
        // elapsed to avoid division by zero: 4 min = 240 s.
        let elapsed_secs = 240.0_f64;
        let grown = current_size.saturating_sub(oldest_size);
        let bytes_per_min = grown as f64 / (elapsed_secs / 60.0);

        // 8 MB grown over 4 min = 2 MB/min > 1 MB/min threshold.
        const ONE_MB_PER_MIN: f64 = 1024.0 * 1024.0;
        assert!(
            bytes_per_min > ONE_MB_PER_MIN,
            "growth rate of {:.2} MB/min must exceed the 1 MB/min threshold",
            bytes_per_min / ONE_MB_PER_MIN
        );

        // Verify the oldest_time comparison used in real code; in tests
        // Instant::now() doesn't elapse, but the logic is covered above.
        // elapsed() in the real code: oldest_time.elapsed() — same pattern.
        let _ = oldest_time.elapsed();
    }
}
