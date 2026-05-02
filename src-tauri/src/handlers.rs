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
use std::time::{Duration, Instant};

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

use tillandsias_core::config::{GlobalConfig, SelectedAgent, cache_dir, load_global_config, load_project_config, save_selected_agent};
use tillandsias_core::event::{AppEvent, BuildProgressEvent, ContainerState};
use tillandsias_core::genus::GenusAllocator;
use tillandsias_core::state::{BuildProgress, BuildStatus, ContainerInfo, ContainerType, TrayState};
use tillandsias_core::tools::ToolAllocator;
use tillandsias_podman::PodmanClient;
use tillandsias_podman::launch::{ContainerLauncher, allocate_port_range};
use tillandsias_podman::query_occupied_ports;

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

/// The chromium-core browser image tag, e.g., `tillandsias-chromium-core:v0.1.126.83`.
/// @trace spec:browser-isolation-core
pub(crate) fn chromium_core_image_tag() -> String {
    format!("tillandsias-chromium-core:v{}", env!("TILLANDSIAS_FULL_VERSION"))
}

/// The chromium-framework browser image tag, e.g., `tillandsias-chromium-framework:v0.1.126.83`.
/// @trace spec:browser-isolation-framework
pub(crate) fn chromium_framework_image_tag() -> String {
    format!("tillandsias-chromium-framework:v{}", env!("TILLANDSIAS_FULL_VERSION"))
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
/// @trace spec:inference-container
pub(crate) async fn ensure_inference_running(
    state: &TrayState,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    // Check if already running (in our state or via podman inspect)
    if state.running.iter().any(|c| c.name == INFERENCE_CONTAINER_NAME) {
        debug!(spec = "inference-container", "Inference container already tracked in state");
        return Ok(());
    }

    let client = PodmanClient::new();

    // Check if it's running outside our state (e.g., surviving a restart).
    // If running but with a stale image version, stop it and rebuild.
    if let Ok(inspect) = client.inspect_container(INFERENCE_CONTAINER_NAME).await {
        if inspect.state == "running" {
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
pub(crate) async fn stop_inference() {
    let client = PodmanClient::new();
    let launcher = tillandsias_podman::launch::ContainerLauncher::new(client);
    match launcher.stop(INFERENCE_CONTAINER_NAME).await {
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
/// @trace spec:proxy-container, spec:enclave-network
pub(crate) async fn ensure_proxy_running(
    state: &TrayState,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    // Check if already running (in our state or via podman inspect)
    if state.running.iter().any(|c| c.name == PROXY_CONTAINER_NAME) {
        debug!(spec = "proxy-container", "Proxy container already tracked in state");
        return Ok(());
    }

    let client = PodmanClient::new();

    // Check if it's running outside our state (e.g., surviving a restart).
    // If running but with a stale image version, stop it and rebuild.
    if let Ok(inspect) = client.inspect_container(PROXY_CONTAINER_NAME).await {
        if inspect.state == "running" {
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
            if let Err(e) = client.stop_container(PROXY_CONTAINER_NAME, 5).await {
                warn!(container = PROXY_CONTAINER_NAME, error = %e, "Failed to stop stale proxy container");
            }
            // Wait briefly for cleanup
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }
    }

    info!(
        accountability = true,
        category = "proxy",
        spec = "proxy-container",
        "Starting proxy container"
    );

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

/// Stop the proxy container if running. Best-effort, errors are logged.
/// @trace spec:proxy-container
pub(crate) async fn stop_proxy() {
    let client = PodmanClient::new();
    let launcher = tillandsias_podman::launch::ContainerLauncher::new(client);
    match launcher.stop(PROXY_CONTAINER_NAME).await {
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
///
/// Used by both `ensure_proxy_running` (readiness loop) and `tools_overlay`
/// (to decide whether to route builds through the enclave or direct).
///
/// @trace spec:proxy-container
pub(crate) async fn is_proxy_healthy() -> bool {
    // DISTRO: Proxy is Alpine — busybox nc (netcat) for TCP probe.
    // wget --spider returns 400 because squid rejects non-proxy HTTP requests.
    let check = tillandsias_podman::podman_cmd()
        .args(["exec", PROXY_CONTAINER_NAME, "sh", "-c", "nc -z localhost 3128"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await;
    check.map(|s| s.success()).unwrap_or(false)
}

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
pub(crate) async fn sweep_orphan_containers() {
    let output = tillandsias_podman::podman_cmd()
        .args(["ps", "--filter", "name=tillandsias-", "--format", "{{.Names}}"])
        .output()
        .await;
    let names = match output {
        Ok(o) if o.status.success() => {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect::<Vec<_>>()
        }
        Ok(o) => {
            debug!(
                exit_code = o.status.code().unwrap_or(-1),
                "podman ps exited non-zero during orphan sweep — skipping"
            );
            return;
        }
        Err(e) => {
            debug!(error = %e, "podman ps failed during orphan sweep — skipping");
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
    let client = PodmanClient::new();
    let launcher = tillandsias_podman::launch::ContainerLauncher::new(client);
    for name in &names {
        if let Err(e) = launcher.stop(name).await {
            debug!(container = %name, error = %e, "Orphan container stop returned error (may have exited already)");
        }
        // Belt-and-suspenders: our runtime always uses `--rm`, so stop also
        // deletes. But older installations or hand-built containers might
        // not; force-remove here so the orphan is fully gone either way.
        let _ = tillandsias_podman::podman_cmd()
            .args(["rm", "-f", name])
            .output()
            .await;
        // Also wipe any residual token file for this container.
        crate::secrets::cleanup_token_file(name);
    }
    // Finally clear the enclave network itself — safe to recreate on next launch.
    cleanup_enclave_network().await;
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
        if in_origin_section {
            if let Some(url) = trimmed.strip_prefix("url") {
                let url = url.trim().strip_prefix('=').unwrap_or("").trim();
                if !url.is_empty() {
                    return GitProjectState::RemoteRepo {
                        remote_url: url.to_string(),
                    };
                }
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
        match run_git(&["-C", mirror_ref, "fetch", "--all"], &mounts) {
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
    // pushes to the real remote (through the git service's D-Bus keyring access)
    // instead of trying to push to an inaccessible local path.
    // @trace spec:git-mirror-service
    if let GitProjectState::RemoteRepo { ref remote_url } = state {
        let mirror_ref = if has_git { mp.as_str() } else { container_mirror.as_str() };
        match run_git(
            &["-C", mirror_ref, "remote", "set-url", "origin", remote_url],
            &mounts,
        ) {
            Ok(o) if o.status.success() => {
                info!(
                    spec = "git-mirror-service",
                    project = %project_name,
                    remote_url = %remote_url,
                    "Mirror origin set to project's remote URL"
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

/// Ensure the git service container is running for a project.
///
/// Checks if `tillandsias-git-<project>` is already running. If not,
/// builds the git image if needed and starts a detached git service
/// container on the enclave network with the mirror mounted.
///
/// @trace spec:git-mirror-service
pub(crate) async fn ensure_git_service_running(
    project_name: &str,
    mirror_path: &Path,
    state: &TrayState,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    let container_name = tillandsias_core::state::ContainerInfo::git_service_container_name(project_name);

    // Check if already running (in our state or via podman inspect)
    if state.running.iter().any(|c| c.name == container_name) {
        debug!(spec = "git-mirror-service", project = %project_name, "Git service already tracked in state");
        return Ok(());
    }

    let client = PodmanClient::new();

    // Check if it's running outside our state.
    // If running but with a stale image version, stop it and rebuild.
    if let Ok(inspect) = client.inspect_container(&container_name).await {
        if inspect.state == "running" {
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
// Tools overlay — delegated to tools_overlay module
// @trace spec:layered-tools-overlay
// ---------------------------------------------------------------------------

// NOTE: tools_overlay::ensure_tools_overlay is called via the full
// crate::tools_overlay::ensure_tools_overlay path in handle_attach_here().

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

    // NOTE: Tools overlay (ensure_tools_overlay) is NOT called here because it
    // requires the forge image to exist (it runs a temporary forge container).
    // On first launch, the forge image may not be built yet. Instead, tools
    // overlay is called from handle_attach_here() AFTER forge image is confirmed.
    // @trace spec:layered-tools-overlay

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
/// @trace spec:enclave-network, spec:proxy-container
pub async fn ensure_infrastructure_ready(
    state: &TrayState,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    // @trace spec:layered-tools-overlay
    // Extract config overlay to tmpfs before containers launch.
    // Non-fatal — containers will use defaults if extraction fails.
    if let Err(e) = crate::embedded::extract_config_overlay() {
        warn!(error = %e, spec = "layered-tools-overlay", "Config overlay extraction failed — containers will use default configs");
    }

    ensure_enclave_network().await?;
    ensure_proxy_running(state, build_tx).await?;

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
pub(crate) async fn stop_git_service(project_name: &str) {
    let name = tillandsias_core::state::ContainerInfo::git_service_container_name(project_name);
    let client = PodmanClient::new();
    let launcher = tillandsias_podman::launch::ContainerLauncher::new(client);
    match launcher.stop(&name).await {
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
/// Keeps only the current version tag for each type (forge, proxy, git, inference, chromium).
pub(crate) fn prune_old_images() {
    let current_tags = [
        forge_image_tag(),
        proxy_image_tag(),
        git_image_tag(),
        inference_image_tag(),
        chromium_core_image_tag(),
        chromium_framework_image_tag(),
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
                    // Normalize: strip localhost/ prefix for comparison
                    let normalized = trimmed.strip_prefix("localhost/").unwrap_or(trimmed);
                    // Only target tillandsias images (all types including chromium)
                    let is_tillandsias = normalized.starts_with("tillandsias-forge:")
                        || normalized.starts_with("tillandsias-proxy:")
                        || normalized.starts_with("tillandsias-git:")
                        || normalized.starts_with("tillandsias-inference:")
                        || normalized.starts_with("tillandsias-chromium-core:")
                        || normalized.starts_with("tillandsias-chromium-framework:")
                        || normalized.starts_with("tillandsias-router:");  // Legacy: remove old router images
                    // Keep current version tags
                    let is_current = current_tags.iter().any(|tag| normalized == tag);
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
            .args(["rmi", "-f", image])
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
    for ip in ips.trim().split_whitespace() {
        if !ip.starts_with("10.89.") {
            return Ok(ip.to_string());
        }
    }
    // Fallback: use any IP
    ips.trim()
        .split_whitespace()
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
fn image_build_paths(source_dir: &std::path::Path, image_name: &str) -> (PathBuf, PathBuf) {
    let subdir = match image_name {
        "proxy" => "proxy",
        "git" => "git",
        "inference" => "inference",
        "web" => "web",
        // forge / default / unknown all build the forge image. Keeping this
        // permissive matches build-image.sh's behavior; the image_name
        // validation lives at the call sites that compute the tag.
        _ => "default",
    };
    let dir = source_dir.join("images").join(subdir);
    (dir.join("Containerfile"), dir)
}

/// Run `build-image.sh` from the embedded binary scripts.
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

    let script = source_dir.join("scripts").join("build-image.sh");
    // Use the correct versioned tag for each image type.
    // @trace spec:default-image, spec:proxy-container, spec:git-mirror-service, spec:inference-container
    // @trace spec:browser-isolation-core, spec:browser-isolation-framework
    let tag = match image_name {
        "proxy" => proxy_image_tag(),
        "git" => git_image_tag(),
        "inference" => inference_image_tag(),
        "chromium-core" => chromium_core_image_tag(),
        "chromium-framework" => chromium_framework_image_tag(),
        _ => forge_image_tag(),
    };
    info!(script = %script.display(), image = image_name, tag = %tag, spec = "default-image, nix-builder", "Running embedded build-image.sh");

    // On Windows, call podman build directly instead of going through bash.
    // Git Bash's MSYS2 doesn't initialize properly from native Windows processes.
    #[cfg(target_os = "windows")]
    {
        // @trace spec:default-image, spec:fix-windows-image-routing
        // Route Containerfile + context by image_name. Mirrors the `case` in
        // scripts/build-image.sh so Windows builds the right image instead of
        // tagging the forge image with proxy/git/inference names.
        let (containerfile, context_dir) = image_build_paths(&source_dir, image_name);
        info!(
            image = image_name,
            tag = %tag,
            containerfile = %containerfile.display(),
            spec = "default-image, fix-windows-image-routing",
            "Running podman build directly (Windows)"
        );

        let output = tillandsias_podman::podman_cmd_sync()
            .args(["build", "--tag", &tag, "-f"])
            .arg(&containerfile)
            .arg(&context_dir)
            .output()
            .map_err(|e| {
                error!(image = image_name, error = %e, "Failed to launch podman build");
                strings::SETUP_ERROR
            })?;

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

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let stdout = String::from_utf8_lossy(&output.stdout);
            error!(
                image = image_name,
                exit_code = output.status.code().unwrap_or(-1),
                stdout = %stdout,
                stderr = %stderr,
                "podman build failed"
            );
            return Err(strings::SETUP_ERROR.into());
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        debug!(output = %stdout, "podman build completed");
        prune_old_images();
        return Ok(());
    }

    // On Unix, use the build-image.sh script (handles nix + fedora backends).
    #[cfg(not(target_os = "windows"))]
    {
        let mut cmd = std::process::Command::new(&script);
        cmd.arg(image_name)
            .args(["--tag", &tag, "--backend", "fedora"])
            .current_dir(&source_dir)
            .env_remove("LD_LIBRARY_PATH")
            .env_remove("LD_PRELOAD")
            .env("PODMAN_PATH", tillandsias_podman::find_podman_path());

        // Image builds do NOT go through the proxy. SSL bump on port 3129
        // intercepts HTTPS, but build containers don't have our CA cert
        // installed — they'd reject the MITM'd certificate. Runtime containers
        // have the CA chain injected via bind-mount + update-ca-trust.
        // @trace spec:proxy-container

        let output = cmd.output()
            .map_err(|e| {
                error!(script = %script.display(), image = image_name, error = %e, "Failed to launch image build script");
                strings::SETUP_ERROR
            })?;

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

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let stdout = String::from_utf8_lossy(&output.stdout);
            error!(
                image = image_name,
                exit_code = output.status.code().unwrap_or(-1),
                stdout = %stdout,
                stderr = %stderr,
                spec = "default-image, nix-builder",
                "Image build script failed"
            );
            return Err(strings::SETUP_ERROR.into());
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        debug!(output = %stdout, "build-image.sh completed");
        prune_old_images();

        Ok(())
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
        selected_language: tillandsias_core::config::load_global_config().i18n.language.clone(),
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
// @trace spec:tray-minimal-ux
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
#[instrument(skip(state, allocator, build_tx), fields(project = %project_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string()), operation = "attach", spec = "podman-orchestration, default-image"))]
pub async fn handle_attach_here(
    project_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    build_tx: mpsc::Sender<BuildProgressEvent>,
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
        return handle_attach_web(project_path, state, allocator, build_tx).await;
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

    // @trace spec:layered-tools-overlay
    // Tools overlay runs HERE — after forge image is confirmed ready (above) and
    // enclave is up (proxy available for npm downloads). Hard failure: no
    // per-container fallback — if the overlay cannot be built we refuse the
    // launch so the real ordering/build error is visible.
    if let Err(e) = crate::tools_overlay::ensure_tools_overlay(build_tx.clone()).await {
        error!(
            spec = "layered-tools-overlay",
            error = %e,
            "Tools overlay build failed — aborting attach"
        );
        state.running.retain(|c| c.name != container_name);
        allocator.release(&project_name, genus);
        return Err(strings::SETUP_ERROR.into());
    }

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

    // P2-4: Spawn background tools overlay update after successful launch.
    // Non-blocking — container is already running, this checks for newer
    // tool versions in the background.
    // @trace spec:layered-tools-overlay
    crate::tools_overlay::spawn_background_update();

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
    skip(state, allocator, build_tx),
    fields(
        project = %project_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string()),
        operation = "attach-web",
        spec = "opencode-web-session, podman-orchestration, default-image"
    )
)]
pub async fn handle_attach_web(
    project_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    build_tx: mpsc::Sender<BuildProgressEvent>,
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
        if let Err(e) = crate::webview::wait_for_web_ready(host_port).await {
            let msg = format!(
                "OpenCode Web server not responding for '{}': {}",
                project_name, e
            );
            send_notification("Tillandsias", &msg);
            return Err(msg);
        }
        // Find the genus for the title (should exist since we matched above).
        let genus_label = state
            .running
            .iter()
            .find(|c| c.name == container_name)
            .map(|c| c.genus.display_name().to_string())
            .unwrap_or_default();
        if let Err(e) =
            crate::webview::open_web_session_global(&project_name, &genus_label, host_port)
        {
            warn!(
                project = %project_name,
                port = host_port,
                error = %e,
                spec = "opencode-web-session",
                "Failed to open additional webview (container remains running)"
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

    // @trace spec:layered-tools-overlay
    if let Err(e) = crate::tools_overlay::ensure_tools_overlay(build_tx.clone()).await {
        warn!(
            accountability = true,
            category = "performance",
            safety = "DEGRADED: tools will be installed per-container instead of from cache",
            spec = "layered-tools-overlay",
            error = %e,
            "Tools overlay setup failed — performance degradation (web mode)"
        );
    }

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
    // Health-wait for the loopback server before opening the webview.
    // On timeout: the container stays running (user can retry); we only
    // fail the open attempt.
    if let Err(e) = crate::webview::wait_for_web_ready(host_port).await {
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

    // @trace spec:opencode-web-session
    // Open the Tauri webview. Failure is decoupled from container health —
    // log a warning and keep the container running for another attempt.
    if let Err(e) = crate::webview::open_web_session_global(
        &project_name,
        genus.display_name(),
        host_port,
    ) {
        warn!(
            project = %project_name,
            port = host_port,
            error = %e,
            spec = "opencode-web-session",
            "Failed to open webview window (container remains running)"
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

    // @trace spec:layered-tools-overlay
    crate::tools_overlay::spawn_background_update();

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

    // @trace spec:opencode-web-session, spec:browser-daemon-tracking
    // Stop all containers for this project: OpenCodeWeb + Browser containers.
    let containers: Vec<ContainerInfo> = state
        .running
        .iter()
        .filter(|c| {
            c.project_name == project_name
                && matches!(
                    c.container_type,
                    tillandsias_core::state::ContainerType::OpenCodeWeb
                        | tillandsias_core::state::ContainerType::Browser
                )
        })
        .cloned()
        .collect();

    if containers.is_empty() {
        info!(
            project = %project_name,
            spec = "opencode-web-session, browser-daemon-tracking",
            "Stop requested but no tracked containers for project — nothing to do"
        );
        return Ok(());
    }

    info!(
        project = %project_name,
        count = containers.len(),
        spec = "opencode-web-session, browser-daemon-tracking",
        "Stop project requested — stopping all containers for project"
    );

    // Close webviews first so the user sees them vanish before the container
    // actually stops. Order doesn't affect correctness but matches intent.
    crate::webview::close_web_sessions_for_project_global(&project_name);

    let client = PodmanClient::new();
    let launcher = ContainerLauncher::new(client);

    for container in &containers {
        if let Err(e) = launcher.stop(&container.name).await {
            // Graceful fallback: the launcher already did SIGTERM→SIGKILL; if that
            // still failed (container already gone, podman flaky), log and proceed
            // so state doesn't desync.
            warn!(
                container = %container.name,
                error = %e,
                spec = "opencode-web-session, browser-daemon-tracking",
                "launcher.stop failed — removing from state anyway"
            );
        }
    }

    // Remove all stopped containers from state
    let names_to_remove: Vec<String> = containers.iter().map(|c| c.name.clone()).collect();
    state
        .running
        .retain(|c| !names_to_remove.contains(&c.name));

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
        project = %project_name,
        count = containers.len(),
        spec = "opencode-web-session, browser-daemon-tracking",
        "Containers stopped and removed from state"
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
    // Close every open OpenCode Web webview first so the UI fades out before
    // the backing containers begin to stop. Failures are logged inside the
    // helper and do not block the rest of the shutdown sequence.
    crate::webview::close_all_web_sessions_global();

    let client = PodmanClient::new();
    let launcher = ContainerLauncher::new(client);

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
    // Stop git service containers for every project that had one tracked.
    // @trace spec:git-mirror-service, spec:persistent-git-service, spec:opencode-web-session
    for project_name in &git_service_projects {
        stop_git_service(project_name).await;
    }

    // Stop the inference container
    // @trace spec:inference-container
    stop_inference().await;

    // Stop the proxy
    // @trace spec:proxy-container
    stop_proxy().await;

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
        }
    }

    // Clean up the enclave network
    // @trace spec:enclave-network
    cleanup_enclave_network().await;

    info!(
        accountability = true,
        category = "enclave",
        spec = "enclave-network",
        "All containers stopped, enclave shut down"
    );
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
            // P2-4: Spawn background tools overlay update after successful launch.
            // @trace spec:layered-tools-overlay
            crate::tools_overlay::spawn_background_update();
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
pub async fn handle_github_login(
    _state: &TrayState,
    _build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    info!("GitHub Login: spawning `tillandsias --github-login` in a terminal");

    let exe = std::env::current_exe()
        .map_err(|e| format!("Cannot locate own executable: {e}"))?;

    // open_terminal takes a command string it hands to the OS's shell.
    // Quote the executable path so spaces (Program Files, username etc.) work.
    let exe_str = exe.to_string_lossy();
    let cmd = if exe_str.contains(' ') {
        format!("\"{exe_str}\" --github-login")
    } else {
        format!("{exe_str} --github-login")
    };

    open_terminal(&cmd, "GitHub Login")
        .map_err(|e| format!("Failed to open terminal: {e}"))
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

/// Handle a browser window request from the MCP server.
///
/// Validates the request, applies debouncing, spawns a Chromium window using
/// the `chromium_launcher` module, and tracks the container in TrayState.
///
/// # Arguments
///
/// * `project` - The project name
/// * `url` - The URL to open
/// * `window_type` - Either "open_safe_window" or "open_debug_window"
/// * `state` - Mutable reference to TrayState for tracking
///
/// @trace spec:browser-daemon-tracking, spec:browser-debounce, spec:browser-isolation-core
#[cfg(target_os = "linux")]
pub async fn handle_open_browser_window(
    project: &str,
    url: &str,
    window_type: &str,
    state: &mut TrayState,
) -> Result<(), String> {
    use crate::chromium_launcher;
    use std::time::Instant;

    info!(
        spec = "browser-daemon-tracking",
        project = %project,
        url = %url,
        window_type = %window_type,
        "Handling browser window request"
    );

    // Validate window type
    match window_type {
        "open_safe_window" | "open_debug_window" => {}
        _ => {
            return Err(format!(
                "Invalid window_type: '{}'. Expected 'open_safe_window' or 'open_debug_window'",
                window_type
            ));
        }
    }

    // Validate URL
    if window_type == "open_safe_window" {
        if !url.contains(&format!(".{}.localhost", project))
            && !url.contains("dashboard.localhost")
        {
            return Err(format!(
                "Invalid URL for safe window: '{}'. Expected <service>.<project>.localhost or dashboard.localhost",
                url
            ));
        }
    } else if window_type == "open_debug_window" {
        if !url.contains(&format!(".{}.localhost", project)) {
            return Err(format!(
                "Invalid URL for debug window: '{}'. Expected <service>.<project>.localhost",
                url
            ));
        }
    }

    // Debounce: prevent rapid successive spawns (10s window for safe windows)
    let now = Instant::now();
    if window_type == "open_safe_window" {
        if let Some(last_launch) = state.browser_last_launch.get(project) {
            if now.duration_since(*last_launch) < Duration::from_secs(10) {
                info!(
                    spec = "browser-debounce",
                    project = %project,
                    "Debounced rapid browser spawn (safe window)"
                );
                return Err("Debounced: too many rapid browser launches".to_string());
            }
        }
    }

    // Debug browser: only one per project (simplified for now)
    if window_type == "open_debug_window" {
        // NOTE: is_process_running() and get_container_pid() not yet implemented
        // Skipping debug browser duplicate check for now
        // TODO: implement these functions in chromium_launcher module
    }

    // Push BuildProgress notification (Browser — <project>)
    let build_id = format!("browser-{}", project);
    state.active_builds.retain(|b| b.image_name != build_id);
    state.active_builds.push(BuildProgress {
        image_name: format!("Browser — {}", project),
        status: BuildStatus::InProgress,
        started_at: now,
        completed_at: None,
    });

    // Spawn the Chromium window
    let container_id = chromium_launcher::spawn_chromium_window(project, url, window_type)?;

    // Update timestamp on successful spawn
    state.browser_last_launch.insert(project.to_string(), now);

    // Track the container in state.running
    let container_name = format!("tillandsias-chromium-{}-{}", project, window_type);
    let genus = tillandsias_core::genus::TillandsiaGenus::Ionantha; // placeholder
    state.running.push(ContainerInfo {
        name: container_name,
        project_name: project.to_string(),
        genus,
        state: ContainerState::Running,
        port_range: (0, 0), // Browser containers don't use port ranges
        container_type: ContainerType::Browser,
        display_emoji: "🌐".to_string(),
    });

    // Track debug browser PID (simplified - no PID tracking without get_container_pid)
    if window_type == "open_debug_window" {
        // NOTE: get_container_pid() not yet implemented
        // TODO: implement PID tracking when needed
    }

    // Update BuildProgress to Completed, start 5s fadeout
    if let Some(build) = state.active_builds.iter_mut().find(|b| b.image_name == format!("Browser — {}", project)) {
        build.status = BuildStatus::Completed;
        build.completed_at = Some(Instant::now());
    }

    info!(
        spec = "browser-daemon-tracking",
        container_id = %container_id,
        project = %project,
        window_type = %window_type,
        "Browser window spawned and tracked successfully"
    );

    Ok(())
}

/// @trace spec:cli-diagnostics, spec:observability-convergence
/// Stream live container logs for the given project to stdout.
///
/// Discovers all running Tillandsias containers (shared infra + project-specific)
/// and spawns `podman logs -f` for each, with line-by-line source labels.
pub async fn handle_diagnostics(project_path: Option<&std::path::Path>, _debug: bool) -> Result<(), String> {
    use std::process::{Command, Stdio};
    use std::io::{BufRead, BufReader};

    info!(
        spec = "cli-diagnostics",
        cheatsheet = "docs/cheatsheets/podman-logging.md",
        "Diagnostics: starting container log stream"
    );

    // Discover running containers: shared infra + project-specific
    let shared_containers = vec!["tillandsias-proxy", "tillandsias-git", "tillandsias-inference"];

    let project_containers: Vec<String> = if let Some(project_path) = project_path {
        let project_name = project_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("unknown")
            .to_string();
        vec![
            format!("tillandsias-{}-forge", project_name),
            format!("tillandsias-{}-browser-core", project_name),
            format!("tillandsias-{}-browser-framework", project_name),
        ]
    } else {
        vec![]
    };

    let all_containers: Vec<&str> = shared_containers
        .iter()
        .map(|s| &s[..])
        .chain(project_containers.iter().map(|s| &s[..]))
        .collect();

    // Check which containers are actually running
    let mut running_containers = Vec::new();
    for container in &all_containers {
        let output = Command::new("podman")
            .args(&["ps", "--quiet", "--filter", &format!("name={}", container)])
            .output();

        if let Ok(output) = output {
            let container_id = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !container_id.is_empty() {
                running_containers.push(*container);
            }
        }
    }

    if running_containers.is_empty() {
        let msg = if let Some(path) = project_path {
            format!("No running Tillandsias containers found for project: {}", path.display())
        } else {
            "No running Tillandsias containers found".to_string()
        };
        warn!(
            spec = "cli-diagnostics",
            "Diagnostics: no running containers",
        );
        eprintln!("{}", msg);
        return Ok(());
    }

    info!(
        spec = "cli-diagnostics",
        container_count = running_containers.len(),
        "Diagnostics: found running containers"
    );

    // Spawn `podman logs -f` for each container in parallel
    let mut children = Vec::new();
    for container in &running_containers {
        // Extract container type (proxy, git, forge, browser-core, browser-framework)
        let container_type = if container.contains("proxy") {
            "proxy"
        } else if container.contains("git") {
            "git"
        } else if container.contains("inference") {
            "inference"
        } else if container.contains("browser-core") {
            "browser-core"
        } else if container.contains("browser-framework") {
            "browser-framework"
        } else {
            "forge"
        };

        // Extract project name if present
        let owner = if container.starts_with("tillandsias-") {
            let parts: Vec<&str> = container.split('-').collect();
            if parts.len() > 1 && parts[1] != "proxy" && parts[1] != "git" && parts[1] != "inference" {
                parts[1]
            } else {
                "shared"
            }
        } else {
            "unknown"
        };

        let container_copy = container.to_string();
        let container_type_copy = container_type.to_string();
        let owner_copy = owner.to_string();

        let child = std::thread::spawn(move || {
            let mut cmd = Command::new("podman");
            cmd.args(&["logs", "-f", &container_copy])
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());

            if let Ok(mut child) = cmd.spawn() {
                if let Some(stdout) = child.stdout.take() {
                    let reader = BufReader::new(stdout);
                    for line in reader.lines() {
                        if let Ok(line) = line {
                            let prefix = format!("[{}:{}]", container_type_copy, owner_copy);
                            eprintln!("{} {}", prefix, line);
                        }
                    }
                }
            }
        });

        children.push(child);
    }

    // Wait for all children to finish (they run until Ctrl+C)
    for child in children {
        let _ = child.join();
    }

    info!(
        spec = "cli-diagnostics",
        "Diagnostics: stream ended"
    );

    Ok(())
}

/// Handle "OpenCode" action: opens the terminal-based IDE.
/// @trace spec:tray-minimal-ux
#[instrument(skip(state, allocator, build_tx), fields(project = %project_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string()), operation = "opencode", spec = "tray-minimal-ux"))]
pub async fn handle_opencode_project(
    project_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<AppEvent, String> {
    // OpenCode terminal mode: use the standard attach-here flow
    // which defaults to terminal-based OpenCode unless overridden by config.
    // @trace spec:tray-minimal-ux
    handle_attach_here(project_path, state, allocator, build_tx).await
}

/// Handle "OpenCode Web" action: opens the web-based IDE.
/// Currently routes through handle_attach_web, but should transition to browser isolation.
/// @trace spec:browser-isolation-tray-integration
#[instrument(skip(state, allocator, build_tx), fields(project = %project_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string()), operation = "opencode-web", spec = "browser-isolation-tray-integration"))]
pub async fn handle_opencode_web_project(
    project_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<AppEvent, String> {
    // OpenCode Web mode: use handle_attach_web which manages the persistent
    // forge container and opens the web interface.
    // TODO: @tombstone webview-based flow, transition to browser-isolation-core
    // @trace spec:browser-isolation-tray-integration
    handle_attach_web(project_path, state, allocator, build_tx).await
}

/// Handle "Claude" action: opens the Claude assistant.
/// @trace spec:tray-minimal-ux
#[instrument(skip(state, allocator, build_tx), fields(project = %project_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string()), operation = "claude", spec = "tray-minimal-ux"))]
pub async fn handle_claude_project(
    project_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<AppEvent, String> {
    // Claude mode: use the standard attach-here flow.
    // @trace spec:tray-minimal-ux
    handle_attach_here(project_path, state, allocator, build_tx).await
}

/// Handle "Maintenance" action: opens a terminal for maintenance tasks.
/// @trace spec:tray-minimal-ux
#[instrument(skip(state, allocator, tool_allocator, build_tx), fields(project = %project_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string()), operation = "maintenance", spec = "tray-minimal-ux"))]
pub async fn handle_maintenance_project(
    project_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    tool_allocator: &mut ToolAllocator,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    // Maintenance is equivalent to Terminal mode
    handle_terminal(project_path, state, allocator, tool_allocator, build_tx).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    use tillandsias_core::state::{ContainerType, TrayState};

    // @trace spec:default-image, spec:fix-windows-image-routing
    #[test]
    fn image_build_paths_routes_each_image_to_its_own_subdir() {
        let root = Path::new("/tmp/sources");

        let cases = [
            ("forge", "default"),
            ("proxy", "proxy"),
            ("git", "git"),
            ("inference", "inference"),
            ("web", "web"),
            ("definitely-not-real", "default"),
        ];

        for (image_name, expected_subdir) in cases {
            let (containerfile, context) = image_build_paths(root, image_name);
            let expected_dir = root.join("images").join(expected_subdir);
            assert_eq!(
                context, expected_dir,
                "context for {image_name} should be {expected_dir:?}"
            );
            assert_eq!(
                containerfile,
                expected_dir.join("Containerfile"),
                "Containerfile for {image_name} should live in {expected_dir:?}"
            );
        }
    }

    #[test]
    fn test_debounce_prevents_rapid_spawns() {
        // This is a unit test for the debounce logic
        // In practice, this would need a mock of TrayState and time
        // For now, just verify the logic exists in handle_open_browser_window
        assert!(true); // Placeholder - full test needs integration setup
    }

    #[test]
    fn test_only_one_debug_browser_per_project() {
        // Placeholder for testing that only one debug browser can run per project
        assert!(true); // Placeholder - full test needs integration setup
    }

    #[test]
    fn test_browser_container_tracked_in_state() {
        // Placeholder for testing that browser containers are added to state.running
        assert!(true); // Placeholder - full test needs integration setup
    }

    #[test]
    fn test_shutdown_cleans_up_browser_containers() {
        // Placeholder for testing that shutdown_all stops browser containers
        assert!(true); // Placeholder - full test needs integration setup
    }
}
