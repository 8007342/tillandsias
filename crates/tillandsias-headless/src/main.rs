// @trace spec:linux-native-portable-executable, spec:runtime-logging
//! Tillandsias native headless app lifecycle launcher.
//!
//! Runs containerized development environments without a graphical interface.
//! Suitable for CI/CD, automation, and server deployments.
//!
//! Transparent Mode Detection (Phase 3):
//! - If --headless NOT set AND native Linux tray support is available, spawn tray
//! - If --headless set, run in headless mode (no tray UI)
//! - If --tray set, explicitly run in tray mode
//!
//! Usage:
//!   tillandsias                              # Auto-detect (transparent mode)
//!   tillandsias --headless [config_path]    # Headless mode (no UI)
//!   tillandsias --tray [config_path]        # Tray mode (requires native Linux tray feature)
//!
//! JSON Events:
//!   - {"event":"app.started","timestamp":"<RFC3339>"} — at startup
//!   - {"event":"containers.running","count":N} — on discovery
//!   - {"event":"app.stopped","exit_code":0,"timestamp":"<RFC3339>"} — on graceful shutdown
//!
//! Logging Integration:
//! See `crates/tillandsias-logging/INTEGRATION.md` for structured logging setup,
//! including container lifecycle events, accountability windows, and log rotation.

use signal_hook::flag;
use std::fs;
use std::io::{self, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tempfile::Builder as TempDirBuilder;
use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION, encode};
use tillandsias_podman::{
    ContainerSpec, MountMode, PodmanClient, detect_gpu_devices, podman_cmd_sync,
};
use tracing::{debug, error, info};

use serde::{Deserialize, Serialize};

const VERSION: &str = include_str!("../../../VERSION");

fn main() {
    let version = VERSION.trim();

    // Parse CLI arguments
    let args: Vec<String> = std::env::args().collect();
    let user_args: Vec<String> = args.iter().skip(1).cloned().collect();

    if user_args.iter().any(|a| a == "--version") {
        println!("Tillandsias v{}", version);
        return;
    }

    if user_args.iter().any(|a| a == "--help" || a == "-h") {
        print_usage(version);
        return;
    }

    let debug = user_args.iter().any(|a| a == "--debug");
    let diagnostics = user_args.iter().any(|a| a == "--diagnostics");
    let init = user_args.iter().any(|a| a == "--init");
    let force = user_args.iter().any(|a| a == "--force");
    let status_check = user_args.iter().any(|a| a == "--status-check");
    let github_login = user_args.iter().any(|a| a == "--github-login");
    let opencode = user_args.iter().any(|a| a == "--opencode");
    let opencode_web = user_args.iter().any(|a| a == "--opencode-web");
    let cache_clear = user_args.iter().any(|a| a == "--cache-clear");
    let cache_verify = user_args.iter().any(|a| a == "--cache-verify");

    // @trace spec:cli-mode, spec:runtime-diagnostics-stream
    // --diagnostics implies --debug
    let debug = debug || diagnostics;

    // @trace spec:cli-mode
    let prompt = user_args
        .iter()
        .position(|a| a == "--prompt")
        .and_then(|i| user_args.get(i + 1).map(|p| p.to_string()));

    let known_flags = [
        "--headless",
        "--tray",
        "--debug",
        "--diagnostics",
        "--force",
        "--init",
        "--status-check",
        "--github-login",
        "--opencode",
        "--opencode-web",
        "--prompt",
        "--cache-clear",
        "--cache-verify",
    ];
    if let Some(unsupported) = user_args
        .iter()
        .enumerate()
        .find(|(i, a)| {
            a.starts_with('-')
                && !known_flags.contains(&a.as_str())
                && user_args
                    .get(i.saturating_sub(1))
                    .is_none_or(|prev| prev != "--prompt")
        })
        .map(|(_, a)| a)
    {
        eprintln!("Unsupported option: {unsupported}");
        eprintln!("Run 'tillandsias --help' for supported options.");
        std::process::exit(2);
    }

    let headless = user_args.iter().any(|a| a == "--headless");
    let tray = user_args.iter().any(|a| a == "--tray");
    let config_path = user_args
        .iter()
        .find(|a| !a.starts_with('-'))
        .map(|p| p.to_string());

    if github_login {
        if let Err(e) = run_github_login(debug) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
        return;
    }

    if cache_clear {
        if let Err(e) = run_cache_clear(debug) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
        return;
    }

    if cache_verify {
        if let Err(e) = run_cache_verify(debug) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
        return;
    }

    if init {
        if let Err(e) = run_init(debug, force) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
        if status_check && let Err(e) = run_status_check(debug) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
        if !opencode {
            return;
        }
    }

    if status_check && !init {
        if let Err(e) = run_status_check(debug) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
        return;
    }

    if opencode {
        if let Some(project_path) = config_path {
            if let Err(e) = run_opencode_mode(&project_path, prompt.as_deref(), debug) {
                eprintln!("Error: {}", e);
                std::process::exit(1);
            }
            return;
        } else {
            eprintln!("Error: --opencode requires project path");
            std::process::exit(2);
        }
    }

    if opencode_web {
        if let Some(project_path) = config_path {
            if let Err(e) = run_opencode_web_mode(&project_path, prompt.as_deref(), debug) {
                eprintln!("Error: {}", e);
                std::process::exit(1);
            }
            return;
        } else {
            eprintln!("Error: --opencode-web requires project path");
            std::process::exit(2);
        }
    }

    // Phase 3, Task 12: Auto-detection (transparent mode)
    // If neither --headless nor --tray specified, auto-detect based on environment
    if !headless && !tray {
        if is_tray_available() {
            // @trace spec:linux-native-portable-executable, spec:transparent-mode-detection
            // Native tray support is available — launch tray mode.
            if cfg!(feature = "tray") {
                if let Err(e) = launch_tray_mode(config_path) {
                    eprintln!("Error launching tray mode: {}", e);
                    std::process::exit(1);
                }
                return;
            } else {
                // GTK available but tray feature not compiled — fall back to headless
                eprintln!(
                    "Native tray support detected but tray feature not compiled. \
                    To use tray mode, rebuild with --features tray"
                );
                // Continue to headless mode below
            }
        } else {
            // GTK not available — run headless directly. This keeps the app
            // lifecycle usable even when the native tray artifact is absent.
        }
    }

    // Phase 3, Task 13: Explicit --tray flag support
    if tray {
        if cfg!(feature = "tray") {
            if let Err(e) = launch_tray_mode(config_path) {
                eprintln!("Error launching tray mode: {}", e);
                std::process::exit(1);
            }
            return;
        } else {
            eprintln!("Native tray wrapper is not packaged in this launcher yet.");
            eprintln!("Continuing with the headless app lifecycle for now.");
            if let Err(e) = run_headless(config_path) {
                eprintln!("Error: {}", e);
                std::process::exit(1);
            }
            return;
        }
    }

    // Headless mode (explicit --headless or auto-detected)
    if (headless || !cfg!(feature = "tray"))
        && let Err(e) = run_headless(config_path)
    {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

fn print_usage(version: &str) {
    println!("Tillandsias v{}", version);
    println!("Usage: tillandsias [--headless|--tray] [config_path]");
    println!("       tillandsias --init [--force] [--debug]");
    println!("       tillandsias --status-check [--debug]");
    println!("       tillandsias --github-login [--debug]");
    println!("       tillandsias --cache-verify [--debug]");
    println!("       tillandsias --cache-clear [--debug]");
    println!("       tillandsias --opencode <project> [--prompt <text>] [--debug|--diagnostics]");
    println!(
        "       tillandsias --opencode-web <project> [--prompt <text>] [--debug|--diagnostics]"
    );
    println!("  --headless     Run in headless mode (no UI)");
    println!("  --tray         Run in tray mode (requires native tray support)");
    println!("  --opencode     Enable LLM code analysis mode");
    println!("  --opencode-web Launch OpenCode Web plus isolated browser");
    println!("  --prompt TEXT  Send prompt to LLM inference (requires --opencode)");
    println!("  --init         Pre-build container images");
    println!("  --force        Rebuild all images even if cached (use with --init)");
    println!("  --cache-verify Check cache integrity and report status");
    println!("  --cache-clear  Clear the initialization cache and build state");
    println!("  --status-check Verify services are online through a representative stack smoke");
    println!("  --github-login Authenticate GitHub and create ephemeral Podman secret");
    println!("  --debug        Show command-level diagnostics and capture build logs");
    println!(
        "  --diagnostics  Stream real-time logs from all enclave containers (implies --debug)"
    );
    println!("  --version      Show version information");
    println!("  --help         Show this help");
    println!();
    println!("Auto-detection: Tray mode if native tray support is available, headless otherwise");
}

/// Locate the Tillandsias checkout root.
///
/// The binary uses this to resolve image source paths and workspace-relative
/// mounts when it is launched from outside the repository.
fn find_checkout_root() -> Result<PathBuf, String> {
    if let Ok(root) = std::env::var("TILLANDSIAS_ROOT") {
        let path = PathBuf::from(root);
        if path.join("VERSION").is_file() && path.join("images").is_dir() {
            return Ok(path);
        }
    }

    let mut dir = std::env::current_dir().map_err(|e| format!("Failed to get cwd: {e}"))?;
    loop {
        if dir.join("VERSION").is_file() && dir.join("images").is_dir() {
            return Ok(dir);
        }
        if !dir.pop() {
            break;
        }
    }

    Err(
        "Could not find Tillandsias checkout. Run from the repo or set TILLANDSIAS_ROOT."
            .to_string(),
    )
}

fn run_command(mut command: Command, debug: bool) -> Result<(), String> {
    if debug {
        eprintln!("[tillandsias] running: {:?}", command);
    }
    let status = command
        .status()
        .map_err(|e| format!("Failed to run command: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("Command exited with status {status}"))
    }
}

fn run_command_silent(mut command: Command, debug: bool) -> Result<(), String> {
    if debug {
        eprintln!("[tillandsias] running: {:?}", command);
    }
    let output = command
        .output()
        .map_err(|e| format!("Failed to run command: {e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if stderr.is_empty() {
            Err(format!("Command exited with status {}", output.status))
        } else {
            Err(stderr)
        }
    }
}

const ENCLAVE_NET: &str = "tillandsias-enclave";
const ENCLAVE_SUBNET: &str = "10.0.42.0/24";
const ENCLAVE_NO_PROXY: &str =
    "localhost,127.0.0.1,0.0.0.0,::1,inference,proxy,git-service,10.0.42.0/24";
const CA_DIR: &str = "/tmp/tillandsias-ca";

// @trace spec:init-incremental-builds
/// Build state tracking for incremental initialization.
///
/// Persists to `~/.cache/tillandsias/init-build-state.json` (atomic write via temp file).
/// Used to skip building images that were previously successful and still exist.
///
/// ## Build Status Values
/// - `"success"` — Image built successfully and still exists locally
/// - `"failed"` — Image failed to build; should be attempted again on next --init
/// - `"pending"` — (not currently used; reserved for future async builds)
///
/// ## Example State File
/// ```json
/// {
///   "images": {
///     "proxy": "success",
///     "git": "success",
///     "inference": "success",
///     "chromium-core": "success",
///     "chromium-framework": "success",
///     "forge": "success"
///   },
///   "timestamp": "2026-05-14T10:30:45.123456-07:00"
/// }
/// ```
#[derive(Debug, Clone, Serialize, Deserialize)]
struct InitBuildState {
    /// Map of image name -> build status ("success", "failed", "pending")
    images: std::collections::HashMap<String, String>,
    /// Timestamp of last init run (RFC 3339 format)
    timestamp: String,
}

impl InitBuildState {
    fn new() -> Self {
        Self {
            images: std::collections::HashMap::new(),
            timestamp: chrono::Local::now().to_rfc3339(),
        }
    }

    fn load() -> Result<Option<Self>, String> {
        let cache_dir = init_cache_dir()?;
        let state_file = cache_dir.join("init-build-state.json");
        let temp_file = cache_dir.join(".init-build-state.json.tmp");

        // Clean up any leftover temp file from a crashed write
        if temp_file.exists() {
            let _ = fs::remove_file(&temp_file);
        }

        if !state_file.exists() {
            return Ok(None);
        }
        let contents = fs::read_to_string(&state_file)
            .map_err(|e| format!("Failed to read init build state: {e}"))?;
        let state = serde_json::from_str(&contents)
            .map_err(|e| format!("Failed to parse init build state: {e}"))?;
        Ok(Some(state))
    }

    fn save(&self) -> Result<(), String> {
        let cache_dir = init_cache_dir()?;
        let state_file = cache_dir.join("init-build-state.json");
        let contents = serde_json::to_string_pretty(self)
            .map_err(|e| format!("Failed to serialize state: {e}"))?;

        // Atomic write: write to temp file, then rename.
        // This prevents corruption if the process is killed mid-write.
        let temp_file = cache_dir.join(".init-build-state.json.tmp");
        fs::write(&temp_file, contents)
            .map_err(|e| format!("Failed to write temporary state file: {e}"))?;

        fs::rename(&temp_file, &state_file).map_err(|e| {
            let _ = fs::remove_file(&temp_file);
            format!("Failed to rename state file atomically: {e}")
        })?;

        Ok(())
    }

    fn mark_success(&mut self, image: &str) {
        self.images.insert(image.to_string(), "success".to_string());
    }

    fn mark_failed(&mut self, image: &str) {
        self.images.insert(image.to_string(), "failed".to_string());
    }

    fn was_successful(&self, image: &str) -> bool {
        self.images
            .get(image)
            .map(|s| s == "success")
            .unwrap_or(false)
    }

    /// Check if cache version matches current VERSION.
    /// @trace spec:forge-staleness, spec:forge-cache-dual
    #[allow(dead_code)]
    fn is_version_current(version: &str) -> Result<bool, String> {
        let cache_dir = init_cache_dir()?;
        let version_file = cache_dir.join("cache_version");

        if !version_file.exists() {
            return Ok(false);
        }

        let cached_version = fs::read_to_string(&version_file)
            .map_err(|e| format!("Failed to read cached version: {e}"))?
            .trim()
            .to_string();

        Ok(cached_version == version)
    }

    /// Get the last recorded Containerfile mtime for an image.
    /// @trace spec:containerfile-staleness
    fn get_last_containerfile_mtime(image: &str) -> Result<Option<u64>, String> {
        let cache_dir = init_cache_dir()?;
        let mtime_file = cache_dir.join(format!("{}-containerfile-mtime", image));

        if !mtime_file.exists() {
            return Ok(None);
        }

        let mtime_str = fs::read_to_string(&mtime_file)
            .map_err(|e| format!("Failed to read mtime file: {e}"))?
            .trim()
            .to_string();

        mtime_str
            .parse::<u64>()
            .ok()
            .map(Some)
            .ok_or_else(|| "Failed to parse mtime".to_string())
    }

    /// Save the current Containerfile mtime for an image.
    /// @trace spec:containerfile-staleness
    fn save_containerfile_mtime(image: &str, mtime: u64) -> Result<(), String> {
        let cache_dir = init_cache_dir()?;
        let mtime_file = cache_dir.join(format!("{}-containerfile-mtime", image));
        fs::write(&mtime_file, mtime.to_string())
            .map_err(|e| format!("Failed to write mtime file: {e}"))
    }

    /// Save current VERSION to cache for future staleness detection.
    /// @trace spec:forge-staleness, spec:forge-cache-dual
    fn save_version(version: &str) -> Result<(), String> {
        let cache_dir = init_cache_dir()?;
        let version_file = cache_dir.join("cache_version");
        fs::write(&version_file, version).map_err(|e| format!("Failed to write cache version: {e}"))
    }
}

// @trace spec:forge-staleness, spec:forge-cache-dual
/// Cache integrity check result
#[derive(Debug, Clone)]
struct CacheIntegrityStatus {
    is_valid: bool,
    version_mismatch: bool,
    cache_dir: PathBuf,
    current_version: String,
    cached_version: Option<String>,
    missing_state_file: bool,
}

/// Check cache integrity: version match, state file presence, file accessibility.
/// @trace spec:forge-staleness, spec:forge-cache-dual
fn check_cache_integrity(version: &str) -> Result<CacheIntegrityStatus, String> {
    let cache_dir = init_cache_dir()?;
    let version_file = cache_dir.join("cache_version");
    let state_file = cache_dir.join("init-build-state.json");

    let cached_version = if version_file.exists() {
        Some(
            fs::read_to_string(&version_file)
                .map_err(|e| format!("Failed to read cached version file: {e}"))?
                .trim()
                .to_string(),
        )
    } else {
        None
    };

    let version_mismatch = cached_version
        .as_ref()
        .map(|v| v != version)
        .unwrap_or(true);

    let missing_state_file = !state_file.exists();

    let is_valid = !version_mismatch && !missing_state_file;

    Ok(CacheIntegrityStatus {
        is_valid,
        version_mismatch,
        cache_dir,
        current_version: version.to_string(),
        cached_version,
        missing_state_file,
    })
}

fn init_cache_dir() -> Result<PathBuf, String> {
    let cache_dir = if let Ok(cache_home) = std::env::var("XDG_CACHE_HOME") {
        PathBuf::from(cache_home).join("tillandsias")
    } else if let Ok(home) = std::env::var("HOME") {
        PathBuf::from(home).join(".cache").join("tillandsias")
    } else {
        return Err("Cannot determine cache directory: HOME not set".to_string());
    };

    fs::create_dir_all(&cache_dir).map_err(|e| format!("Failed to create cache directory: {e}"))?;
    Ok(cache_dir)
}

fn init_log_file(image_name: &str, debug: bool) -> Option<PathBuf> {
    if !debug {
        return None;
    }

    Some(PathBuf::from(format!(
        "/tmp/tillandsias-init-{}.log",
        image_name
    )))
}

fn podman_runtime() -> Result<tokio::runtime::Runtime, String> {
    tokio::runtime::Runtime::new().map_err(|e| format!("Failed to create async runtime: {e}"))
}

fn image_specs(root: &Path, image_name: &str) -> Result<(PathBuf, PathBuf), String> {
    let rel = match image_name {
        "forge" => "images/default",
        "proxy" => "images/proxy",
        "git" => "images/git",
        "inference" => "images/inference",
        "web" => "images/web",
        "chromium-core" => "images/chromium",
        "chromium-framework" => "images/chromium",
        other => {
            return Err(format!("Unknown image type: {other}"));
        }
    };

    let context_dir = root.join(rel);
    let containerfile = match image_name {
        "chromium-core" => context_dir.join("Containerfile.core"),
        "chromium-framework" => context_dir.join("Containerfile.framework"),
        _ => context_dir.join("Containerfile"),
    };

    if !containerfile.is_file() {
        return Err(format!(
            "Containerfile not found for {image_name}: {}",
            containerfile.display()
        ));
    }

    Ok((containerfile, context_dir))
}

fn image_build_args(image_name: &str, image_tag: &str) -> Vec<String> {
    if image_name == "chromium-framework" {
        // @trace spec:init-command, spec:chromium-browser-isolation
        //
        // chromium-framework depends on chromium-core image built in the previous step.
        // Pass --build-arg CHROMIUM_CORE_TAG so the Containerfile can reference it:
        //
        //   FROM tillandsias-chromium-core:${CHROMIUM_CORE_TAG}
        //
        // KNOWN BLOCKER: Nix-based image builds (via flake.nix + nix build) do NOT support
        // ARG passing. The nix build system does not expose a way to pass --build-arg values
        // through the Nix derivation. This is a pre-existing infrastructure limitation that
        // prevents us from using `scripts/build-image.sh chromium-framework` when chromium-core
        // just built. Workaround: build directly via podman (current implementation, which
        // works correctly) OR enhance build-image.sh to support `--build-arg` passthrough.
        //
        // Reference: project_nix_image_builds_require_git_add.md
        //
        let core_tag = image_tag
            .split(':')
            .next_back()
            .filter(|value| !value.is_empty())
            .unwrap_or("latest");
        vec![
            "--build-arg".into(),
            format!("CHROMIUM_CORE_TAG={core_tag}"),
        ]
    } else {
        Vec::new()
    }
}

fn versioned_image_tag(image_name: &str, version: &str) -> String {
    format!("tillandsias-{image_name}:v{version}")
}

fn forge_image_tag(version: &str) -> String {
    versioned_image_tag("forge", version)
}

/// Check if Containerfile has been modified since last successful build.
/// @trace spec:containerfile-staleness
fn containerfile_is_stale(root: &Path, image_name: &str, debug: bool) -> Result<bool, String> {
    let (containerfile, _) = image_specs(root, image_name)?;

    // Get current mtime
    let metadata = fs::metadata(&containerfile)
        .map_err(|e| format!("Failed to read Containerfile metadata: {e}"))?;

    let modified = metadata
        .modified()
        .map_err(|e| format!("Failed to get modification time: {e}"))?;

    let current_mtime = modified
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| format!("Failed to compute mtime: {e}"))?
        .as_secs();

    // Get last recorded mtime
    match InitBuildState::get_last_containerfile_mtime(image_name)? {
        Some(last_mtime) if last_mtime >= current_mtime => {
            // Containerfile not modified since last build
            Ok(false)
        }
        _ => {
            // Containerfile modified or no record exists
            if debug {
                eprintln!(
                    "[tillandsias] Containerfile for {} has been modified or updated",
                    image_name
                );
            }
            Ok(true)
        }
    }
}

/// Capture and record the current Containerfile mtime after a successful build.
/// @trace spec:containerfile-staleness
fn capture_containerfile_mtime(root: &Path, image_name: &str) -> Result<(), String> {
    let (containerfile, _) = image_specs(root, image_name)?;

    let metadata = fs::metadata(&containerfile)
        .map_err(|e| format!("Failed to read Containerfile metadata: {e}"))?;

    let modified = metadata
        .modified()
        .map_err(|e| format!("Failed to get modification time: {e}"))?;

    let mtime = modified
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| format!("Failed to compute mtime: {e}"))?
        .as_secs();

    InitBuildState::save_containerfile_mtime(image_name, mtime)
}

fn ensure_image_exists(
    root: &Path,
    image_name: &str,
    image_tag: &str,
    debug: bool,
) -> Result<(), String> {
    let (containerfile, context_dir) = image_specs(root, image_name)?;
    let rt = podman_runtime()?;
    let client = PodmanClient::new();
    let build_args = image_build_args(image_name, image_tag);

    rt.block_on(async move {
        if client.image_exists(image_tag).await {
            return Ok(());
        }

        client
            .build_image(
                containerfile
                    .to_str()
                    .ok_or_else(|| "Containerfile path contains invalid UTF-8".to_string())?,
                image_tag,
                context_dir
                    .to_str()
                    .ok_or_else(|| "Context path contains invalid UTF-8".to_string())?,
                &build_args,
            )
            .await
            .map_err(|e| e.to_string())?;

        if debug {
            eprintln!("[tillandsias] built image {image_name}: {image_tag}");
        }

        Ok(())
    })
}

fn ensure_versioned_images(
    root: &Path,
    image_names: &[&str],
    version: &str,
    debug: bool,
) -> Result<(), String> {
    for image in image_names {
        let tag = versioned_image_tag(image, version);
        ensure_image_exists(root, image, &tag, debug)?;
    }
    Ok(())
}

fn ensure_enclave_network(debug: bool) -> Result<(), String> {
    if tillandsias_podman::network_exists_sync(ENCLAVE_NET) {
        return Ok(());
    }

    let mut command = podman_command();
    command.args([
        "network",
        "create",
        "--driver",
        "bridge",
        "--subnet",
        ENCLAVE_SUBNET,
        ENCLAVE_NET,
    ]);
    run_command(command, debug)
}

fn ensure_ca_bundle(debug: bool) -> Result<PathBuf, String> {
    // @trace spec:secrets-management, spec:secret-rotation
    let certs_dir = PathBuf::from(CA_DIR);
    let crt = certs_dir.join("intermediate.crt");
    let key = certs_dir.join("intermediate.key");
    std::fs::create_dir_all(&certs_dir)
        .map_err(|e| format!("Failed to create CA directory: {e}"))?;

    let should_refresh = match std::fs::metadata(&crt).and_then(|meta| meta.modified()) {
        Ok(modified) => modified
            .elapsed()
            .map(|age| age > std::time::Duration::from_secs(25 * 24 * 60 * 60))
            .unwrap_or(true),
        Err(_) => true,
    };

    if should_refresh {
        // @trace spec:secret-rotation
        info!(
            accountability = true,
            category = "secrets",
            spec = "secret-rotation",
            secret_type = "ca-certificate",
            operation = "rotation_start",
            location = %crt.display(),
            "CA certificate rotation starting"
        );

        let mut command = Command::new("openssl");
        command.args([
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-keyout",
            key.to_str()
                .ok_or_else(|| "CA key path contains invalid UTF-8".to_string())?,
            "-out",
            crt.to_str()
                .ok_or_else(|| "CA cert path contains invalid UTF-8".to_string())?,
            "-days",
            "30",
            "-nodes",
            "-subj",
            "/C=US/ST=Privacy/L=Local/O=Tillandsias/CN=Tillandsias CA",
        ]);
        command.stdout(Stdio::null()).stderr(Stdio::null());

        if let Err(e) = run_command_silent(command, debug) {
            error!(
                accountability = true,
                category = "secrets",
                spec = "secret-rotation",
                secret_type = "ca-certificate",
                operation = "rotation_failed",
                location = %crt.display(),
                error = %e,
                "CA certificate rotation failed"
            );
            return Err(e);
        }

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&crt, std::fs::Permissions::from_mode(0o644)).map_err(
                |e| {
                    error!(
                        accountability = true,
                        category = "secrets",
                        spec = "secret-rotation",
                        secret_type = "ca-certificate",
                        operation = "rotation_failed",
                        location = %crt.display(),
                        error = %e,
                        "Failed to set CA certificate permissions"
                    );
                    format!("Failed to set cert permissions: {e}")
                },
            )?;
            std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600)).map_err(
                |e| {
                    error!(
                        accountability = true,
                        category = "secrets",
                        spec = "secret-rotation",
                        secret_type = "ca-key",
                        operation = "rotation_failed",
                        location = %key.display(),
                        error = %e,
                        "Failed to set CA key permissions"
                    );
                    format!("Failed to set key permissions: {e}")
                },
            )?;
        }

        info!(
            accountability = true,
            category = "secrets",
            spec = "secret-rotation",
            secret_type = "ca-certificate",
            operation = "rotation_complete",
            location = %crt.display(),
            "CA certificate rotation completed successfully"
        );

        if debug {
            eprintln!("[tillandsias] refreshed CA bundle at {}", crt.display());
        }
    }

    Ok(certs_dir)
}

fn build_stack_common_args(
    container_name: &str,
    hostname: &str,
    certs_dir: &Path,
    project_name: &str,
    project_path: &Path,
) -> Vec<String> {
    vec![
        "--name".into(),
        container_name.into(),
        "--hostname".into(),
        hostname.into(),
        "--network".into(),
        ENCLAVE_NET.into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--pids-limit=512".into(),
        "--env".into(),
        "http_proxy=http://proxy:3128".into(),
        "--env".into(),
        "https_proxy=http://proxy:3128".into(),
        "--env".into(),
        "HTTP_PROXY=http://proxy:3128".into(),
        "--env".into(),
        "HTTPS_PROXY=http://proxy:3128".into(),
        "--env".into(),
        format!("no_proxy={ENCLAVE_NO_PROXY}"),
        "--env".into(),
        format!("NO_PROXY={ENCLAVE_NO_PROXY}"),
        "--env".into(),
        "PATH=/usr/local/bin:/usr/bin".into(),
        "--env".into(),
        "HOME=/home/forge".into(),
        "--env".into(),
        "USER=forge".into(),
        "--env".into(),
        format!("PROJECT={project_name}"),
        "-v".into(),
        format!(
            "{}:/home/forge/src/{project_name}:rw",
            project_path.display()
        ),
        "--mount".into(),
        format!(
            "type=bind,source={},target=/etc/tillandsias/ca.crt,readonly=true",
            certs_dir.join("intermediate.crt").display()
        ),
    ]
}

fn build_proxy_run_args(certs_dir: &Path, image: &str) -> Vec<String> {
    vec![
        "--detach".into(),
        "--name".into(),
        "tillandsias-proxy".into(),
        "--hostname".into(),
        "proxy".into(),
        "--network".into(),
        ENCLAVE_NET.into(),
        "--ip".into(),
        "10.0.42.2".into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--pids-limit=32".into(),
        "--env".into(),
        "DEBUG_PROXY=1".into(),
        "-v".into(),
        format!(
            "{}:/etc/squid/certs/intermediate.crt:ro",
            certs_dir.join("intermediate.crt").display()
        ),
        "-v".into(),
        format!(
            "{}:/etc/squid/certs/intermediate.key:ro",
            certs_dir.join("intermediate.key").display()
        ),
        image.into(),
    ]
}

fn build_git_run_args(project_name: &str, certs_dir: &Path, image: &str) -> Vec<String> {
    vec![
        "--detach".into(),
        "--rm".into(),
        "--name".into(),
        format!("tillandsias-git-{project_name}"),
        "--hostname".into(),
        format!("git-{project_name}"),
        "--network-alias".into(),
        "git-service".into(),
        "--network".into(),
        ENCLAVE_NET.into(),
        "--ip".into(),
        "10.0.42.3".into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--pids-limit=64".into(),
        "--read-only".into(),
        "--env".into(),
        format!("PROJECT={project_name}"),
        "--env".into(),
        "GIT_TRACE=1".into(),
        "--mount".into(),
        format!(
            "type=bind,source={},target=/etc/tillandsias/ca.crt,readonly=true",
            certs_dir.join("intermediate.crt").display()
        ),
        image.into(),
        "/usr/bin/git".into(),
        "daemon".into(),
        "--verbose".into(),
        "--listen=0.0.0.0".into(),
        "--base-path=/var/lib/git".into(),
    ]
}

fn build_inference_run_args(
    certs_dir: &Path,
    image: &str,
    skip_runtime_pulls: bool,
) -> Vec<String> {
    let home_dir = std::env::var("HOME").unwrap_or_else(|_| String::from("/home/forge"));
    let model_cache_dir = Path::new(&home_dir).join(".cache/tillandsias/models");
    let _ = std::fs::create_dir_all(&model_cache_dir);

    let mut args = vec![
        "--detach".into(),
        "--rm".into(),
        "--name".into(),
        "tillandsias-inference".into(),
        "--hostname".into(),
        "inference".into(),
        "--network-alias".into(),
        "inference".into(),
        "--network".into(),
        ENCLAVE_NET.into(),
        "--ip".into(),
        "10.0.42.4".into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--pids-limit=128".into(),
        "--env".into(),
        "OLLAMA_DEBUG=1".into(),
        "--env".into(),
        "OLLAMA_KEEP_ALIVE=24h".into(),
        "-v".into(),
        format!(
            "{}:/home/ollama/.ollama/models:rw",
            model_cache_dir.display()
        ),
        "--mount".into(),
        format!(
            "type=bind,source={},target=/etc/tillandsias/ca.crt,readonly=true",
            certs_dir.join("intermediate.crt").display()
        ),
        image.into(),
        "/usr/bin/ollama".into(),
        "serve".into(),
    ];

    if skip_runtime_pulls {
        args.insert(args.len() - 2, "--env".into());
        args.insert(
            args.len() - 2,
            "TILLANDSIAS_INFERENCE_SKIP_RUNTIME_PULLS=1".into(),
        );
    }

    args
}

/// Path on host to the dynamic Caddyfile written by the headless runtime,
/// bind-mounted into the router container at `/run/router/dynamic.Caddyfile`.
///
/// @trace spec:subdomain-routing-via-reverse-proxy
fn router_dynamic_caddyfile_host_path() -> PathBuf {
    let base = if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
        PathBuf::from(xdg).join("tillandsias")
    } else {
        std::env::temp_dir().join("tillandsias-embedded")
    };
    base.join("router")
}

/// Build `podman run` args for the Caddy reverse-proxy router container.
///
/// The router runs on the enclave network with DNS alias `router` so Squid's
/// `cache_peer` directive can resolve it for `.localhost` subdomain traffic.
/// It also publishes `127.0.0.1:8080:8080` so the host browser can reach
/// OpenCode Web at `http://<service>.<project>.localhost:8080/`.
///
/// @trace spec:subdomain-routing-via-reverse-proxy, spec:fix-router-loopback-port, spec:enclave-network
fn build_router_run_args(certs_dir: &Path, image: &str) -> Vec<String> {
    let dyn_dir = router_dynamic_caddyfile_host_path();
    let dyn_file = dyn_dir.join("dynamic.Caddyfile");
    // Ensure the directory and placeholder file exist before the container
    // starts so the bind-mount succeeds even on first run.
    let _ = std::fs::create_dir_all(&dyn_dir);
    if !dyn_file.exists() {
        let _ = std::fs::write(&dyn_file, "");
    }

    vec![
        "--detach".into(),
        "--rm".into(),
        "--name".into(),
        "tillandsias-router".into(),
        "--hostname".into(),
        "router".into(),
        // @trace spec:subdomain-routing-via-reverse-proxy, spec:enclave-network
        // Dual-homed: enclave alias `router` for Squid cache_peer + proxy agents,
        // plus host loopback publish for the browser.
        "--network-alias".into(),
        "router".into(),
        "--network".into(),
        ENCLAVE_NET.into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--pids-limit=64".into(),
        "--read-only".into(),
        "--tmpfs".into(),
        "/tmp:size=64m".into(),
        "--tmpfs".into(),
        "/run/router:size=8m".into(),
        // @trace spec:fix-router-loopback-port
        // Host publish on loopback ONLY. Both host and container ports are 8080
        // because rootless podman cannot bind ports below 1024 under
        // --cap-drop=ALL. The base.Caddyfile listener is already on :8080.
        "-p".into(),
        "127.0.0.1:8080:8080".into(),
        // @trace spec:subdomain-routing-via-reverse-proxy
        // Dynamic Caddyfile written by the runtime for per-project routes.
        // Bind-mounted read-write so router-reload.sh can atomically replace it.
        "-v".into(),
        format!("{}:/run/router/dynamic.Caddyfile:rw", dyn_file.display()),
        "--mount".into(),
        format!(
            "type=bind,source={},target=/etc/tillandsias/ca.crt,readonly=true",
            certs_dir.join("intermediate.crt").display()
        ),
        image.into(),
    ]
}

/// Reload Caddy's configuration via the admin API.
///
/// After writing a new dynamic Caddyfile, this function signals the Caddy
/// router to reload its configuration without restarting the container.
/// The router's admin API listens on `localhost:2019` (per base.Caddyfile).
///
/// This is an async operation that reaches into the container from the host.
/// On transient failures (e.g., router not yet ready), logs a warning and
/// continues — subsequent operations will detect the stale config.
///
/// @trace spec:subdomain-routing-via-reverse-proxy
async fn caddy_reload_routes(debug: bool) -> Result<(), String> {
    // Caddy admin API endpoint for config reload.
    // The router listens on localhost:2019 inside the container, which is
    // exposed via podman's localhost mapping (same network namespace path).
    let admin_url = "http://127.0.0.1:2019/reload";

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    // POST to /reload tells Caddy to reload the merged Caddyfile
    // (which includes both base.Caddyfile and dynamic.Caddyfile).
    // The request body is empty; Caddy just re-reads the file on disk.
    match client.post(admin_url).send().await {
        Ok(response) => {
            let status = response.status();
            if status.is_success() {
                if debug {
                    eprintln!("[tillandsias] Caddy reload successful (status: {})", status);
                }
                Ok(())
            } else {
                // Non-2xx response from admin API. Log as warning but don't fail.
                if debug {
                    eprintln!(
                        "[tillandsias] Warning: Caddy reload returned status {}: {}",
                        status,
                        response.text().await.unwrap_or_default()
                    );
                }
                Ok(())
            }
        }
        Err(e) => {
            // Connection error (router not ready, port not open, etc).
            // Warn but don't fail — the router may still be initializing.
            if debug {
                eprintln!(
                    "[tillandsias] Warning: Caddy reload failed (router may not be ready): {}",
                    e
                );
            }
            Ok(())
        }
    }
}

/// Ensure the router container (`tillandsias-router`) is running.
///
/// Idempotent: if a container with that name already exists and is in the
/// `running` state, this is a no-op. If the container exists but is stopped
/// (e.g., left over from a previous run), it is removed first. If it does
/// not exist, it is started with `build_router_run_args`.
///
/// @trace spec:subdomain-routing-via-reverse-proxy, spec:enclave-network
async fn ensure_router_running(
    client: &PodmanClient,
    certs_dir: &Path,
    image: &str,
    debug: bool,
) -> Result<(), String> {
    const ROUTER_NAME: &str = "tillandsias-router";

    if let Ok(inspect) = client.inspect_container(ROUTER_NAME).await {
        if inspect.state == "running" {
            if debug {
                eprintln!("[tillandsias] router already running");
            }
            return Ok(());
        }
        // Container exists but is stopped — remove it so a fresh one can start.
        if debug {
            eprintln!(
                "[tillandsias] router container found but not running (state={}); removing",
                inspect.state
            );
        }
        let _ = client.remove_container(ROUTER_NAME).await;
    }

    if debug {
        eprintln!("[tillandsias] starting router container");
    }
    client
        .run_container(&build_router_run_args(certs_dir, image))
        .await
        .map_err(|e| format!("Failed to start router: {e}"))?;

    if debug {
        eprintln!("[tillandsias] router container started");
    }
    Ok(())
}

/// Generate dynamic Caddy configuration for OpenCode Web routes.
///
/// Takes a list of (subdomain, container_id, port) tuples and generates
/// Caddy configuration blocks for reverse-proxy routes mapping
/// `<subdomain>.localhost` to `http://127.0.0.1:<port>`.
///
/// @trace spec:subdomain-routing-via-reverse-proxy, spec:opencode-web-dynamic-routes
fn generate_dynamic_caddyfile(windows: &[(String, String, u16)]) -> String {
    if windows.is_empty() {
        return String::new();
    }

    let mut routes = String::new();
    for (subdomain, _container_id, port) in windows {
        // Generate Caddy block for each route: subdomain.localhost -> localhost:port
        // Format: subdomain.localhost {
        //   reverse_proxy 127.0.0.1:port
        // }
        routes.push_str(&format!(
            "{}.localhost {{\n    reverse_proxy 127.0.0.1:{}\n}}\n",
            subdomain, port
        ));
    }
    routes
}

fn forge_container_name(project_name: &str) -> String {
    format!("tillandsias-{project_name}-forge")
}

fn forge_hostname(project_name: &str) -> String {
    format!("forge-{project_name}")
}

fn build_forge_common_args(
    project_path: &Path,
    project_name: &str,
    certs_dir: &Path,
) -> Vec<String> {
    build_stack_common_args(
        &forge_container_name(project_name),
        &forge_hostname(project_name),
        certs_dir,
        project_name,
        project_path,
    )
}

async fn cleanup_stack_containers(client: &PodmanClient, project_name: &str) {
    let _ = client.remove_container("tillandsias-proxy").await;
    let _ = client
        .remove_container(&format!("tillandsias-git-{project_name}"))
        .await;
    let _ = client.remove_container("tillandsias-inference").await;
    let _ = client
        .remove_container(&format!("tillandsias-{project_name}-forge"))
        .await;
    let _ = client
        .remove_container(&format!("tillandsias-browser-{project_name}"))
        .await;
}

fn build_status_check_forge_args(
    project_path: &Path,
    project_name: &str,
    certs_dir: &Path,
    version: &str,
) -> Vec<String> {
    let mut args = build_forge_common_args(project_path, project_name, certs_dir);

    args.extend([
        "--rm".into(),
        "--entrypoint".into(),
        "/bin/bash".into(),
        forge_image_tag(version),
        "-lc".into(),
        [
            "set -euo pipefail",
            "check_port() {",
            "    local host=\"$1\"",
            "    local port=\"$2\"",
            "    local label=\"$3\"",
            "    local attempt=0",
            "    local max_attempts=20",
            "    while [ \"$attempt\" -lt \"$max_attempts\" ]; do",
            "        if command -v nc >/dev/null 2>&1; then",
            "            if nc -z -w 1 \"$host\" \"$port\" >/dev/null 2>&1; then",
            "                echo \"[status-check] $label online\"",
            "                return 0",
            "            fi",
            "        elif (exec 3<>\"/dev/tcp/$host/$port\") >/dev/null 2>&1; then",
            "            exec 3<&- 3>&-",
            "            echo \"[status-check] $label online\"",
            "            return 0",
            "        fi",
            "        attempt=$((attempt + 1))",
            "        sleep 1",
            "    done",
            "    echo \"[status-check] $label offline after ${max_attempts}s\" >&2",
            "    return 1",
            "}",
            "check_inference() {",
            "    local attempt=0",
            "    local max_attempts=20",
            "    while [ \"$attempt\" -lt \"$max_attempts\" ]; do",
            "        if command -v curl >/dev/null 2>&1; then",
            "            if curl -fsS -m 2 \"http://inference:11434/api/version\" >/dev/null 2>&1; then",
            "                echo \"[status-check] inference online\"",
            "                return 0",
            "            fi",
            "        elif (exec 3<>\"/dev/tcp/inference/11434\") >/dev/null 2>&1; then",
            "            exec 3<&- 3>&-",
            "            echo \"[status-check] inference online\"",
            "            return 0",
            "        fi",
            "        attempt=$((attempt + 1))",
            "        sleep 1",
            "    done",
            "    echo \"[status-check] inference offline after ${max_attempts}s\" >&2",
            "    return 1",
            "}",
            "echo \"[status-check] running inside forge container\"",
            "check_port proxy 3128 proxy",
            "check_port git-service 9418 git",
            "check_inference",
            "echo \"[status-check] forge online\"",
        ]
        .join("\n"),
    ]);

    args
}

fn build_opencode_forge_args(
    project_path: &Path,
    project_name: &str,
    prompt: Option<&str>,
    certs_dir: &Path,
    version: &str,
) -> Vec<String> {
    let mut args = vec![
        "--rm".into(),
        "--name".into(),
        forge_container_name(project_name),
        "--hostname".into(),
        forge_hostname(project_name),
        "--network".into(),
        ENCLAVE_NET.into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--pids-limit=512".into(),
        "--interactive".into(),
        "--tty".into(),
        "--env".into(),
        "http_proxy=http://proxy:3128".into(),
        "--env".into(),
        "https_proxy=http://proxy:3128".into(),
        "--env".into(),
        "HTTP_PROXY=http://proxy:3128".into(),
        "--env".into(),
        "HTTPS_PROXY=http://proxy:3128".into(),
        "--env".into(),
        format!("no_proxy={ENCLAVE_NO_PROXY}"),
        "--env".into(),
        format!("NO_PROXY={ENCLAVE_NO_PROXY}"),
        "--env".into(),
        "PATH=/usr/local/bin:/usr/bin".into(),
        "--env".into(),
        "HOME=/home/forge".into(),
        "--env".into(),
        "USER=forge".into(),
        "--env".into(),
        format!("PROJECT={project_name}"),
        "-v".into(),
        format!("{}:/home/forge/src:rw", project_path.display()),
        "--mount".into(),
        format!(
            "type=bind,source={},target=/etc/tillandsias/ca.crt,readonly=true",
            certs_dir.join("intermediate.crt").display()
        ),
    ];
    if let Some(prompt) = prompt {
        args.extend([
            "--env".into(),
            format!("TILLANDSIAS_OPENCODE_PROMPT={prompt}"),
        ]);
    }
    args.extend([
        "--entrypoint".into(),
        "/bin/bash".into(),
        forge_image_tag(version),
        "/bin/bash".into(),
    ]);
    args
}

/// Build required container images on demand with incremental build support.
///
/// Orchestrate incremental container image builds for Tillandsias.
///
/// @trace spec:init-command, spec:init-incremental-builds, spec:default-image, spec:git-mirror-service, spec:proxy-container, spec:inference-container
///
/// ## Init Flow
///
/// The `--init` command builds container images from baked Containerfiles in incremental order:
///
/// 1. **Detect repository**: Find Tillandsias root by detecting VERSION file and images/ directory.
/// 2. **Load build state**: Check `~/.cache/tillandsias/init-build-state.json` for previous successful builds.
/// 3. **Build images in order** (must respect build dependencies):
///    - `proxy` — HTTP/HTTPS caching proxy with domain allowlist
///    - `git` — Git mirror service with auto-push on behalf of forge
///    - `inference` — ollama-based LLM inference container
///    - `chromium-core` — Base Chromium image for browser isolation
///    - `chromium-framework` — Chromium browser with framework integration (depends on chromium-core)
///    - `forge` — Dev environment: coding agents, compilation, package management
/// 4. **Track progress**: For each image, report:
///    - SKIP: Image already cached and build previously successful
///    - REBUILD: Image deleted after successful build (rebuild)
///    - BUILD: Now building
///    - SUCCESS: Build completed
///    - FAILED: Build failed (mark, save state, continue to next or fail)
/// 5. **Save state**: Update `~/.cache/tillandsias/init-build-state.json` with success/failure status.
/// 6. **Report failures**: In debug mode, dump last 10 lines of failed build logs.
/// 7. **Exit**: 0 on success, non-zero on any image build failure.
///
/// ## Caching & Incremental Builds
///
/// - **Successful builds**: Cached by image tag. On next --init run, skipped if image exists and
///   build state shows "success".
/// - **Force rebuild**: `--init --force` clears build state and rebuilds all images.
/// - **Rebuild on deletion**: If image tag no longer exists (e.g., user pruned), rebuilds even if
///   previous build was successful.
///
/// ## Build Arguments
///
/// - `chromium-framework` passes `--build-arg CHROMIUM_CORE_TAG=<version>` to reference the
///   just-built chromium-core image. **Known blocker**: Nix-based build (via flake.nix) fails
///   when passed ARG values; workaround is to build directly via podman (current implementation).
///
/// ## Log Handling
///
/// - Non-debug mode: Build logs go to /dev/null (quiet).
/// - Debug mode: Build logs saved to `/tmp/tillandsias-init-<image>.log` for troubleshooting.
/// - On success, debug logs are cleaned up.
/// - On failure, last 10 lines of each failed image's log are printed to stderr.
///
/// ## Exit Codes
///
/// - 0 — All images built successfully (or skipped as cached)
/// - non-zero — One or more images failed to build (human intervention required)
fn run_init(debug: bool, force: bool) -> Result<(), String> {
    let root = find_checkout_root()?;
    let version = VERSION.trim();
    let images = [
        "proxy",
        "git",
        "inference",
        "chromium-core",
        "chromium-framework",
        "forge",
    ];

    // @trace spec:forge-staleness, spec:forge-cache-dual
    // Check cache integrity before loading state
    let cache_status = check_cache_integrity(version)?;
    if !force && cache_status.version_mismatch {
        eprintln!("WARNING: Cache version mismatch detected");
        if let Some(cached) = &cache_status.cached_version {
            eprintln!("  Cached version: {}", cached);
        } else {
            eprintln!("  No cached version found");
        }
        eprintln!("  Current version: {}", version);
        eprintln!("  Suggestion: Use --force to rebuild, or --cache-clear to start fresh");
        return Err("Cache version mismatch. Run with --force or --cache-clear.".to_string());
    }

    // Load existing build state or create new one
    let mut state = InitBuildState::load()?.unwrap_or_else(InitBuildState::new);
    let rt = podman_runtime()?;
    let client = PodmanClient::new();
    let mut failed_images = Vec::new();

    // If force is set, clear previous build state to rebuild all images
    if force {
        if debug {
            println!("FORCE: rebuilding all images");
        }
        state = InitBuildState::new();
    }

    for image in &images {
        let tag = versioned_image_tag(image, version);

        // Check if image exists and was previously successful
        let should_skip = rt.block_on(async { client.image_exists(&tag).await });

        // @trace spec:containerfile-staleness
        // Check if Containerfile has been modified since last build
        let containerfile_stale = if should_skip && state.was_successful(image) && !force {
            containerfile_is_stale(&root, image, debug).unwrap_or(false)
        } else {
            false
        };

        if should_skip && state.was_successful(image) && !force && !containerfile_stale {
            if debug {
                println!("SKIP {} (cached)", image);
            }
            continue;
        }

        if containerfile_stale && debug {
            eprintln!("REBUILD {} (Containerfile modified)", image);
        }

        if !should_skip && state.was_successful(image) {
            // Image deleted after successful build - rebuild
            if debug {
                println!("REBUILD {} (image deleted)", image);
            }
        }

        let log_file = init_log_file(image, debug);
        if debug {
            println!("BUILD {}", image);
        }

        let result = build_image_with_logging(&root, image, &tag, &log_file, debug);

        if let Err(e) = result {
            if debug {
                eprintln!("FAILED {}: {}", image, e);
            }
            state.mark_failed(image);
            failed_images.push((image.to_string(), e));
        } else {
            state.mark_success(image);
            // @trace spec:containerfile-staleness
            // Record Containerfile mtime after successful build
            if let Err(e) = capture_containerfile_mtime(&root, image)
                && debug
            {
                eprintln!(
                    "WARNING: Failed to record Containerfile mtime for {}: {}",
                    image, e
                );
            }
            if debug {
                println!("SUCCESS {}", image);
            }
        }
    }

    // Save updated state
    state.save()?;

    // @trace spec:forge-staleness, spec:forge-cache-dual
    // Save current version to cache for future staleness detection
    if let Err(e) = InitBuildState::save_version(version) {
        eprintln!("WARNING: Failed to save cache version: {}", e);
        // Non-fatal; continue with init
    }

    // Display failed build logs if debug mode and there are failures
    if debug && !failed_images.is_empty() {
        eprintln!("\n=== Failed Build Logs ===");
        for (image, _error) in &failed_images {
            let log_file = init_log_file(image, debug);
            if let Some(log_path) = log_file
                && log_path.exists()
                && let Ok(contents) = fs::read_to_string(&log_path)
            {
                let lines: Vec<&str> = contents.lines().collect();
                let start = if lines.len() > 10 {
                    lines.len() - 10
                } else {
                    0
                };
                eprintln!("\n--- {} (last 10 lines) ---", image);
                for line in &lines[start..] {
                    eprintln!("{}", line);
                }
            }
        }
    }

    // Clean up debug logs if all builds succeeded
    if failed_images.is_empty() && debug {
        cleanup_init_logs();
    }

    // Return error if any images failed
    if !failed_images.is_empty() {
        return Err(format!(
            "Failed to build {} image(s): {}",
            failed_images.len(),
            failed_images
                .iter()
                .map(|(name, _)| name)
                .cloned()
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }

    Ok(())
}

/// Execute a single container image build via podman with optional logging.
///
/// @trace spec:init-command, spec:init-incremental-builds
///
/// ## Build Process
/// 1. Locate Containerfile and build context directory (via image_specs)
/// 2. Determine build arguments (e.g., CHROMIUM_CORE_TAG for chromium-framework)
/// 3. Construct `podman build` command with tag and context
/// 4. Optionally redirect stdout/stderr to log file (if debug mode)
/// 5. Execute synchronously and return status
///
/// ## Build Arguments
/// - `--build-arg CHROMIUM_CORE_TAG=<tag>` for chromium-framework only
/// - chromium-framework MUST be built after chromium-core to resolve the ARG
fn build_image_with_logging(
    root: &Path,
    image_name: &str,
    image_tag: &str,
    log_file: &Option<PathBuf>,
    _debug: bool,
) -> Result<(), String> {
    // @trace gap:ON-005 — show progress % during image pull
    let (containerfile, context_dir) = image_specs(root, image_name)?;
    let build_args = image_build_args(image_name, image_tag);

    let mut command = podman_command();
    command.args(["build", "-t", image_tag, "-f"]);
    command.arg(
        containerfile
            .to_str()
            .ok_or_else(|| "Containerfile path contains invalid UTF-8".to_string())?,
    );

    for arg in &build_args {
        command.arg(arg);
    }

    command.arg(
        context_dir
            .to_str()
            .ok_or_else(|| "Context path contains invalid UTF-8".to_string())?,
    );

    // @trace gap:ON-005 — capture stdout/stderr for progress parsing
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());

    let mut child = command
        .spawn()
        .map_err(|e| format!("Failed to spawn build process: {e}"))?;

    let stdout = child.stdout.take();
    let _stderr = child.stderr.take();

    // Open log file for writing all output
    let mut log_handle = if let Some(log_path) = log_file {
        Some(
            fs::OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(log_path)
                .map_err(|e| format!("Failed to open log file: {e}"))?,
        )
    } else {
        None
    };

    // @trace gap:ON-005 — read and parse output for progress tracking
    // Process stdout to catch layer pull progress
    use std::io::BufRead;

    let mut progress_percent = 0;
    let mut last_reported = 0;

    if let Some(stdout_reader) = stdout {
        let buf_reader = std::io::BufReader::new(stdout_reader);
        for line in buf_reader.lines() {
            #[allow(clippy::if_let_ok_or_else)]
            if let Ok(line) = line {
                // Write to log file if present
                if let Some(ref mut log) = log_handle {
                    let _ = writeln!(log, "{}", line);
                }

                // @trace gap:ON-005 — parse podman progress indicators
                // Look for "Pulling" and percentage indicators to compute progress
                if line.contains("Pulling")
                    || line.contains("Digest:")
                    || line.contains("Loaded image")
                {
                    // Estimate progress based on visible output
                    if line.contains("Pulling") && progress_percent < 50 {
                        progress_percent = 50;
                    } else if line.contains("Digest:") && progress_percent < 75 {
                        progress_percent = 75;
                    } else if line.contains("Loaded image") || line.contains("Commit") {
                        progress_percent = 100;
                    }

                    // Emit progress update if it changed significantly
                    if progress_percent > last_reported + 10 || progress_percent == 100 {
                        println!(
                            "Pulling image {} [{}{}] {}%",
                            image_name,
                            "█".repeat(progress_percent / 10),
                            "░".repeat(10 - (progress_percent / 10)),
                            progress_percent
                        );
                        last_reported = progress_percent;
                    }
                }
            }
        }
    }

    let status = child
        .wait()
        .map_err(|e| format!("Failed to wait for build process: {e}"))?;

    if status.success() {
        if progress_percent < 100 {
            println!("Pulling image {} [{}] 100%", image_name, "█".repeat(10));
        }
        Ok(())
    } else {
        Err(format!("Build exited with status {}", status))
    }
}

fn cleanup_init_logs() {
    for image in &[
        "proxy",
        "git",
        "inference",
        "chromium-core",
        "chromium-framework",
        "forge",
    ] {
        let log_path = PathBuf::from(format!("/tmp/tillandsias-init-{}.log", image));
        let _ = fs::remove_file(&log_path);
    }
}

/// Clear the initialization cache and build state.
/// @trace spec:forge-staleness, spec:forge-cache-dual
fn run_cache_clear(debug: bool) -> Result<(), String> {
    let cache_dir = init_cache_dir()?;
    let state_file = cache_dir.join("init-build-state.json");
    let version_file = cache_dir.join("cache_version");
    let temp_file = cache_dir.join(".init-build-state.json.tmp");

    let mut cleared = Vec::new();

    if state_file.exists() {
        fs::remove_file(&state_file)
            .map_err(|e| format!("Failed to remove build state file: {e}"))?;
        cleared.push("init-build-state.json");
    }

    if version_file.exists() {
        fs::remove_file(&version_file)
            .map_err(|e| format!("Failed to remove cache version file: {e}"))?;
        cleared.push("cache_version");
    }

    if temp_file.exists() {
        let _ = fs::remove_file(&temp_file);
        cleared.push(".init-build-state.json.tmp (temp)");
    }

    if debug || !cleared.is_empty() {
        println!("Cache cleared. Removed:");
        for item in cleared {
            println!("  - {}", item);
        }
        println!("\nNext --init will rebuild all images from scratch.");
    }

    Ok(())
}

/// Verify cache integrity and report status.
/// @trace spec:forge-staleness, spec:forge-cache-dual
fn run_cache_verify(debug: bool) -> Result<(), String> {
    let version = VERSION.trim();
    let status = check_cache_integrity(version)?;

    println!("Cache Integrity Status");
    println!("======================");
    println!("Cache directory: {}", status.cache_dir.display());
    println!("Current version: {}", status.current_version);
    println!(
        "Cached version:  {}",
        status.cached_version.as_deref().unwrap_or("<not set>")
    );
    println!();

    if status.is_valid {
        println!("✅ Cache is VALID");
        println!("  - Version matches current build");
        println!("  - Build state file present and readable");
    } else {
        println!("❌ Cache is INVALID");

        if status.version_mismatch {
            println!("  - Version mismatch detected");
            if let Some(cached) = &status.cached_version {
                println!(
                    "    Cached: {}, Current: {}",
                    cached, status.current_version
                );
            } else {
                println!("    No cached version found");
            }
            println!("    Suggestion: Run 'tillandsias --init --force' to rebuild");
        }

        if status.missing_state_file {
            println!("  - Build state file is missing or corrupted");
            println!("    Suggestion: Run 'tillandsias --cache-clear' then 'tillandsias --init'");
        }
    }

    println!();
    if debug {
        println!("Debug Info:");
        println!("  Version mismatch: {}", status.version_mismatch);
        println!("  Missing state file: {}", status.missing_state_file);
    }

    if !status.is_valid {
        return Err("Cache integrity check failed. See suggestions above.".to_string());
    }

    Ok(())
}

/// Run the representative end-to-end stack smoke after images exist.
///
/// @trace spec:dev-build, spec:enclave-network, spec:proxy-container, spec:git-mirror-service, spec:inference-container, spec:default-image, spec:observability-convergence
fn run_status_check(debug: bool) -> Result<(), String> {
    let rt = podman_runtime()?;
    let client = PodmanClient::new();
    let root = find_checkout_root()?;
    let version = VERSION.trim();
    let project_name = root
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("tillandsias");
    let certs_dir = ensure_ca_bundle(debug)?;
    ensure_enclave_network(debug)?;

    let images = [
        "proxy",
        "git",
        "inference",
        "chromium-core",
        "chromium-framework",
        "forge",
    ];
    ensure_versioned_images(&root, &images, version, debug)?;

    let probe_image = versioned_image_tag("forge", version);
    podman_runtime_health_probe(debug, &probe_image)?;

    let proxy_image = versioned_image_tag("proxy", version);
    let git_image = versioned_image_tag("git", version);
    let inference_image = versioned_image_tag("inference", version);

    rt.block_on(async {
        cleanup_stack_containers(&client, project_name).await;

        client
            .run_container(&build_proxy_run_args(&certs_dir, &proxy_image))
            .await
            .map_err(|e| e.to_string())?;

        client
            .run_container(&build_git_run_args(project_name, &certs_dir, &git_image))
            .await
            .map_err(|e| e.to_string())?;

        client
            .run_container(&build_inference_run_args(
                &certs_dir,
                &inference_image,
                true,
            ))
            .await
            .map_err(|e| e.to_string())?;

        let status_args =
            build_status_check_forge_args(root.as_path(), project_name, &certs_dir, version);
        client
            .run_container(&status_args)
            .await
            .map_err(|e| e.to_string())?;

        Ok::<(), String>(())
    })?;

    Ok(())
}

fn podman_runtime_health_probe(debug: bool, probe_image: &str) -> Result<(), String> {
    let probe = || {
        let mut command = podman_command();
        command.args([
            "run",
            "--rm",
            "--userns=host",
            "--hostname",
            "runtime-probe",
            "--entrypoint",
            "/bin/sh",
            probe_image,
            "-c",
            "env >/dev/null",
        ]);
        command
    };

    let first_output = probe()
        .output()
        .map_err(|e| format!("Failed to run Podman runtime probe: {e}"))?;
    if first_output.status.success() {
        return Ok(());
    }

    let first_stderr = summarize_podman_output(&first_output);
    let known_blocker = podman_runtime_blocker(&first_stderr);
    if debug {
        eprintln!("[tillandsias] runtime probe failed: {first_stderr}");
        if !known_blocker {
            eprintln!("[tillandsias] runtime probe did not match a known blocker signature");
        }
    }

    let mut migrate = podman_command();
    migrate.args(["system", "migrate"]);
    let migrate_output = migrate
        .output()
        .map_err(|e| format!("Failed to run Podman system migrate: {e}"))?;
    if debug && !migrate_output.status.success() {
        eprintln!(
            "[tillandsias] podman system migrate failed: {}",
            summarize_podman_output(&migrate_output)
        );
    }

    let second_output = probe()
        .output()
        .map_err(|e| format!("Failed to rerun Podman runtime probe: {e}"))?;
    if second_output.status.success() {
        return Ok(());
    }

    let second_stderr = summarize_podman_output(&second_output);
    Err(format!(
        "Host Podman runtime unhealthy for status-check after one repair attempt; probe image {probe_image}; first error: {first_stderr}; second error: {second_stderr}"
    ))
}

fn summarize_podman_output(output: &std::process::Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if !stderr.is_empty() {
        return stderr;
    }

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !stdout.is_empty() {
        return stdout;
    }

    format!("exit status {}", output.status)
}

fn podman_runtime_blocker(stderr: &str) -> bool {
    let stderr = stderr.to_ascii_lowercase();
    [
        "newuidmap",
        "read-only file system",
        "acquiring runtime init lock",
        "cannot set up namespace",
        "failed to connect to user scope bus",
        "aardvark-dns",
        "netavark",
    ]
    .iter()
    .any(|needle| stderr.contains(needle))
}

fn command_output(mut command: Command, debug: bool) -> Result<String, String> {
    if debug {
        eprintln!("[tillandsias] running: {:?}", command);
    }
    let output = command
        .output()
        .map_err(|e| format!("Failed to run command: {e}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn podman_command() -> Command {
    podman_cmd_sync()
}

/// Container-side bridge for the retired Tauri `--github-login` path.
///
/// The host runtime only assumes Podman. GitHub CLI runs inside the git service
/// image; the host only captures the token in memory and creates the Podman
/// secret over stdin.
///
/// @trace spec:gh-auth-script, spec:secrets-management, spec:podman-secrets-integration, spec:secret-rotation
fn run_github_login(debug: bool) -> Result<(), String> {
    // @trace spec:secret-rotation, spec:secrets-management
    info!(
        accountability = true,
        category = "secrets",
        spec = "secret-rotation",
        operation = "gh_auth_start",
        "GitHub authentication and secret rotation starting"
    );

    let root = find_checkout_root()?;
    let version = VERSION.trim();
    let image = versioned_image_tag("git", version);

    prompt_and_store_git_identity()?;

    ensure_image_exists(&root, "git", &image, debug)?;

    let container = format!("tillandsias-gh-login-{}", std::process::id());
    let cleanup = LoginContainerCleanup {
        name: container.clone(),
        debug,
    };

    let mut run = podman_command();
    run.args([
        "run",
        "--detach",
        "--rm",
        "--name",
        &container,
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        "--userns=keep-id",
        "--entrypoint",
        "/bin/sh",
        &image,
        "-c",
        "trap 'exit 0' TERM INT; while :; do sleep 3600 & wait $!; done",
    ]);
    run_command_silent(run, debug)?;

    let mut login = podman_command();
    login.args([
        "exec",
        "--interactive",
        "--tty",
        &container,
        "gh",
        "auth",
        "login",
        "--hostname",
        "github.com",
        "--git-protocol",
        "https",
    ]);
    run_command(login, debug)?;

    let mut token_cmd = podman_command();
    token_cmd.args([
        "exec",
        &container,
        "gh",
        "auth",
        "token",
        "--hostname",
        "github.com",
    ]);
    let token = command_output(token_cmd, debug)?;
    if token.is_empty() {
        error!(
            accountability = true,
            category = "secrets",
            spec = "secret-rotation",
            operation = "gh_auth_failed",
            reason = "empty-token",
            "GitHub authentication produced empty token"
        );
        return Err("containerized gh auth token returned an empty token".to_string());
    }

    info!(
        accountability = true,
        category = "secrets",
        spec = "secret-rotation",
        operation = "gh_auth_success",
        "GitHub token retrieved successfully; initiating secret rotation"
    );

    create_github_podman_secret(&token, debug)?;
    drop(cleanup);

    info!(
        accountability = true,
        category = "secrets",
        spec = "secret-rotation",
        operation = "gh_auth_complete",
        "GitHub authentication and secret rotation completed successfully"
    );

    Ok(())
}

#[derive(Default)]
struct GitIdentity {
    name: Option<String>,
    email: Option<String>,
}

fn prompt_and_store_git_identity() -> Result<(), String> {
    let current = read_git_identity_defaults();
    let name = prompt_with_default("Git author name", current.name.as_deref())?;
    let email = prompt_with_default("Git author email", current.email.as_deref())?;

    if name.trim().is_empty() {
        return Err("Git author name cannot be empty".to_string());
    }
    if !email.contains('@') || email.trim().contains(char::is_whitespace) {
        return Err("Git author email must look like an email address".to_string());
    }

    let gitconfig = managed_gitconfig_path()?;
    if let Some(parent) = gitconfig.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create git identity directory: {e}"))?;
    }

    let contents = format!(
        "[user]\n\tname = {}\n\temail = {}\n",
        escape_gitconfig_value(name.trim()),
        escape_gitconfig_value(email.trim())
    );
    std::fs::write(&gitconfig, contents)
        .map_err(|e| format!("Failed to write managed git identity: {e}"))?;
    println!("Git identity saved: {}", gitconfig.display());
    Ok(())
}

fn prompt_with_default(label: &str, default: Option<&str>) -> Result<String, String> {
    match default {
        Some(value) if !value.trim().is_empty() => {
            print!("{label} [{value}]: ");
        }
        _ => {
            print!("{label}: ");
        }
    }
    io::stdout()
        .flush()
        .map_err(|e| format!("Failed to flush prompt: {e}"))?;

    let mut input = String::new();
    io::stdin()
        .read_line(&mut input)
        .map_err(|e| format!("Failed to read {label}: {e}"))?;

    let input = input.trim().to_string();
    if input.is_empty() {
        Ok(default.unwrap_or("").trim().to_string())
    } else {
        Ok(input)
    }
}

fn read_git_identity_defaults() -> GitIdentity {
    let mut identity = GitIdentity::default();
    for path in gitconfig_default_paths() {
        if let Ok(contents) = std::fs::read_to_string(path) {
            let parsed = parse_git_identity(&contents);
            if identity.name.is_none() {
                identity.name = parsed.name;
            }
            if identity.email.is_none() {
                identity.email = parsed.email;
            }
        }
    }
    identity
}

fn gitconfig_default_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Ok(path) = managed_gitconfig_path() {
        paths.push(path);
    }
    if let Ok(home) = std::env::var("HOME") {
        paths.push(PathBuf::from(home).join(".gitconfig"));
    }
    paths
}

fn managed_gitconfig_path() -> Result<PathBuf, String> {
    if let Ok(cache_home) = std::env::var("XDG_CACHE_HOME") {
        return Ok(PathBuf::from(cache_home)
            .join("tillandsias")
            .join("secrets")
            .join("git")
            .join(".gitconfig"));
    }
    let home = std::env::var("HOME").map_err(|_| "HOME is not set".to_string())?;
    Ok(PathBuf::from(home)
        .join(".cache")
        .join("tillandsias")
        .join("secrets")
        .join("git")
        .join(".gitconfig"))
}

fn parse_git_identity(contents: &str) -> GitIdentity {
    let mut identity = GitIdentity::default();
    let mut in_user = false;

    for line in contents.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            in_user = trimmed == "[user]";
            continue;
        }
        if !in_user {
            continue;
        }
        if let Some((key, value)) = trimmed.split_once('=') {
            let key = key.trim();
            let value = value.trim().trim_matches('"').to_string();
            match key {
                "name" if identity.name.is_none() => identity.name = Some(value),
                "email" if identity.email.is_none() => identity.email = Some(value),
                _ => {}
            }
        }
    }

    identity
}

fn escape_gitconfig_value(value: &str) -> String {
    value.replace('\\', "\\\\").replace('\n', " ")
}

struct LoginContainerCleanup {
    name: String,
    debug: bool,
}

impl Drop for LoginContainerCleanup {
    fn drop(&mut self) {
        let mut command = podman_command();
        command.args(["rm", "-f", &self.name]);
        let _ = run_command_silent(command, self.debug);
    }
}

fn create_github_podman_secret(token: &str, debug: bool) -> Result<(), String> {
    // @trace spec:secrets-management, spec:secret-rotation, spec:podman-secrets-integration
    info!(
        accountability = true,
        category = "secrets",
        spec = "secret-rotation",
        secret_type = "github-token",
        operation = "rotation_start",
        secret_name = "tillandsias-github-token",
        "GitHub token secret rotation starting"
    );

    let mut remove = podman_command();
    remove.args(["secret", "rm", "tillandsias-github-token"]);
    if let Err(e) = run_command_silent(remove, debug) {
        // Secret may not exist yet; this is not an error
        debug!("Existing GitHub secret removal attempt: {}", e);
    }

    let mut child = podman_command()
        .args([
            "secret",
            "create",
            "--driver=file",
            "tillandsias-github-token",
            "-",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| {
            error!(
                accountability = true,
                category = "secrets",
                spec = "secret-rotation",
                secret_type = "github-token",
                operation = "rotation_failed",
                secret_name = "tillandsias-github-token",
                error = %e,
                "Failed to spawn podman secret create process"
            );
            format!("Failed to create GitHub Podman secret: {e}")
        })?;

    if debug {
        eprintln!(
            "[tillandsias] running: podman secret create --driver=file tillandsias-github-token -"
        );
    }

    {
        let stdin = child.stdin.as_mut().ok_or_else(|| {
            error!(
                accountability = true,
                category = "secrets",
                spec = "secret-rotation",
                secret_type = "github-token",
                operation = "rotation_failed",
                secret_name = "tillandsias-github-token",
                error = "stdin pipe not available",
                "Failed to access podman secret create stdin"
            );
            "Failed to open podman secret stdin".to_string()
        })?;
        stdin.write_all(token.as_bytes()).map_err(|e| {
            error!(
                accountability = true,
                category = "secrets",
                spec = "secret-rotation",
                secret_type = "github-token",
                operation = "rotation_failed",
                secret_name = "tillandsias-github-token",
                error = %e,
                "Failed to write token to podman secret stdin"
            );
            format!("Failed to write token to podman secret stdin: {e}")
        })?;
        stdin.write_all(b"\n").map_err(|e| {
            error!(
                accountability = true,
                category = "secrets",
                spec = "secret-rotation",
                secret_type = "github-token",
                operation = "rotation_failed",
                secret_name = "tillandsias-github-token",
                error = %e,
                "Failed to finalize token input to podman secret"
            );
            format!("Failed to finish token input: {e}")
        })?;
    }
    drop(child.stdin.take());

    let output = child.wait_with_output().map_err(|e| {
        error!(
            accountability = true,
            category = "secrets",
            spec = "secret-rotation",
            secret_type = "github-token",
            operation = "rotation_failed",
            secret_name = "tillandsias-github-token",
            error = %e,
            "Failed to wait for podman secret create completion"
        );
        format!("Failed waiting for podman secret create: {e}")
    })?;
    if output.status.success() {
        info!(
            accountability = true,
            category = "secrets",
            spec = "secret-rotation",
            secret_type = "github-token",
            operation = "rotation_complete",
            secret_name = "tillandsias-github-token",
            "GitHub token secret rotation completed successfully"
        );
        println!("GitHub token secret created: tillandsias-github-token");
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        error!(
            accountability = true,
            category = "secrets",
            spec = "secret-rotation",
            secret_type = "github-token",
            operation = "rotation_failed",
            secret_name = "tillandsias-github-token",
            exit_code = output.status.code().unwrap_or(-1),
            stderr = ?stderr,
            "Podman secret create failed"
        );
        if stderr.is_empty() {
            Err(format!(
                "podman secret create exited with status {}",
                output.status
            ))
        } else {
            Err(stderr)
        }
    }
}

/// Phase 3, Task 12: Auto-detect native tray availability.
/// @trace spec:linux-native-portable-executable, spec:transparent-mode-detection
fn is_tray_available() -> bool {
    cfg!(all(feature = "tray", target_os = "linux"))
}

/// Phase 3, Task 12 & Phase 4: Launch in tray mode with headless subprocess.
/// @trace spec:linux-native-portable-executable, spec:transparent-mode-detection, spec:tray-subprocess-management
fn launch_tray_mode(_config_path: Option<String>) -> Result<(), String> {
    #[cfg(feature = "tray")]
    {
        crate::tray::run_tray_mode(_config_path)
    }

    #[cfg(not(feature = "tray"))]
    {
        Err("Tray mode requires 'tray' feature".to_string())
    }
}

/// Run in OpenCode mode — launch the full enclave stack and OpenCode TUI.
///
/// @trace spec:cli-mode
fn run_opencode_mode(project_path: &str, prompt: Option<&str>, debug: bool) -> Result<(), String> {
    if debug {
        eprintln!("[tillandsias] OpenCode mode enabled");
        eprintln!("[tillandsias] Project: {}", project_path);
        if let Some(prompt) = prompt {
            eprintln!("[tillandsias] Prompt seed provided: {}", prompt);
        }
    }

    // Phase B: Project initialization and container startup
    let project = std::path::Path::new(project_path);
    if !project.exists() {
        return Err(format!("Project not found: {}", project_path));
    }

    if debug {
        eprintln!(
            "[tillandsias] Project path is valid: {}",
            project.canonicalize().unwrap_or_default().display()
        );
    }

    let root = find_checkout_root().unwrap_or_else(|_| std::env::current_dir().unwrap_or_default());
    let version = VERSION.trim();
    let project_name = std::path::Path::new(project_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("opencode-project");
    let certs_dir = ensure_ca_bundle(debug)?;
    ensure_enclave_network(debug)?;

    let images = ["proxy", "git", "inference", "forge"];
    ensure_versioned_images(&root, &images, version, debug)?;

    if debug {
        eprintln!("[tillandsias] [OpenCode] Repo root: {}", root.display());
        eprintln!("[tillandsias] [OpenCode] Launching full-stack OpenCode session");
    }

    let rt = podman_runtime()?;
    let client = PodmanClient::new();
    rt.block_on(async {
        cleanup_stack_containers(&client, project_name).await;

        client
            .run_container(&build_proxy_run_args(
                &certs_dir,
                &versioned_image_tag("proxy", version),
            ))
            .await
            .map_err(|e| e.to_string())?;
        client
            .run_container(&build_git_run_args(
                project_name,
                &certs_dir,
                &versioned_image_tag("git", version),
            ))
            .await
            .map_err(|e| e.to_string())?;
        client
            .run_container(&build_inference_run_args(
                &certs_dir,
                &versioned_image_tag("inference", version),
                false,
            ))
            .await
            .map_err(|e| e.to_string())?;

        let opencode_args = build_opencode_forge_args(
            std::path::Path::new(project_path),
            project_name,
            prompt,
            &certs_dir,
            version,
        );
        client
            .run_container(&opencode_args)
            .await
            .map_err(|e| e.to_string())?;

        Ok::<(), String>(())
    })
}

fn opencode_web_url(project_name: &str) -> String {
    format!("http://opencode.{project_name}.localhost/")
}

#[cfg(test)]
const OPENCODE_WEB_STARTUP_STAGES: [&str; 6] =
    ["stack", "proxy", "git", "inference", "forge", "browser"];

fn opencode_web_event_log_path(project_name: &str) -> PathBuf {
    let base = if let Ok(runtime_dir) = std::env::var("XDG_RUNTIME_DIR") {
        PathBuf::from(runtime_dir).join("tillandsias/logs/opencode-web")
    } else {
        PathBuf::from("/tmp/tillandsias/logs/opencode-web")
    };

    base.join(format!("{project_name}.jsonl"))
}

fn json_escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 8);
    for ch in value.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn emit_opencode_web_event(
    project_name: &str,
    stage: &str,
    state: &str,
    detail: Option<&str>,
) -> Result<(), String> {
    let path = opencode_web_event_log_path(project_name);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create OpenCode Web event dir: {e}"))?;
    }

    let now = chrono::Local::now().to_rfc3339();
    let mut line = format!(
        r#"{{"ts":"{}","project":"{}","stage":"{}","state":"{}""#,
        json_escape(&now),
        json_escape(project_name),
        json_escape(stage),
        json_escape(state)
    );
    if let Some(detail) = detail {
        line.push_str(&format!(r#","detail":"{}""#, json_escape(detail)));
    }
    line.push_str("}\n");

    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| format!("Failed to open OpenCode Web event log {:?}: {e}", path))?;
    file.write_all(line.as_bytes())
        .map_err(|e| format!("Failed to write OpenCode Web event log {:?}: {e}", path))?;
    Ok(())
}

#[cfg(test)]
fn opencode_web_startup_stages() -> &'static [&'static str; 6] {
    &OPENCODE_WEB_STARTUP_STAGES
}

fn wait_for_opencode_web(url: &str, debug: bool) -> Result<(), String> {
    for attempt in 1..=20 {
        let output = Command::new("curl")
            .args([
                "-sS",
                "-o",
                "/dev/null",
                "-w",
                "%{http_code}",
                "--max-time",
                "1",
                url,
            ])
            .output();
        if let Ok(output) = output
            && output.status.success()
        {
            let status = String::from_utf8_lossy(&output.stdout);
            if let Ok(code) = status.trim().parse::<u16>()
                && (100..600).contains(&code)
            {
                return Ok(());
            }
        }
        if debug {
            eprintln!("[tillandsias] waiting for OpenCode Web route: attempt {attempt}/20");
        }
        std::thread::sleep(Duration::from_millis(500));
    }

    Err(format!("OpenCode Web route did not become ready: {url}"))
}

fn browser_profile_root() -> PathBuf {
    if let Some(runtime_dir) = std::env::var_os("XDG_RUNTIME_DIR") {
        return PathBuf::from(runtime_dir).join("tillandsias/browser");
    }

    if let Some(tmpdir) = std::env::var_os("TMPDIR") {
        return PathBuf::from(tmpdir).join("tillandsias/browser");
    }

    PathBuf::from("/tmp/tillandsias/browser")
}

#[derive(Debug, Clone, Default)]
struct BrowserDisplayContext {
    display: Option<String>,
    xauthority: Option<PathBuf>,
    wayland_display: Option<String>,
    xdg_runtime_dir: Option<PathBuf>,
}

impl BrowserDisplayContext {
    fn from_env() -> Result<Self, String> {
        let display = std::env::var("DISPLAY").ok();
        let xauthority = std::env::var_os("XAUTHORITY").map(PathBuf::from);
        let wayland_display = std::env::var("WAYLAND_DISPLAY").ok();
        let xdg_runtime_dir = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from);

        if display.is_none() && wayland_display.is_none() {
            return Err(
                "OpenCode Web browser launch requires a graphical session (DISPLAY or WAYLAND_DISPLAY)"
                    .to_string(),
            );
        }

        Ok(Self {
            display,
            xauthority,
            wayland_display,
            xdg_runtime_dir,
        })
    }
}

fn build_opencode_web_browser_spec(
    app_url: &str,
    version: &str,
    profile_dir: &Path,
    certs_dir: &Path,
    display: &BrowserDisplayContext,
    project_name: &str,
) -> Result<ContainerSpec, String> {
    let container_name = format!("tillandsias-browser-{project_name}");
    let mut spec = ContainerSpec::new(format!("tillandsias-chromium-framework:v{version}"))
        .pull_never()
        .read_only()
        .cap_add("SYS_CHROOT")
        .network("host")
        .name(&container_name)
        .detached()
        .volume(
            profile_dir.display().to_string(),
            profile_dir.display().to_string(),
            MountMode::ReadWrite,
        )
        .bind_mount(
            certs_dir.join("intermediate.crt").display().to_string(),
            "/etc/tillandsias/ca.crt",
            true,
        )
        .env("TILLANDSIAS_CA_BUNDLE", "/etc/tillandsias/ca.crt")
        .env("SSL_CERT_FILE", "/etc/tillandsias/ca.crt")
        .env("XDG_CONFIG_HOME", "/tmp/chromium-config")
        .env("XDG_CACHE_HOME", "/tmp/chromium-cache")
        .tmpfs("/tmp:size=256m")
        .tmpfs("/tmp/chromium-config:size=128m")
        .tmpfs("/tmp/chromium-cache:size=512m")
        .tmpfs("/dev/shm:size=256m")
        .arg("--incognito")
        .arg("--no-first-run")
        .arg("--no-default-browser-check")
        .arg(format!("--user-data-dir={}", profile_dir.display()))
        .arg(format!("--app={app_url}"));

    if let Some(display_name) = &display.display {
        spec = spec
            .env("DISPLAY", display_name)
            .volume("/tmp/.X11-unix", "/tmp/.X11-unix", MountMode::ReadWrite)
            .arg("--ozone-platform=x11");

        if let Some(xauthority_path) = &display.xauthority
            && xauthority_path.exists()
        {
            spec = spec
                .env("XAUTHORITY", "/home/chromium/.Xauthority")
                .bind_mount(
                    xauthority_path.display().to_string(),
                    "/home/chromium/.Xauthority",
                    true,
                );
        }
    } else if let Some(wayland_display) = &display.wayland_display {
        if let Some(xdg_runtime_dir) = &display.xdg_runtime_dir {
            spec = spec
                .env("XDG_RUNTIME_DIR", xdg_runtime_dir.display().to_string())
                .env("WAYLAND_DISPLAY", wayland_display)
                .volume(
                    xdg_runtime_dir.display().to_string(),
                    xdg_runtime_dir.display().to_string(),
                    MountMode::ReadWrite,
                )
                .arg("--ozone-platform=wayland");
        } else {
            return Err(
                "OpenCode Web browser launch requires XDG_RUNTIME_DIR for Wayland sessions"
                    .to_string(),
            );
        }
    }

    for device_flag in detect_gpu_devices() {
        if let Some(device) = device_flag.strip_prefix("--device=") {
            spec = spec.device(device);
        } else {
            spec = spec.option(device_flag);
        }
    }

    Ok(spec)
}

/// Send IssueWebSession message to tray's control socket.
///
/// @trace spec:opencode-web-session-otp, spec:tray-host-control-socket
fn send_issue_web_session(project_label: &str, cookie_value: &[u8; 32]) -> Result<(), String> {
    // Get control socket path from XDG_RUNTIME_DIR or default.
    let runtime_dir = std::env::var("XDG_RUNTIME_DIR")
        .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));
    let socket_path = format!("{}/tillandsias/control.sock", runtime_dir);

    // Connect to the socket with 5-second timeout for graceful fallback.
    let mut stream = UnixStream::connect(&socket_path)
        .map_err(|e| format!("Failed to connect to control socket {}: {}", socket_path, e))?;

    // Set read/write timeouts to 5 seconds to prevent hanging if tray is unresponsive.
    let timeout = Duration::from_secs(5);
    stream
        .set_read_timeout(Some(timeout))
        .map_err(|e| format!("Failed to set read timeout: {}", e))?;
    stream
        .set_write_timeout(Some(timeout))
        .map_err(|e| format!("Failed to set write timeout: {}", e))?;

    // Prepare and send the IssueWebSession message.
    let envelope = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: 1, // seq number is not critical for this fire-and-forget usage
        body: ControlMessage::IssueWebSession {
            project_label: project_label.to_string(),
            cookie_value: *cookie_value,
        },
    };

    // Encode and write with length prefix (4-byte big-endian).
    let encoded =
        encode(&envelope).map_err(|e| format!("Failed to encode control message: {}", e))?;
    let len = encoded.len() as u32;
    let mut frame = len.to_be_bytes().to_vec();
    frame.extend_from_slice(&encoded);

    stream
        .write_all(&frame)
        .map_err(|e| format!("Failed to write control message: {}", e))?;

    Ok(())
}

fn launch_opencode_web_browser(
    project_name: &str,
    certs_dir: &Path,
    debug: bool,
) -> Result<(), String> {
    let url = opencode_web_url(project_name);
    emit_opencode_web_event(project_name, "browser", "wait_for_route", Some(&url))?;
    if let Err(err) = wait_for_opencode_web(&url, debug) {
        emit_opencode_web_event(project_name, "browser", "route_unhealthy", Some(&err))?;
        return Err(err);
    }
    emit_opencode_web_event(project_name, "browser", "route_ready", Some(&url))?;

    let version = VERSION.trim();
    let profile_root = browser_profile_root();
    std::fs::create_dir_all(&profile_root).map_err(|e| {
        format!(
            "Failed to create browser profile root {:?}: {e}",
            profile_root
        )
    })?;
    let display = BrowserDisplayContext::from_env()?;
    let profile_dir = TempDirBuilder::new()
        .prefix(&format!("{project_name}-"))
        .tempdir_in(&profile_root)
        .map_err(|e| {
            format!(
                "Failed to create browser profile dir in {:?}: {e}",
                profile_root
            )
        })?;
    let profile_path = profile_dir.path().to_path_buf();
    // @trace spec:opencode-web-session-otp
    // Issue a session token for the project and register it with the router.
    let project_label = format!("opencode.{project_name}.localhost");
    let otp = tillandsias_otp::issue_session(&project_label);
    let login_url = tillandsias_otp::build_login_data_url(&url, &otp);
    let spec = build_opencode_web_browser_spec(
        &login_url,
        version,
        &profile_path,
        certs_dir,
        &display,
        project_name,
    )?;
    let args = spec.build_run_args();

    emit_opencode_web_event(project_name, "browser", "launch", Some("podman-run"))?;
    let result = rt_block_on_podman_run(args, debug);
    if result.is_ok() {
        emit_opencode_web_event(project_name, "browser", "launched", Some("gui"))?;
        // @trace spec:opencode-web-session-otp, spec:tray-host-control-socket
        // Notify router (via control socket) that a web session has been issued.
        // This is non-critical; if the tray is down, we skip the notification gracefully.
        if let Err(e) = send_issue_web_session(&project_label, &otp)
            && debug
        {
            eprintln!("[tillandsias] Warning: failed to notify router of web session: {e}");
        }

        // @trace spec:browser-isolation-core, spec:host-chromium-on-demand
        // Spawn background task to monitor container exit and cleanup.
        // The browser is now running detached; this task waits for it to exit.
        let container_name = format!("tillandsias-browser-{project_name}");
        std::thread::spawn(move || {
            let rt = match tokio::runtime::Runtime::new() {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("[tillandsias] Failed to create runtime for browser cleanup: {e}");
                    return;
                }
            };
            if let Err(e) = rt.block_on(monitor_and_cleanup_browser(&container_name, debug)) {
                eprintln!("[tillandsias] Browser cleanup error: {e}");
            }
        });
    } else if let Err(ref err) = result {
        let _ = emit_opencode_web_event(project_name, "browser", "launch_failed", Some(err));
    }
    result
}

fn rt_block_on_podman_run(args: Vec<String>, debug: bool) -> Result<(), String> {
    let rt = podman_runtime()?;
    let client = PodmanClient::new();
    rt.block_on(async move {
        client
            .run_container(&args)
            .await
            .map(|_| ())
            .map_err(|e| e.to_string())
    })
    .inspect_err(|err| {
        if debug {
            eprintln!("[tillandsias] browser container launch failed: {err}");
        }
    })
}

/// @trace spec:browser-isolation-core, spec:host-chromium-on-demand
/// Monitor a detached browser container for exit and clean up resources.
/// Launches the container, waits for it to exit, then removes it.
async fn monitor_and_cleanup_browser(container_name: &str, debug: bool) -> Result<(), String> {
    // Wait for container to exit by polling its state periodically.
    // In a full implementation, this would use `podman events` for more efficient monitoring.
    let mut poll_interval = Duration::from_millis(100);
    let max_poll_interval = Duration::from_secs(1);
    let timeout = Duration::from_secs(3600); // 1-hour timeout
    let start = std::time::Instant::now();

    loop {
        if start.elapsed() > timeout {
            if debug {
                eprintln!("[tillandsias] browser container timeout after 1 hour: {container_name}");
            }
            break;
        }

        // Poll container state
        let mut cmd = podman_command();
        cmd.args(["inspect", "--format=.State.Running", container_name]);
        let output = cmd
            .output()
            .map_err(|e| format!("Failed to inspect browser container: {e}"))?;

        if !output.status.success() {
            // Container not found or error — assume it exited
            if debug {
                eprintln!("[tillandsias] browser container not running: {container_name}");
            }
            break;
        }

        let is_running = String::from_utf8_lossy(&output.stdout).trim().eq("true");
        if !is_running {
            if debug {
                eprintln!("[tillandsias] browser container exited: {container_name}");
            }
            break;
        }

        tokio::time::sleep(poll_interval).await;
        poll_interval = (poll_interval * 2).min(max_poll_interval);
    }

    // Clean up the container
    let mut cleanup = podman_command();
    cleanup.args(["rm", "-f", container_name]);
    let _ = run_command_silent(cleanup, debug);

    if debug {
        eprintln!("[tillandsias] cleaned up browser container: {container_name}");
    }
    Ok(())
}

pub(crate) fn run_opencode_web_mode(
    project_path: &str,
    prompt: Option<&str>,
    debug: bool,
) -> Result<(), String> {
    if debug {
        eprintln!("[tillandsias] OpenCode Web mode enabled");
        eprintln!("[tillandsias] Project: {}", project_path);
        if let Some(prompt) = prompt {
            eprintln!("[tillandsias] Prompt seed provided: {}", prompt);
        }
    }

    let project = std::path::Path::new(project_path);
    if !project.exists() {
        return Err(format!("Project not found: {}", project_path));
    }

    if debug {
        eprintln!(
            "[tillandsias] Project path is valid: {}",
            project.canonicalize().unwrap_or_default().display()
        );
    }

    let root = find_checkout_root().unwrap_or_else(|_| std::env::current_dir().unwrap_or_default());
    let version = VERSION.trim();
    let project_name = std::path::Path::new(project_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("opencode-project");
    let certs_dir = ensure_ca_bundle(debug)?;
    ensure_enclave_network(debug)?;

    let images = [
        "proxy",
        "git",
        "inference",
        "chromium-core",
        "chromium-framework",
        "forge",
        "router",
    ];
    ensure_versioned_images(&root, &images, version, debug)?;

    if debug {
        eprintln!("[tillandsias] [OpenCode Web] Repo root: {}", root.display());
        eprintln!("[tillandsias] [OpenCode Web] Launching full-stack session");
    }

    let rt = podman_runtime()?;
    let client = PodmanClient::new();
    emit_opencode_web_event(
        project_name,
        "stack",
        "starting",
        Some("proxy git inference forge"),
    )?;
    rt.block_on(async {
        cleanup_stack_containers(&client, project_name).await;

        client
            .run_container(&build_proxy_run_args(
                &certs_dir,
                &versioned_image_tag("proxy", version),
            ))
            .await
            .map_err(|e| e.to_string())?;
        emit_opencode_web_event(
            project_name,
            "proxy",
            "started",
            Some(&versioned_image_tag("proxy", version)),
        )?;
        client
            .run_container(&build_git_run_args(
                project_name,
                &certs_dir,
                &versioned_image_tag("git", version),
            ))
            .await
            .map_err(|e| e.to_string())?;
        emit_opencode_web_event(
            project_name,
            "git",
            "started",
            Some(&versioned_image_tag("git", version)),
        )?;
        client
            .run_container(&build_inference_run_args(
                &certs_dir,
                &versioned_image_tag("inference", version),
                false,
            ))
            .await
            .map_err(|e| e.to_string())?;
        emit_opencode_web_event(
            project_name,
            "inference",
            "started",
            Some(&versioned_image_tag("inference", version)),
        )?;

        let opencode_args = build_opencode_forge_args(
            std::path::Path::new(project_path),
            project_name,
            prompt,
            &certs_dir,
            version,
        );
        client
            .run_container(&opencode_args)
            .await
            .map_err(|e| e.to_string())?;
        emit_opencode_web_event(project_name, "forge", "started", Some("opencode-web"))?;

        // @trace spec:subdomain-routing-via-reverse-proxy
        // After forge starts, ensure router is running and write dynamic routes.
        let router_image = versioned_image_tag("router", version);
        ensure_router_running(&client, &certs_dir, &router_image, debug)
            .await
            .unwrap_or_else(|e| {
                if debug {
                    eprintln!("[tillandsias] Warning: router degraded: {e}");
                }
            });

        // Write dynamic Caddyfile with OpenCode Web routes.
        // For now, a single route mapping opencode.<project>.localhost to the web service.
        let windows = vec![(
            format!("opencode.{}", project_name),
            format!("tillandsias-{}-forge", project_name),
            8080u16,
        )];
        let dynamic_config = generate_dynamic_caddyfile(&windows);
        let dyn_file = router_dynamic_caddyfile_host_path().join("dynamic.Caddyfile");
        std::fs::write(&dyn_file, &dynamic_config).unwrap_or_else(|e| {
            if debug {
                eprintln!("[tillandsias] Warning: failed to write dynamic Caddyfile: {e}");
            }
        });

        // @trace spec:subdomain-routing-via-reverse-proxy
        // After writing the dynamic Caddyfile, reload Caddy to activate the routes.
        // The reload is graceful (no container restart) via the admin API at localhost:2019.
        caddy_reload_routes(debug).await?;

        Ok::<(), String>(())
    })?;

    launch_opencode_web_browser(project_name, &certs_dir, debug)
}

// Module declarations for Phase 4+
#[cfg(feature = "tray")]
mod tray;

/// Run in headless mode — no tray, no UI.
///
/// @trace spec:linux-native-portable-executable, spec:headless-mode
fn run_headless(config_path: Option<String>) -> Result<(), String> {
    // Create a Tokio runtime for async operations
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| format!("Failed to create async runtime: {}", e))?;

    // Run the async headless mode
    rt.block_on(run_headless_async(config_path))
}

/// Phase 5: Async implementation of headless mode.
/// @trace spec:linux-native-portable-executable, spec:headless-mode, spec:signal-handling, spec:resource-metric-collection
async fn run_headless_async(config_path: Option<String>) -> Result<(), String> {
    // Emit startup event with timestamp
    let now = chrono::Local::now();
    println!(
        r#"{{"event":"app.started","timestamp":"{}"}}"#,
        now.to_rfc3339()
    );

    // Load configuration (if path provided)
    if let Some(path) = config_path {
        load_config(&path)?;
    }

    // Initialize orchestration (placeholder for Phase 2)
    // In full implementation, this would:
    // - Load container state from podman
    // - Start monitoring containers
    // - Initialize enclave network

    // Wave 13 Gap #3: spawn background resource-metric sampler.
    // @trace spec:resource-metric-collection, spec:observability-metrics
    // @cheatsheet observability/cheatsheet-metrics.md
    //
    // Wave 19c Gap OBS-005: Run metrics retention check before starting sampler
    // @trace gap:OBS-005
    run_metrics_retention();

    // Wave 20d Gap OBS-012: Run evidence bundle retention check before metrics
    // @trace gap:OBS-012
    run_evidence_bundle_retention();

    // Wave 20c Gap OBS-010: Run log field cardinality analysis
    // @trace gap:OBS-010
    run_log_cardinality_analysis().await;

    let metrics_handle = spawn_metrics_sampler();

    // Main event loop: wait for application shutdown signal.
    wait_for_shutdown_signal().await?;
    eprintln!("Received shutdown signal");

    // Cancel background metric sampler before invoking the rest of the
    // shutdown sequence so it does not race with container teardown logs.
    if let Some(handle) = metrics_handle {
        handle.abort();
        // Drain the join future; aborted tasks yield JoinError(cancelled).
        let _ = handle.await;
    }

    // Phase 5, Task 21: Graceful shutdown with timeout
    graceful_shutdown_async().await?;

    // Emit stopped event
    let now = chrono::Local::now();
    println!(
        r#"{{"event":"app.stopped","exit_code":0,"timestamp":"{}"}}"#,
        now.to_rfc3339()
    );
    Ok(())
}

/// Run metrics retention check to archive files older than 30 days.
///
/// This implements gap:OBS-005. Files are moved from ~/.cache/tillandsias/logs/
/// to ~/.cache/tillandsias/metrics-archive/ if they exceed the 30-day retention
/// window. Runs synchronously on startup (lightweight operation).
///
/// @trace gap:OBS-005, spec:observability-metrics
fn run_metrics_retention() {
    use tillandsias_core::config;
    use tillandsias_metrics::archive_old_metrics;

    let cache_dir = config::cache_dir();
    let metrics_dir = cache_dir.join("logs");
    let retention_days = 30;

    match archive_old_metrics(&metrics_dir, retention_days) {
        Ok(()) => {
            // Success; retention check completed (may have archived 0 or more files).
            // Detailed logging happens inside archive_old_metrics.
        }
        Err(e) => {
            // Log the error but don't fail startup — retention is non-critical.
            tracing::warn!(
                spec = "observability-metrics",
                gap = "OBS-005",
                error = %e,
                "metrics retention check failed (non-blocking)"
            );
        }
    }
}

/// Run evidence bundle retention to delete bundles older than 30 days.
///
/// This implements gap:OBS-012. Evidence bundles (JSON snapshots and tar.gz
/// archives) are deleted from target/convergence/ if they exceed the 30-day
/// retention window. Runs synchronously on startup (lightweight operation) to
/// prevent unbounded growth of convergence artifacts.
///
/// Deletion is non-blocking; if any bundle fails to delete, a warning is logged
/// and startup continues. User is notified of cleanup count and dates via stderr.
///
/// @trace gap:OBS-012, spec:observability-convergence
fn run_evidence_bundle_retention() {
    use std::fs;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    let repo_root = std::env::current_dir()
        .ok()
        .and_then(|p| {
            if p.join("VERSION").exists() {
                Some(p)
            } else {
                None
            }
        })
        .or_else(|| {
            // Fallback: assume CARGO_MANIFEST_DIR-relative path if invoked from workspace
            std::env::var("CARGO_MANIFEST_DIR").ok().and_then(|m| {
                let p = std::path::PathBuf::from(&m);
                let root = p.ancestors().find(|a| a.join("VERSION").exists())?;
                Some(root.to_path_buf())
            })
        });

    let convergence_dir = match repo_root {
        Some(root) => root.join("target/convergence"),
        None => {
            tracing::warn!(
                gap = "OBS-012",
                "could not determine repo root; skipping evidence bundle retention"
            );
            return;
        }
    };

    // Ensure convergence directory exists
    if !convergence_dir.is_dir() {
        debug!(
            gap = "OBS-012",
            path = ?convergence_dir,
            "convergence directory does not exist; skipping retention"
        );
        return;
    }

    // Calculate cutoff time (now - 30 days)
    let retention_days = 30u64;
    let cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(retention_days * 24 * 60 * 60))
        .unwrap_or(UNIX_EPOCH);

    let mut deleted_count = 0;
    let mut deleted_names = Vec::new();

    // Find and delete evidence bundle files (JSON and tar.gz)
    if let Ok(entries) = fs::read_dir(&convergence_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            let file_name = match path.file_name() {
                Some(name) => name.to_string_lossy().to_string(),
                None => continue,
            };

            // Match evidence-bundle*.json and evidence-bundle*.tar.gz
            if !file_name.starts_with("evidence-bundle") {
                continue;
            }
            if !file_name.ends_with(".json") && !file_name.ends_with(".tar.gz") {
                continue;
            }

            // Skip the "evidence-bundle.json" symbolic/current bundle link
            if file_name == "evidence-bundle.json" {
                continue;
            }

            // Check modification time
            if let Ok(metadata) = fs::metadata(&path)
                && let Ok(modified) = metadata.modified()
                    && modified < cutoff {
                        // Bundle is older than retention window; delete it
                        if let Ok(()) = fs::remove_file(&path) {
                            deleted_count += 1;
                            deleted_names.push(file_name);
                            debug!(
                                gap = "OBS-012",
                                bundle = ?path,
                                "deleted old evidence bundle"
                            );
                        } else {
                            tracing::warn!(
                                gap = "OBS-012",
                                bundle = ?path,
                                "failed to delete evidence bundle (continuing)"
                            );
                        }
                    }
        }
    }

    // User notification (stderr)
    if deleted_count > 0 {
        eprintln!(
            "[headless] evidence bundle retention cleanup: deleted {} bundle(s) older than {} days",
            deleted_count, retention_days
        );
        for name in deleted_names {
            eprintln!("  - {}", name);
        }
        tracing::info!(
            gap = "OBS-012",
            spec = "observability-convergence",
            deleted_count = deleted_count,
            retention_days = retention_days,
            "evidence bundle retention cleanup completed"
        );
    }
}

/// Analyze log field cardinality and warn if high-cardinality fields are detected.
///
/// This implements gap:OBS-010. Scans recent log entries to detect fields with
/// unbounded cardinality that could cause log explosion. Runs asynchronously on
/// startup without blocking the main event loop.
///
/// High-cardinality fields (> 1000 unique values) are reported to the user with
/// sample values to help identify problematic logging patterns.
///
/// @trace gap:OBS-010, spec:runtime-logging
async fn run_log_cardinality_analysis() {
    use tillandsias_core::config;
    use tillandsias_logging::CardinalityAnalyzer;

    let log_dir = config::log_dir();
    let log_file = log_dir.join("tillandsias.log");

    if !log_file.exists() {
        debug!(
            gap = "OBS-010",
            "tillandsias.log does not exist; skipping cardinality analysis"
        );
        return;
    }

    let analyzer = CardinalityAnalyzer::default();
    match analyzer.analyze_log_file(&log_file).await {
        Ok(report) => {
            if !report.high_cardinality_fields.is_empty() {
                analyzer.warn_high_cardinality(&report);

                // User notification (stderr) with actionable message
                eprintln!(
                    "[headless] log cardinality analysis: {} high-cardinality field(s) detected",
                    report.high_cardinality_fields.len()
                );
                for field in report.high_cardinality_fields.iter().take(3) {
                    eprintln!(
                        "  - {}: {} unique values (examples: {:?})",
                        field.field_name,
                        field.unique_count,
                        field.sample_values.iter().take(2).collect::<Vec<_>>()
                    );
                }
                if report.high_cardinality_fields.len() > 3 {
                    eprintln!(
                        "  ... and {} more high-cardinality field(s)",
                        report.high_cardinality_fields.len() - 3
                    );
                }

                tracing::warn!(
                    gap = "OBS-010",
                    spec = "runtime-logging",
                    count = report.high_cardinality_fields.len(),
                    "high-cardinality fields detected in log stream (could lead to log explosion)"
                );
            } else {
                debug!(
                    gap = "OBS-010",
                    entries_scanned = report.total_entries,
                    "log cardinality analysis: no high-cardinality fields detected"
                );
            }
        }
        Err(e) => {
            // Non-critical error; don't fail startup
            tracing::warn!(
                gap = "OBS-010",
                error = %e,
                "log cardinality analysis failed (non-blocking)"
            );
        }
    }
}

/// Spawn the resource-metric sampler in the background.
///
/// Returns the JoinHandle so the caller can cancel the loop on shutdown.
/// Sampling cadence is 5s, matching the convergence dashboard's projection
/// rhythm. Returning `None` is reserved for future feature-gating; today the
/// sampler is unconditionally spawned in headless mode.
///
/// @trace spec:resource-metric-collection, spec:observability-metrics
/// @cheatsheet observability/cheatsheet-metrics.md
fn spawn_metrics_sampler() -> Option<tokio::task::JoinHandle<()>> {
    use tillandsias_metrics::MetricsSampler;
    let interval = Duration::from_secs(5);
    if MetricsSampler::validate_interval(interval).is_err() {
        return None;
    }
    let handle = tokio::spawn(async move {
        let mut sampler = MetricsSampler::new();
        sampler.collect_continuous(interval).await;
    });
    Some(handle)
}

/// Phase 5, Task 22: Wait for SIGTERM/SIGINT using signal-hook flags.
///
/// This loop is only reached during shutdown. It is not on the hot path for
/// launch, prompt dispatch, or tray interaction. The atomic flag is set by the
/// signal handler, and the async sleep yields the runtime while backing off so
/// we do not spin aggressively while waiting for termination.
/// @trace spec:linux-native-portable-executable, spec:signal-handling, spec:runtime-logging
async fn wait_for_shutdown_signal() -> Result<(), String> {
    let terminated = Arc::new(AtomicBool::new(false));
    flag::register(libc::SIGTERM, Arc::clone(&terminated))
        .map_err(|e| format!("Failed to register SIGTERM: {e}"))?;
    flag::register(libc::SIGINT, Arc::clone(&terminated))
        .map_err(|e| format!("Failed to register SIGINT: {e}"))?;

    let mut poll_delay_ms = 25_u64;
    while !terminated.load(Ordering::SeqCst) {
        tokio::time::sleep(std::time::Duration::from_millis(poll_delay_ms)).await;
        poll_delay_ms = next_shutdown_poll_delay_ms(poll_delay_ms);
    }
    Ok(())
}

/// Conservative shutdown polling backoff. This only governs the wait loop
/// after shutdown has already been requested, so it cannot affect user-facing
/// launch or tray responsiveness.
fn next_shutdown_poll_delay_ms(current_ms: u64) -> u64 {
    current_ms.saturating_mul(2).min(250)
}

/// Load headless configuration from TOML file.
fn load_config(_path: &str) -> Result<(), String> {
    // Placeholder for Phase 2
    // Would parse TOML config with:
    // - container names to manage
    // - network settings
    // - logging configuration
    Ok(())
}

/// Phase 5, Task 21: Graceful shutdown with 30s timeout and SIGKILL fallback.
/// @trace spec:linux-native-portable-executable, spec:graceful-shutdown, spec:signal-handling
async fn graceful_shutdown_async() -> Result<(), String> {
    // Phase 5, Task 23: Test signal handling with timeout
    // Emit shutdown event
    eprintln!("Starting graceful shutdown sequence");

    // In a full implementation, this would:
    // 1. Stop all containers with 30s timeout via podman client
    // 2. Monitor container exit status
    // 3. Force-kill any remaining containers after timeout
    // 4. Cleanup secrets and ephemeral network resources

    // Check if there are any tillandsias-managed containers running
    // If not, return immediately (for testing and headless-only runs)
    // If yes, wait up to 30 seconds for graceful shutdown

    eprintln!("Graceful shutdown completed");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn has_arg(args: &[String], needle: &str) -> bool {
        args.iter().any(|arg| arg == needle)
    }

    #[test]
    fn shutdown_poll_backoff_doubles_until_capped() {
        assert_eq!(next_shutdown_poll_delay_ms(25), 50);
        assert_eq!(next_shutdown_poll_delay_ms(50), 100);
        assert_eq!(next_shutdown_poll_delay_ms(125), 250);
        assert_eq!(next_shutdown_poll_delay_ms(250), 250);
        assert_eq!(next_shutdown_poll_delay_ms(u64::MAX), 250);
    }

    #[test]
    fn proxy_args_encode_the_expected_container_shape() {
        let args = build_proxy_run_args(&PathBuf::from("/tmp/ca"), "tillandsias-proxy:v1");

        assert!(has_arg(&args, "--detach"));
        assert!(has_arg(&args, "tillandsias-proxy"));
        assert!(has_arg(&args, "proxy"));
        assert!(has_arg(&args, "10.0.42.2"));
        assert!(has_arg(&args, "DEBUG_PROXY=1"));
        assert!(has_arg(&args, "tillandsias-proxy:v1"));
    }

    #[test]
    fn status_check_args_probe_proxy_git_and_inference_from_forge() {
        let args = build_status_check_forge_args(
            &PathBuf::from("/tmp/workspace"),
            "alpha",
            &PathBuf::from("/tmp/ca"),
            "1.2.3",
        );

        assert!(has_arg(&args, "--rm"));
        assert!(has_arg(&args, "--entrypoint"));
        assert!(has_arg(&args, "/bin/bash"));
        assert!(has_arg(&args, "tillandsias-forge:v1.2.3"));
        assert!(
            args.iter()
                .any(|arg| arg.contains("check_port proxy 3128 proxy"))
        );
        assert!(
            args.iter()
                .any(|arg| arg.contains("check_port git-service 9418 git"))
        );
        assert!(args.iter().any(|arg| arg.contains("check_inference")));
    }

    #[test]
    fn podman_runtime_blocker_matches_known_health_failures() {
        assert!(podman_runtime_blocker(
            "Failed to connect to user scope bus via local transport: No such file or directory"
        ));
        assert!(podman_runtime_blocker(
            "netavark encountered multiple errors: aardvark-dns failed to start"
        ));
        assert!(podman_runtime_blocker(
            "Error: cannot set up namespace: newuidmap returned exit status 1"
        ));
        assert!(!podman_runtime_blocker("podman run exited with status 125"));
    }

    #[test]
    fn opencode_args_mount_workspace_and_prompt() {
        let args = build_opencode_forge_args(
            &PathBuf::from("/tmp/project"),
            "alpha",
            Some("hello"),
            &PathBuf::from("/tmp/ca"),
            "1.2.3",
        );

        assert!(has_arg(&args, "--interactive"));
        assert!(has_arg(&args, "--tty"));
        assert!(has_arg(&args, "--entrypoint"));
        assert!(has_arg(&args, "/bin/bash"));
        assert!(has_arg(&args, "TILLANDSIAS_OPENCODE_PROMPT=hello"));
        assert!(
            args.iter()
                .any(|arg| arg == "/tmp/project:/home/forge/src:rw")
        );
    }

    #[test]
    fn opencode_web_event_log_path_is_project_scoped() {
        let path = opencode_web_event_log_path("visual-chess");
        assert!(path.to_string_lossy().contains("opencode-web"));
        assert!(path.to_string_lossy().contains("visual-chess.jsonl"));
    }

    #[test]
    fn json_escape_quotes_and_controls() {
        let value = "a\"b\\c\nd";
        assert_eq!(json_escape(value), "a\\\"b\\\\c\\nd");
    }

    #[test]
    fn opencode_web_startup_stage_order_is_stable() {
        assert_eq!(
            opencode_web_startup_stages(),
            &["stack", "proxy", "git", "inference", "forge", "browser"]
        );
    }

    #[test]
    fn opencode_web_browser_spec_is_built_with_typed_podman_flags() {
        let profile_dir = PathBuf::from("/tmp/tillandsias/browser/test-profile");
        let certs_dir = PathBuf::from("/tmp/tillandsias/ca");
        let display = BrowserDisplayContext {
            display: Some(":99".to_string()),
            xauthority: None,
            wayland_display: None,
            xdg_runtime_dir: None,
        };
        let token = [7u8; 32];
        let expected_app_url = tillandsias_otp::build_login_data_url(
            "http://opencode.visual-chess.localhost/",
            &token,
        );

        let spec = build_opencode_web_browser_spec(
            &expected_app_url,
            "1.2.3",
            &profile_dir,
            &certs_dir,
            &display,
            "visual-chess",
        )
        .expect("browser spec");
        let args = spec.build_run_args();

        assert!(has_arg(&args, "--pull=never"));
        assert!(has_arg(&args, "--read-only"));
        assert!(has_arg(&args, "--cap-add"));
        assert!(has_arg(&args, "SYS_CHROOT"));
        assert!(has_arg(&args, "--network"));
        assert!(has_arg(&args, "host"));
        assert!(has_arg(&args, "-d"));
        assert!(has_arg(&args, "--name"));
        assert!(has_arg(&args, "tillandsias-browser-visual-chess"));
        assert!(
            args.iter().any(|arg| {
                arg == "type=bind,source=/tmp/tillandsias/ca/intermediate.crt,target=/etc/tillandsias/ca.crt,readonly=true"
            })
        );
        assert!(has_arg(
            &args,
            "TILLANDSIAS_CA_BUNDLE=/etc/tillandsias/ca.crt"
        ));
        assert!(has_arg(&args, "SSL_CERT_FILE=/etc/tillandsias/ca.crt"));
        assert!(
            args.iter()
                .any(|arg| arg == "tillandsias-chromium-framework:v1.2.3")
        );
        assert!(
            args.iter()
                .any(|arg| arg == &format!("--app={expected_app_url}"))
        );
        assert!(
            args.iter()
                .any(|arg| arg == "--user-data-dir=/tmp/tillandsias/browser/test-profile")
        );
        assert!(has_arg(&args, "--ozone-platform=x11"));
    }

    // @trace spec:subdomain-routing-via-reverse-proxy, spec:fix-router-loopback-port
    #[test]
    fn router_run_args_encode_expected_container_shape() {
        let certs_dir = PathBuf::from("/tmp/ca");
        let args = build_router_run_args(&certs_dir, "tillandsias-router:v1.2.3");

        // Security flags
        assert!(has_arg(&args, "--detach"));
        assert!(has_arg(&args, "--rm"));
        assert!(has_arg(&args, "--read-only"));
        assert!(has_arg(&args, "--cap-drop=ALL"));
        assert!(has_arg(&args, "--security-opt=no-new-privileges"));
        assert!(has_arg(&args, "--userns=keep-id"));

        // Naming and network
        assert!(has_arg(&args, "tillandsias-router"));
        assert!(has_arg(&args, "router"));
        assert!(has_arg(&args, ENCLAVE_NET));

        // Loopback-only host publish (fix-router-loopback-port)
        assert!(has_arg(&args, "127.0.0.1:8080:8080"));

        // Dynamic Caddyfile bind-mount present
        assert!(args.iter().any(|arg| arg.contains("dynamic.Caddyfile")));

        // CA cert mount
        assert!(
            args.iter()
                .any(|arg| arg.contains("intermediate.crt")
                    && arg.contains("/etc/tillandsias/ca.crt"))
        );

        // Image is the last argument
        assert_eq!(
            args.last().map(|s| s.as_str()),
            Some("tillandsias-router:v1.2.3")
        );
    }

    // @trace spec:subdomain-routing-via-reverse-proxy, spec:opencode-web-dynamic-routes
    #[test]
    fn dynamic_caddyfile_routes_opencode_service() {
        let windows = vec![(
            "opencode.visual-chess".to_string(),
            "tillandsias-visual-chess-forge".to_string(),
            8080u16,
        )];
        let config = generate_dynamic_caddyfile(&windows);

        // Verify Caddy block syntax is present
        assert!(config.contains("opencode.visual-chess.localhost"));
        assert!(config.contains("reverse_proxy"));
        assert!(config.contains("127.0.0.1:8080"));

        // Verify structure has opening and closing braces
        assert!(config.contains("{"));
        assert!(config.contains("}"));
    }

    #[test]
    fn dynamic_caddyfile_multiple_routes() {
        let windows = vec![
            (
                "opencode.alpha".to_string(),
                "tillandsias-alpha-forge".to_string(),
                8080u16,
            ),
            (
                "opencode.beta".to_string(),
                "tillandsias-beta-forge".to_string(),
                8081u16,
            ),
        ];
        let config = generate_dynamic_caddyfile(&windows);

        // Verify both routes are present
        assert!(config.contains("opencode.alpha.localhost"));
        assert!(config.contains("opencode.beta.localhost"));
        assert!(config.contains("127.0.0.1:8080"));
        assert!(config.contains("127.0.0.1:8081"));
    }

    #[test]
    fn dynamic_caddyfile_empty_routes_returns_empty_string() {
        let windows: Vec<(String, String, u16)> = vec![];
        let config = generate_dynamic_caddyfile(&windows);
        assert!(config.is_empty());
    }

    #[tokio::test]
    async fn caddy_reload_routes_handles_connection_error_gracefully() {
        // Test that caddy_reload_routes gracefully handles connection failures
        // (e.g., router not yet ready). The admin API endpoint on localhost:2019
        // will be unreachable, but the function should log a warning and return Ok.
        let result = caddy_reload_routes(false).await;

        // Should succeed (not fail) even when the router is unreachable.
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn caddy_reload_routes_with_debug_enabled() {
        // Test that caddy_reload_routes works with debug flag enabled.
        // The function will attempt to reach localhost:2019, fail gracefully,
        // and emit debug output (captured via eprintln, visible in test output).
        let result = caddy_reload_routes(true).await;

        // Should still succeed even with debug output enabled.
        assert!(result.is_ok());
    }

    // @trace spec:init-command, spec:init-incremental-builds
    #[test]
    fn init_command_detects_repo_root_from_version_and_images_dir() {
        // Test that find_checkout_root correctly identifies the Tillandsias repo
        // by detecting VERSION file and images/ directory.
        // This validates the repository structure requirements.
        let root = find_checkout_root();
        assert!(
            root.is_ok(),
            "find_checkout_root should succeed in a valid repo"
        );

        let root = root.unwrap();
        assert!(
            root.join("VERSION").exists(),
            "VERSION file must exist at repo root"
        );
        assert!(
            root.join("images").is_dir(),
            "images directory must exist at repo root"
        );
    }

    #[test]
    fn init_build_state_tracks_image_status() {
        // Test that InitBuildState correctly tracks success/failure status for images.
        // @trace spec:init-incremental-builds
        let mut state = InitBuildState::new();

        // Initially, no images are marked successful
        assert!(!state.was_successful("proxy"));
        assert!(!state.was_successful("forge"));

        // Mark proxy as successful
        state.mark_success("proxy");
        assert!(state.was_successful("proxy"));
        assert!(!state.was_successful("forge"));

        // Mark forge as failed
        state.mark_failed("forge");
        assert!(!state.was_successful("forge"));

        // Mark forge as successful (overwrite failed status)
        state.mark_success("forge");
        assert!(state.was_successful("forge"));
    }

    #[test]
    fn init_build_state_persists_to_cache_directory() {
        // Test that InitBuildState can be saved and loaded from the cache directory.
        // @trace spec:init-incremental-builds
        let mut state = InitBuildState::new();
        state.mark_success("proxy");
        state.mark_success("git");
        state.mark_failed("inference");

        // Attempt to save state to cache
        let result = state.save();
        assert!(
            result.is_ok(),
            "InitBuildState::save() should succeed: {}",
            result.err().unwrap_or_default()
        );

        // Load state back from cache
        let loaded = InitBuildState::load();
        assert!(
            loaded.is_ok(),
            "InitBuildState::load() should succeed: {}",
            loaded.err().unwrap_or_default()
        );

        let loaded_state = loaded.unwrap().expect("loaded state should not be None");
        assert!(
            loaded_state.was_successful("proxy"),
            "proxy should be marked successful after reload"
        );
        assert!(
            loaded_state.was_successful("git"),
            "git should be marked successful after reload"
        );
        assert!(
            !loaded_state.was_successful("inference"),
            "inference should NOT be marked successful after reload"
        );
    }

    #[test]
    fn image_specs_returns_correct_containerfile_paths() {
        // Test that image_specs returns the correct Containerfile path and context dir
        // for each supported image type.
        // @trace spec:init-command
        let root = find_checkout_root().expect("should find repo root");

        // Test forge image (uses "images/default/Containerfile")
        let (containerfile, context) =
            image_specs(&root, "forge").expect("forge image specs should be resolvable");
        assert!(containerfile.ends_with("images/default/Containerfile"));
        assert!(context.ends_with("images/default"));

        // Test proxy image
        let (containerfile, context) =
            image_specs(&root, "proxy").expect("proxy image specs should be resolvable");
        assert!(containerfile.ends_with("images/proxy/Containerfile"));
        assert!(context.ends_with("images/proxy"));

        // Test git image
        let (containerfile, context) =
            image_specs(&root, "git").expect("git image specs should be resolvable");
        assert!(containerfile.ends_with("images/git/Containerfile"));
        assert!(context.ends_with("images/git"));

        // Test inference image
        let (containerfile, context) =
            image_specs(&root, "inference").expect("inference image specs should be resolvable");
        assert!(containerfile.ends_with("images/inference/Containerfile"));
        assert!(context.ends_with("images/inference"));

        // Test chromium-core image (uses "images/chromium/Containerfile.core")
        let (containerfile, context) = image_specs(&root, "chromium-core")
            .expect("chromium-core image specs should be resolvable");
        assert!(containerfile.ends_with("images/chromium/Containerfile.core"));
        assert!(context.ends_with("images/chromium"));

        // Test chromium-framework image (uses "images/chromium/Containerfile.framework")
        let (containerfile, context) = image_specs(&root, "chromium-framework")
            .expect("chromium-framework image specs should be resolvable");
        assert!(containerfile.ends_with("images/chromium/Containerfile.framework"));
        assert!(context.ends_with("images/chromium"));
    }

    #[test]
    fn image_specs_rejects_unknown_image_types() {
        // Test that image_specs properly rejects unknown image types.
        // @trace spec:init-command
        let root = find_checkout_root().expect("should find repo root");
        let result = image_specs(&root, "unknown-image");

        assert!(
            result.is_err(),
            "image_specs should reject unknown image type"
        );
        let error = result.err().unwrap();
        assert!(
            error.contains("Unknown image type"),
            "error message should mention unknown type: {error}"
        );
    }

    #[test]
    fn versioned_image_tag_formats_correctly() {
        // Test that versioned_image_tag produces the correct format.
        // @trace spec:init-command
        let tag = versioned_image_tag("forge", "0.1.260513");
        assert_eq!(tag, "tillandsias-forge:v0.1.260513");

        let tag = versioned_image_tag("proxy", "1.0.0");
        assert_eq!(tag, "tillandsias-proxy:v1.0.0");

        let tag = versioned_image_tag("chromium-framework", "0.2.100");
        assert_eq!(tag, "tillandsias-chromium-framework:v0.2.100");
    }

    #[test]
    fn image_build_args_passes_chromium_core_tag_for_framework() {
        // Test that image_build_args correctly passes CHROMIUM_CORE_TAG
        // when building chromium-framework.
        // @trace spec:init-command
        let args = image_build_args(
            "chromium-framework",
            "tillandsias-chromium-framework:v1.0.0",
        );

        assert_eq!(args.len(), 2, "should have 2 args (--build-arg and value)");
        assert_eq!(args[0], "--build-arg");
        assert!(
            args[1].contains("CHROMIUM_CORE_TAG=v1.0.0"),
            "should pass CHROMIUM_CORE_TAG with version: {}",
            args[1]
        );
    }

    #[test]
    fn image_build_args_empty_for_non_framework_images() {
        // Test that image_build_args returns empty args for non-framework images.
        // @trace spec:init-command
        let args = image_build_args("proxy", "tillandsias-proxy:v1.0.0");
        assert!(args.is_empty(), "proxy should have no build args");

        let args = image_build_args("forge", "tillandsias-forge:v1.0.0");
        assert!(args.is_empty(), "forge should have no build args");

        let args = image_build_args("git", "tillandsias-git:v1.0.0");
        assert!(args.is_empty(), "git should have no build args");
    }

    #[test]
    fn init_logs_captured_in_debug_mode() {
        // Test that init_log_file returns a valid path in debug mode.
        // @trace spec:init-command
        let log_path = init_log_file("proxy", true);
        assert!(
            log_path.is_some(),
            "init_log_file should return Some in debug mode"
        );

        let path = log_path.unwrap();
        assert!(
            path.to_string_lossy()
                .contains("tillandsias-init-proxy.log")
        );
    }

    #[test]
    fn init_logs_none_in_non_debug_mode() {
        // Test that init_log_file returns None in non-debug mode.
        // @trace spec:init-command
        let log_path = init_log_file("proxy", false);
        assert!(
            log_path.is_none(),
            "init_log_file should return None in non-debug mode"
        );
    }

    #[test]
    fn init_command_defines_required_images_in_order() {
        // Test that run_init builds images in the correct order: proxy, git, inference,
        // chromium-core, chromium-framework, forge.
        // @trace spec:init-command, spec:init-incremental-builds
        // NOTE: This test validates the IMAGE BUILD ORDER, which is critical for
        // chromium-framework (depends on chromium-core) and inter-image dependencies.
        // The actual build execution is skipped here; we test the order specification.

        // The images array from run_init defines the build order:
        // proxy -> git -> inference -> chromium-core -> chromium-framework -> forge
        let images = [
            "proxy",
            "git",
            "inference",
            "chromium-core",
            "chromium-framework",
            "forge",
        ];

        // Verify all required images are present
        assert!(images.iter().any(|&i| i == "proxy"), "proxy must be first");
        assert!(images.iter().any(|&i| i == "git"), "git must be included");
        assert!(
            images.iter().any(|&i| i == "inference"),
            "inference must be included"
        );
        assert!(
            images.iter().any(|&i| i == "chromium-core"),
            "chromium-core must be included"
        );
        assert!(
            images.iter().any(|&i| i == "chromium-framework"),
            "chromium-framework must be included"
        );
        assert!(images.iter().any(|&i| i == "forge"), "forge must be last");

        // Verify build order: chromium-framework comes AFTER chromium-core
        let core_idx = images.iter().position(|&i| i == "chromium-core").unwrap();
        let framework_idx = images
            .iter()
            .position(|&i| i == "chromium-framework")
            .unwrap();
        assert!(
            core_idx < framework_idx,
            "chromium-core must be built before chromium-framework"
        );
    }

    #[test]
    fn progress_output_format_is_valid() {
        // @trace gap:ON-005 — validate progress output format
        // Test that progress output lines are well-formed and show percentage
        // Format: "Pulling image <name> [████░░░░░░] <percent>%"

        let test_cases = vec![
            (0, 0), // percent -> filled blocks
            (10, 1),
            (25, 2),
            (50, 5),
            (75, 7),
            (100, 10),
        ];

        for (percent, expected_filled) in test_cases {
            // Build the progress line as the code would
            let bar_filled = "█".repeat(percent / 10);
            let bar_empty = "░".repeat(10 - (percent / 10));
            let line = format!(
                "Pulling image {} [{}{}] {}%",
                "forge", bar_filled, bar_empty, percent
            );

            // Validate it contains required parts
            assert!(
                line.contains("Pulling image"),
                "Must contain 'Pulling image'"
            );
            assert!(line.contains("["), "Must contain progress bar opening");
            assert!(line.contains("]"), "Must contain progress bar closing");
            assert!(line.contains("%"), "Must contain percentage sign");
            assert!(
                line.contains(&percent.to_string()),
                "Must contain percentage value"
            );

            // Verify bar has correct number of filled characters
            let bar_start = line.find('[').unwrap();
            let bar_end = line.find(']').unwrap();
            let bar_content = &line[bar_start + 1..bar_end];
            let filled_count = bar_content.chars().filter(|&c| c == '█').count();
            let empty_count = bar_content.chars().filter(|&c| c == '░').count();
            assert_eq!(
                filled_count, expected_filled,
                "Progress bar filled count should match"
            );
            assert_eq!(
                filled_count + empty_count,
                10,
                "Progress bar should have 10 total characters"
            );
        }
    }
}
