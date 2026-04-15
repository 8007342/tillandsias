//! Background tools overlay management — version checking, atomic rotation, and updates.
//!
//! Phase 1 (complete): `ensure_tools_overlay()` builds the overlay on first launch.
//! Phase 2 (this module): background version checks, rate-limited updates, atomic
//! directory rotation, and forge image version enforcement.
//!
//! # Design
//!
//! - Version checks use `npm view` (npm tools) and GitHub Releases API (OpenCode).
//! - Checks are rate-limited to once per 24 hours via a `.last-update-check` stamp file.
//! - Rebuilds create a new versioned directory (`v<N+1>/`), build the overlay, then
//!   atomically swap the `current` symlink. Running containers are unaffected (they
//!   hold the old bind-mount).
//! - Forge image version mismatches trigger a BLOCKING rebuild (binary compatibility).
//!
//! @trace spec:layered-tools-overlay

use std::collections::HashMap;
use std::path::Path;

use serde::{Deserialize, Serialize};
use tracing::{debug, error, info, warn};

use tillandsias_core::config::cache_dir;

use crate::handlers::{forge_image_tag, send_notification};
use crate::i18n;

// ---------------------------------------------------------------------------
// Manifest types
// @trace spec:layered-tools-overlay
// ---------------------------------------------------------------------------

/// Manifest describing the contents of a tools overlay directory.
///
/// Written as `.manifest.json` inside each versioned overlay directory
/// (e.g., `~/.cache/tillandsias/tools-overlay/v1/.manifest.json`).
///
/// @trace spec:layered-tools-overlay
#[derive(Debug, Serialize, Deserialize)]
pub(crate) struct ToolsManifest {
    /// Overlay format version (always 1 for now).
    pub version: u32,
    /// ISO 8601 timestamp when the overlay was built.
    pub created: String,
    /// Forge image tag used to build the overlay (e.g., "tillandsias-forge:v0.1.97.83").
    pub forge_image: String,
    /// Per-tool version and install timestamp.
    pub tools: HashMap<String, ToolEntry>,
}

/// A single tool entry in the tools manifest.
///
/// @trace spec:layered-tools-overlay
#[derive(Debug, Serialize, Deserialize)]
pub(crate) struct ToolEntry {
    /// Tool version string (e.g., "1.0.34").
    pub version: String,
    /// ISO 8601 timestamp when this tool was installed.
    pub installed: String,
}

// ---------------------------------------------------------------------------
// Manifest I/O
// @trace spec:layered-tools-overlay
// ---------------------------------------------------------------------------

/// Read the tools manifest from a versioned overlay directory.
///
/// Expects `.manifest.json` to exist in `dir`. Returns `Err` if the file
/// is missing or unparseable.
///
/// @trace spec:layered-tools-overlay
pub(crate) fn read_manifest(dir: &Path) -> Result<ToolsManifest, String> {
    let path = dir.join(".manifest.json");
    let content = std::fs::read_to_string(&path)
        .map_err(|e| format!("Cannot read manifest at {}: {e}", path.display()))?;
    serde_json::from_str(&content)
        .map_err(|e| format!("Cannot parse manifest at {}: {e}", path.display()))
}

/// Write a tools manifest to a versioned overlay directory.
///
/// Creates `.manifest.json` in `dir`, pretty-printed for human readability.
///
/// @trace spec:layered-tools-overlay
pub(crate) fn write_manifest(dir: &Path, manifest: &ToolsManifest) -> Result<(), String> {
    let path = dir.join(".manifest.json");
    let json = serde_json::to_string_pretty(manifest)
        .map_err(|e| format!("Cannot serialize manifest: {e}"))?;
    std::fs::write(&path, json)
        .map_err(|e| format!("Cannot write manifest to {}: {e}", path.display()))
}

// ---------------------------------------------------------------------------
// Timestamp + version helpers
// @trace spec:layered-tools-overlay
// ---------------------------------------------------------------------------

/// Get the current timestamp in ISO 8601 format (UTC).
///
/// Uses the system `date` command, falling back to "unknown" on failure.
pub(crate) fn iso8601_now() -> String {
    std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        })
        .unwrap_or_else(|| "unknown".to_string())
}

/// Probe a tool binary for its version string.
///
/// Runs `<binary> <args>` and returns the trimmed stdout, or "unknown" on failure.
/// @trace spec:layered-tools-overlay
pub(crate) fn probe_tool_version(binary: &Path, args: &[&str]) -> String {
    std::process::Command::new(binary)
        .args(args)
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        })
        .unwrap_or_else(|| "unknown".to_string())
}

// ---------------------------------------------------------------------------
// Proxy health (synchronous — for init/blocking paths)
// @trace spec:proxy-container
// ---------------------------------------------------------------------------

/// Synchronous proxy health check for use in non-async contexts.
///
/// Runs `podman exec tillandsias-proxy nc -z localhost 3128` and returns `true`
/// if squid is listening on port 3128. Used by `build_overlay_for_init()` which
/// runs outside a tokio runtime.
///
/// DISTRO: Proxy is Alpine — busybox nc (netcat) is built-in.
/// wget --spider returns 400 because squid rejects non-proxy requests.
///
/// @trace spec:proxy-container
fn is_proxy_healthy_sync() -> bool {
    let result = tillandsias_podman::podman_cmd_sync()
        .args(["exec", "tillandsias-proxy", "sh", "-c", "nc -z localhost 3128"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    result.map(|s| s.success()).unwrap_or(false)
}

// ---------------------------------------------------------------------------
// Phase 1 entry points (moved from handlers.rs)
// @trace spec:layered-tools-overlay
// ---------------------------------------------------------------------------

/// Ensure the tools overlay directory exists and is up to date.
///
/// On first launch: runs the builder script (blocking).
/// On subsequent launches: validates the `current` symlink exists and checks
/// the forge image version. If the forge image has changed, triggers a
/// BLOCKING rebuild (binary compatibility requires matching images).
///
/// Returns `Ok(())` on success or if the overlay is usable (even if stale).
/// Returns `Err` only on first-launch build failure.
///
/// @trace spec:layered-tools-overlay
pub(crate) async fn ensure_tools_overlay(
    build_tx: tokio::sync::mpsc::Sender<tillandsias_core::event::BuildProgressEvent>,
) -> Result<(), String> {
    let cache = cache_dir();
    let overlay_dir = cache.join("tools-overlay");
    let current = overlay_dir.join("current");

    // If current symlink exists and points to a valid directory, check versions
    if current.exists() && current.is_dir() {
        // P2-5: Forge image version comparison — BLOCKING rebuild if mismatched
        if let Ok(manifest) = read_manifest(&current) {
            let expected_tag = forge_image_tag();
            if manifest.forge_image != expected_tag {
                info!(
                    old = %manifest.forge_image,
                    new = %expected_tag,
                    spec = "layered-tools-overlay",
                    "Forge image changed — triggering blocking tools overlay rebuild"
                );
                // @trace spec:layered-tools-overlay
                // Forge image mismatch = binary incompatibility risk.
                // Must rebuild BLOCKING before launching containers.
                // User-friendly chip name — never expose "overlay" to users.
                let chip_name = i18n::t("menu.build.chip_software_layer").to_string();
                let _ = build_tx.try_send(tillandsias_core::event::BuildProgressEvent::Started {
                    image_name: chip_name.clone(),
                });
                let result = rebuild_tools_overlay(&overlay_dir).await;
                match &result {
                    Ok(()) => {
                        let _ = build_tx.try_send(tillandsias_core::event::BuildProgressEvent::Completed {
                            image_name: chip_name,
                        });
                    }
                    Err(reason) => {
                        let _ = build_tx.try_send(tillandsias_core::event::BuildProgressEvent::Failed {
                            image_name: chip_name,
                            reason: reason.clone(),
                        });
                    }
                }
                return result;
            }
        }
        debug!(
            spec = "layered-tools-overlay",
            overlay = %current.display(),
            "Tools overlay ready"
        );
        return Ok(());
    }

    // First launch — build the overlay (blocking)
    info!(
        accountability = true,
        category = "tools",
        spec = "layered-tools-overlay",
        "Building tools overlay (first time)..."
    );
    // @trace spec:layered-tools-overlay
    // User-friendly chip name — never expose "overlay" to users.
    let chip_name = i18n::t("menu.build.chip_software_layer").to_string();
    let _ = build_tx.try_send(tillandsias_core::event::BuildProgressEvent::Started {
        image_name: chip_name.clone(),
    });
    let result = build_tools_overlay_versioned(&overlay_dir, "v1").await;
    match &result {
        Ok(()) => {
            let _ = build_tx.try_send(tillandsias_core::event::BuildProgressEvent::Completed {
                image_name: chip_name,
            });
        }
        Err(reason) => {
            let _ = build_tx.try_send(tillandsias_core::event::BuildProgressEvent::Failed {
                image_name: chip_name,
                reason: reason.clone(),
            });
        }
    }
    result
}

/// Build the tools overlay by running `build-tools-overlay.sh` in a
/// blocking subprocess, creating a specific versioned directory.
///
/// Steps:
/// 1. Create the versioned directory
/// 2. Extract embedded scripts to temp
/// 3. Run `scripts/build-tools-overlay.sh <version-dir> <forge-image-tag>`
/// 4. Write `.manifest.json` with tool versions
/// 5. Create/swap the `current` symlink
///
/// @trace spec:layered-tools-overlay
async fn build_tools_overlay_versioned(
    overlay_dir: &Path,
    version_name: &str,
) -> Result<(), String> {
    let overlay_dir = overlay_dir.to_path_buf();
    let version_name = version_name.to_string();
    let forge_tag = forge_image_tag();

    // @trace spec:proxy-container, spec:layered-tools-overlay
    // Check proxy health BEFORE entering the blocking build.
    // If the proxy is not responding, the builder script must NOT join
    // the enclave network (which has no default internet route).
    // We signal this by omitting CA_CHAIN_PATH — the script uses its
    // presence to decide between enclave routing and direct access.
    let proxy_healthy = crate::handlers::is_proxy_healthy().await;
    if !proxy_healthy {
        warn!(
            spec = "layered-tools-overlay",
            "Proxy not healthy — tools overlay will use direct network access"
        );
    }

    tokio::task::spawn_blocking(move || {
        build_overlay_sync(&overlay_dir, &version_name, &forge_tag, proxy_healthy)
    })
    .await
    .map_err(|e| format!("Tools overlay build task panicked: {e}"))?
}

/// Synchronous overlay build — runs the builder script and writes manifest.
///
/// Extracted so both first-launch and background-rebuild can share logic.
///
/// `proxy_healthy`: when `true`, the CA chain is passed to the builder script
/// so it routes through the enclave proxy. When `false`, the builder uses
/// direct network access (default bridge network, no proxy).
///
/// @trace spec:layered-tools-overlay
fn build_overlay_sync(
    overlay_dir: &Path,
    version_name: &str,
    forge_tag: &str,
    proxy_healthy: bool,
) -> Result<(), String> {
    // Step 1: Create versioned directory
    let version_dir = overlay_dir.join(version_name);
    std::fs::create_dir_all(&version_dir).map_err(|e| {
        format!(
            "Cannot create overlay directory {}: {e}",
            version_dir.display()
        )
    })?;

    // Step 2: Extract embedded scripts
    let source_dir = crate::embedded::write_image_sources().map_err(|e| {
        error!(error = %e, spec = "layered-tools-overlay", "Failed to extract embedded scripts");
        format!("Failed to extract embedded scripts: {e}")
    })?;

    // Step 3: Run the builder
    info!(
        output = %version_dir.display(),
        forge_image = %forge_tag,
        spec = "layered-tools-overlay",
        "Running tools overlay builder"
    );

    // @trace spec:proxy-container, spec:layered-tools-overlay
    let ca_chain = crate::ca::proxy_certs_dir().join("ca-chain.crt");

    #[cfg(not(target_os = "windows"))]
    let output = {
        // Unix: run build-tools-overlay.sh bash script
        let script = source_dir.join("scripts").join("build-tools-overlay.sh");
        if !script.exists() {
            crate::embedded::cleanup_image_sources();
            return Err(format!(
                "build-tools-overlay.sh not found at {}",
                script.display()
            ));
        }

        let mut cmd = std::process::Command::new(&script);
        cmd.arg(version_dir.to_str().unwrap_or_default())
            .arg(forge_tag)
            .env_remove("LD_LIBRARY_PATH")
            .env_remove("LD_PRELOAD")
            .env("PODMAN_PATH", tillandsias_podman::find_podman_path())
            .env("TOOLS_OVERLAY_QUIET", "1");

        if proxy_healthy && ca_chain.exists() {
            cmd.env("CA_CHAIN_PATH", &ca_chain);
        } else if !proxy_healthy {
            info!(spec = "layered-tools-overlay", "Proxy unhealthy — builder will use direct network access");
        }

        cmd.output().map_err(|e| {
            error!(error = %e, spec = "layered-tools-overlay", "Failed to launch build script");
            format!("Failed to launch build-tools-overlay.sh: {e}")
        })?
    };

    #[cfg(target_os = "windows")]
    let output = {
        // Windows: run the same bash script via WSL (Windows Subsystem for Linux).
        // WSL is required by podman on Windows anyway (podman machine uses WSL2),
        // so it's always available. This ensures the SAME script runs on all
        // platforms — no separate Windows code path.
        // @trace spec:layered-tools-overlay, spec:cross-platform
        let script = source_dir.join("scripts").join("build-tools-overlay.sh");
        if !script.exists() {
            crate::embedded::cleanup_image_sources();
            return Err(format!(
                "build-tools-overlay.sh not found at {}",
                script.display()
            ));
        }

        // Convert Windows paths to WSL paths: C:\Users\foo → /mnt/c/Users/foo
        let to_wsl_path = |p: &std::path::Path| -> String {
            let s = p.to_str().unwrap_or_default().replace('\\', "/");
            if let Some(rest) = s.strip_prefix("C:/") {
                format!("/mnt/c/{rest}")
            } else if let Some(rest) = s.strip_prefix("D:/") {
                format!("/mnt/d/{rest}")
            } else if s.len() >= 3 && s.as_bytes()[1] == b':' && s.as_bytes()[2] == b'/' {
                let drive = (s.as_bytes()[0] as char).to_ascii_lowercase();
                format!("/mnt/{drive}/{}", &s[3..])
            } else {
                s
            }
        };

        let wsl_script = to_wsl_path(&script);
        let wsl_version_dir = to_wsl_path(&version_dir);

        info!(
            spec = "layered-tools-overlay",
            "Windows: running build-tools-overlay.sh via WSL"
        );

        let mut cmd = std::process::Command::new("wsl");
        cmd.args(["bash", &wsl_script, &wsl_version_dir, forge_tag])
            .env("PODMAN_PATH", tillandsias_podman::find_podman_path())
            .env("TOOLS_OVERLAY_QUIET", "1");

        if proxy_healthy && ca_chain.exists() {
            cmd.env("CA_CHAIN_PATH", to_wsl_path(&ca_chain));
        } else if !proxy_healthy {
            info!(spec = "layered-tools-overlay", "Proxy unhealthy — builder will use direct network access");
        }

        cmd.output().map_err(|e| {
            error!(error = %e, spec = "layered-tools-overlay", "Failed to launch build script via WSL");
            format!("Failed to launch build-tools-overlay.sh via WSL: {e}")
        })?
    };

    crate::embedded::cleanup_image_sources();

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        error!(
            exit_code = output.status.code().unwrap_or(-1),
            stdout = %stdout,
            stderr = %stderr,
            spec = "layered-tools-overlay",
            "build-tools-overlay.sh failed"
        );
        // Clean up the failed version directory
        let _ = std::fs::remove_dir_all(&version_dir);
        return Err(format!(
            "Tools overlay build failed (exit {})",
            output.status.code().unwrap_or(-1)
        ));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    debug!(output = %stdout, spec = "layered-tools-overlay", "build-tools-overlay.sh completed");

    // Step 4: Write manifest
    let now = iso8601_now();
    let manifest = ToolsManifest {
        version: 1,
        created: now.clone(),
        forge_image: forge_tag.to_string(),
        tools: {
            let mut map = HashMap::new();
            let claude_ver = probe_tool_version(
                &version_dir.join("claude").join("bin").join("claude"),
                &["--version"],
            );
            let openspec_ver = probe_tool_version(
                &version_dir.join("openspec").join("bin").join("openspec"),
                &["--version"],
            );
            let opencode_ver = probe_tool_version(
                &version_dir.join("opencode").join("bin").join("opencode"),
                &["--version"],
            );

            map.insert(
                "claude".to_string(),
                ToolEntry {
                    version: claude_ver,
                    installed: now.clone(),
                },
            );
            map.insert(
                "openspec".to_string(),
                ToolEntry {
                    version: openspec_ver,
                    installed: now.clone(),
                },
            );
            map.insert(
                "opencode".to_string(),
                ToolEntry {
                    version: opencode_ver,
                    installed: now,
                },
            );
            map
        },
    };

    write_manifest(&version_dir, &manifest)?;
    info!(
        spec = "layered-tools-overlay",
        forge_image = %manifest.forge_image,
        "Wrote tools overlay manifest"
    );

    // Step 5: Create/swap `current` symlink
    swap_current_symlink(overlay_dir, version_name)?;

    info!(
        accountability = true,
        category = "tools",
        spec = "layered-tools-overlay",
        overlay = %version_dir.display(),
        "Tools overlay built and ready"
    );

    Ok(())
}

/// Atomically swap the `current` symlink to point at a new version directory.
///
/// On Unix: creates a temp symlink then renames it (atomic on same filesystem).
/// On Windows: removes old symlink then creates new one (not atomic, but best-effort).
///
/// @trace spec:layered-tools-overlay
fn swap_current_symlink(overlay_dir: &Path, target: &str) -> Result<(), String> {
    let current_link = overlay_dir.join("current");

    #[cfg(unix)]
    {
        // Atomic swap: create temp symlink, then rename over the existing one.
        let tmp_link = overlay_dir.join(".current.tmp");
        let _ = std::fs::remove_file(&tmp_link);
        std::os::unix::fs::symlink(target, &tmp_link)
            .map_err(|e| format!("Cannot create temp symlink: {e}"))?;
        std::fs::rename(&tmp_link, &current_link)
            .map_err(|e| format!("Cannot swap current symlink: {e}"))?;
    }

    #[cfg(windows)]
    {
        let _ = std::fs::remove_file(&current_link);
        std::os::windows::fs::symlink_dir(target, &current_link)
            .map_err(|e| format!("Cannot create current symlink: {e}"))?;
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// P2-1: Version checking functions
// @trace spec:layered-tools-overlay
// ---------------------------------------------------------------------------

/// Check latest versions of overlay tools from upstream registries.
///
/// Uses `npm view` for npm packages and the GitHub Releases API for OpenCode.
/// All checks are async and non-blocking. Individual failures are logged and
/// skipped — partial results are returned.
///
/// @trace spec:layered-tools-overlay
async fn check_latest_tool_versions() -> HashMap<String, String> {
    let mut versions = HashMap::new();

    // Run npm checks in parallel with the GitHub check
    let (claude_result, openspec_result, opencode_result) = tokio::join!(
        npm_latest_version("@anthropic-ai/claude-code"),
        npm_latest_version("@fission-ai/openspec"),
        github_latest_release("nicholasgriffintn/opencode"),
    );

    if let Ok(v) = claude_result {
        versions.insert("claude".to_string(), v);
    }
    if let Ok(v) = openspec_result {
        versions.insert("openspec".to_string(), v);
    }
    if let Ok(v) = opencode_result {
        versions.insert("opencode".to_string(), v);
    }

    versions
}

/// Query the npm registry for the latest version of a package.
///
/// Runs `npm view <package> version` via `tokio::process::Command`.
/// Returns the version string (e.g., "1.0.34") or an error.
///
/// @trace spec:layered-tools-overlay
async fn npm_latest_version(package: &str) -> Result<String, String> {
    let output = tokio::process::Command::new("npm")
        .args(["view", package, "version"])
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        .output()
        .await
        .map_err(|e| format!("npm view {package} failed: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("npm view {package} failed: {stderr}"));
    }

    let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if version.is_empty() {
        return Err(format!("npm view {package} returned empty version"));
    }

    debug!(
        package = %package,
        version = %version,
        spec = "layered-tools-overlay",
        "npm latest version"
    );
    Ok(version)
}

/// Query the GitHub Releases API for the latest release tag.
///
/// Uses `reqwest` with rustls — no system libcurl involved, safe inside AppImage.
/// Returns the tag name stripped of leading "v" (e.g., "0.5.2").
///
/// @trace spec:layered-tools-overlay
async fn github_latest_release(repo: &str) -> Result<String, String> {
    let url = format!("https://api.github.com/repos/{repo}/releases/latest");

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .user_agent("tillandsias")
        .build()
        .map_err(|e| format!("Failed to build HTTP client: {e}"))?;

    let response = client
        .get(&url)
        .header("Accept", "application/vnd.github.v3+json")
        .send()
        .await
        .map_err(|e| format!("GitHub API request failed for {repo}: {e}"))?;

    if !response.status().is_success() {
        return Err(format!(
            "GitHub API returned {} for {repo}",
            response.status()
        ));
    }

    // Parse just the tag_name field from the JSON response
    #[derive(Deserialize)]
    struct Release {
        tag_name: String,
    }

    let release: Release = response
        .json()
        .await
        .map_err(|e| format!("Failed to parse GitHub release for {repo}: {e}"))?;

    // Strip leading "v" if present (e.g., "v0.5.2" -> "0.5.2")
    let version = release
        .tag_name
        .strip_prefix('v')
        .unwrap_or(&release.tag_name)
        .to_string();

    debug!(
        repo = %repo,
        version = %version,
        spec = "layered-tools-overlay",
        "GitHub latest release"
    );
    Ok(version)
}

// ---------------------------------------------------------------------------
// P2-2: Rate limiting (24-hour check interval)
// @trace spec:layered-tools-overlay
// ---------------------------------------------------------------------------

/// Duration between version checks (24 hours).
const CHECK_INTERVAL: std::time::Duration = std::time::Duration::from_secs(24 * 60 * 60);

/// Name of the stamp file recording the last check time.
const LAST_CHECK_STAMP: &str = ".last-update-check";

/// Check whether enough time has passed since the last version check.
///
/// Reads the modification time of the stamp file. Returns `true` if the file
/// is missing, unreadable, or older than `CHECK_INTERVAL`.
///
/// @trace spec:layered-tools-overlay
fn should_check_versions(overlay_dir: &Path) -> bool {
    let stamp = overlay_dir.join(LAST_CHECK_STAMP);
    match std::fs::metadata(&stamp) {
        Ok(meta) => {
            match meta.modified() {
                Ok(modified) => {
                    let elapsed = modified.elapsed().unwrap_or(CHECK_INTERVAL);
                    if elapsed < CHECK_INTERVAL {
                        debug!(
                            spec = "layered-tools-overlay",
                            hours_since_check = elapsed.as_secs() / 3600,
                            "Skipping version check — too recent"
                        );
                        return false;
                    }
                    true
                }
                // Can't read mtime — check anyway
                Err(_) => true,
            }
        }
        // Stamp file missing — first check
        Err(_) => true,
    }
}

/// Update the stamp file to record that a version check just happened.
///
/// @trace spec:layered-tools-overlay
fn touch_check_stamp(overlay_dir: &Path) {
    let stamp = overlay_dir.join(LAST_CHECK_STAMP);
    // Create or truncate the file — its mtime becomes "now".
    if let Err(e) = std::fs::File::create(&stamp) {
        warn!(
            error = %e,
            spec = "layered-tools-overlay",
            "Failed to update check stamp file"
        );
    }
}

// ---------------------------------------------------------------------------
// P2-3: Background overlay rebuild with atomic rotation
// @trace spec:layered-tools-overlay
// ---------------------------------------------------------------------------

/// Determine the next version number by scanning existing `v<N>` directories.
///
/// @trace spec:layered-tools-overlay
fn next_version_number(overlay_dir: &Path) -> u32 {
    let mut max = 0u32;
    if let Ok(entries) = std::fs::read_dir(overlay_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if let Some(num_str) = name.strip_prefix('v')
                && let Ok(num) = num_str.parse::<u32>()
            {
                max = max.max(num);
            }
        }
    }
    max + 1
}

/// Determine what the `current` symlink points to (e.g., "v1").
///
/// Returns `None` if the symlink doesn't exist or can't be read.
///
/// @trace spec:layered-tools-overlay
fn current_version_name(overlay_dir: &Path) -> Option<String> {
    let current = overlay_dir.join("current");
    std::fs::read_link(&current)
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().to_string()))
}

/// Clean up old version directories, keeping only the current version.
///
/// Each overlay version is ~234MB. Previously we kept current + one rollback,
/// but that wastes ~234MB of disk. If the current version is broken, a
/// rebuild is fast enough that a rollback slot isn't worth the storage cost.
///
/// @trace spec:layered-tools-overlay
fn prune_old_versions(overlay_dir: &Path) {
    let current_target = current_version_name(overlay_dir);
    let mut versions: Vec<(u32, String)> = Vec::new();

    if let Ok(entries) = std::fs::read_dir(overlay_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy().to_string();
            if let Some(num_str) = name_str.strip_prefix('v')
                && let Ok(num) = num_str.parse::<u32>()
            {
                versions.push((num, name_str));
            }
        }
    }

    // Sort descending — highest version first
    versions.sort_by(|a, b| b.0.cmp(&a.0));

    // Keep only 1 version (current), delete everything else
    for (_, name) in versions.iter().skip(1) {
        // Never delete the current target
        if current_target.as_deref() == Some(name.as_str()) {
            continue;
        }
        let dir = overlay_dir.join(name);
        if dir.is_dir() {
            info!(
                spec = "layered-tools-overlay",
                version = %name,
                "Pruning old tools overlay version"
            );
            if let Err(e) = std::fs::remove_dir_all(&dir) {
                warn!(
                    error = %e,
                    version = %name,
                    spec = "layered-tools-overlay",
                    "Failed to prune old overlay version"
                );
            }
        }
    }
}

/// Rebuild the tools overlay into a new versioned directory and atomically
/// swap the `current` symlink.
///
/// Used for both forge-image-mismatch (blocking) and background updates.
///
/// @trace spec:layered-tools-overlay
async fn rebuild_tools_overlay(overlay_dir: &Path) -> Result<(), String> {
    let next = next_version_number(overlay_dir);
    let version_name = format!("v{next}");

    info!(
        spec = "layered-tools-overlay",
        version = %version_name,
        "Rebuilding tools overlay"
    );

    build_tools_overlay_versioned(overlay_dir, &version_name).await?;

    // Prune old versions (keep only current)
    prune_old_versions(overlay_dir);

    Ok(())
}

// ---------------------------------------------------------------------------
// Synchronous init-time entry point
// @trace spec:layered-tools-overlay, spec:init-command
// ---------------------------------------------------------------------------

/// Build the tools overlay synchronously for `--init` and tray startup.
///
/// Checks if the current overlay matches the forge image tag. If not (or if
/// no overlay exists), builds it. Returns `Ok(())` on success, `Err` on
/// build failure. Non-fatal — callers should log and continue.
///
/// This does NOT require a tokio runtime or a build_tx channel.
///
/// @trace spec:layered-tools-overlay, spec:init-command
pub fn build_overlay_for_init() -> Result<(), String> {
    let cache = cache_dir();
    let overlay_dir = cache.join("tools-overlay");
    let current = overlay_dir.join("current");

    let expected_tag = forge_image_tag();

    // Check if current overlay exists and matches the forge image
    if current.exists() && current.is_dir() {
        if let Ok(manifest) = read_manifest(&current) {
            if manifest.forge_image == expected_tag {
                info!(
                    spec = "layered-tools-overlay",
                    "Tools overlay already up to date for {expected_tag}"
                );
                return Ok(());
            }
            info!(
                old = %manifest.forge_image,
                new = %expected_tag,
                spec = "layered-tools-overlay",
                "Tools overlay stale — rebuilding for new forge image"
            );
            let next = next_version_number(&overlay_dir);
            let version_name = format!("v{next}");
            // Sync context — check proxy health synchronously via podman exec.
            let proxy_ok = is_proxy_healthy_sync();
            build_overlay_sync(&overlay_dir, &version_name, &expected_tag, proxy_ok)?;
            prune_old_versions(&overlay_dir);
            return Ok(());
        }
    }

    // First launch — build v1
    info!(
        spec = "layered-tools-overlay",
        "Building tools overlay (init)"
    );
    let proxy_ok = is_proxy_healthy_sync();
    build_overlay_sync(&overlay_dir, "v1", &expected_tag, proxy_ok)
}

// ---------------------------------------------------------------------------
// P2-4: Background update check (wired into post-launch flow)
// @trace spec:layered-tools-overlay
// ---------------------------------------------------------------------------

/// Check for tool updates and rebuild the overlay if newer versions are available.
///
/// This is the main entry point for background updates. It:
/// 1. Checks the rate-limit stamp file (skip if < 24h since last check)
/// 2. Queries upstream registries for latest versions
/// 3. Compares against the installed manifest
/// 4. If any tool has a newer version, rebuilds the overlay in the background
/// 5. Sends a desktop notification on completion
///
/// Designed to be called via `tokio::spawn` after a container starts — must
/// never block the user or affect running containers.
///
/// @trace spec:layered-tools-overlay
pub(crate) async fn check_and_update_tools_overlay() -> Result<(), String> {
    let cache = cache_dir();
    let overlay_dir = cache.join("tools-overlay");
    let current = overlay_dir.join("current");

    // Guard: overlay must exist (first-launch build handles creation)
    if !current.exists() || !current.is_dir() {
        debug!(
            spec = "layered-tools-overlay",
            "No tools overlay found — skipping background update check"
        );
        return Ok(());
    }

    // P2-2: Rate limiting — skip if checked recently
    if !should_check_versions(&overlay_dir) {
        return Ok(());
    }

    // Read current manifest
    let manifest = read_manifest(&current)
        .map_err(|e| format!("Cannot read current manifest for update check: {e}"))?;

    // P2-1: Check latest versions
    info!(
        spec = "layered-tools-overlay",
        "Checking for tools overlay updates..."
    );
    let latest = check_latest_tool_versions().await;

    // Update the stamp regardless of whether updates are found
    touch_check_stamp(&overlay_dir);

    if latest.is_empty() {
        debug!(
            spec = "layered-tools-overlay",
            "No upstream versions retrieved — skipping update"
        );
        return Ok(());
    }

    // Compare versions — check if any tool has a newer upstream version
    let mut needs_update = false;
    for (tool_name, latest_version) in &latest {
        if let Some(installed) = manifest.tools.get(tool_name) {
            if installed.version != *latest_version && installed.version != "unknown" {
                info!(
                    tool = %tool_name,
                    installed = %installed.version,
                    latest = %latest_version,
                    spec = "layered-tools-overlay",
                    "Tool update available"
                );
                needs_update = true;
            }
        } else {
            // Tool not in manifest (new tool added?) — treat as needing update
            needs_update = true;
        }
    }

    if !needs_update {
        debug!(
            spec = "layered-tools-overlay",
            "All tools are up to date"
        );
        return Ok(());
    }

    // P2-3 + P2-6: Background rebuild with notifications
    info!(
        accountability = true,
        category = "tools",
        spec = "layered-tools-overlay",
        "Starting background tools overlay update"
    );

    match rebuild_tools_overlay(&overlay_dir).await {
        Ok(()) => {
            info!(
                accountability = true,
                category = "tools",
                spec = "layered-tools-overlay",
                "Background tools overlay update completed"
            );
            // P2-6: Desktop notification
            send_notification(
                "Tillandsias",
                i18n::t("notifications.tools_updated"),
            );
            Ok(())
        }
        Err(e) => {
            warn!(
                error = %e,
                spec = "layered-tools-overlay",
                "Background tools overlay update failed"
            );
            Err(e)
        }
    }
}

/// Spawn a background task to check and update the tools overlay.
///
/// Called after a container starts successfully. The task is fully non-blocking
/// and failures are logged but never propagated to the caller.
///
/// @trace spec:layered-tools-overlay
pub(crate) fn spawn_background_update() {
    tokio::spawn(async move {
        if let Err(e) = check_and_update_tools_overlay().await {
            warn!(
                error = %e,
                spec = "layered-tools-overlay",
                "Background tools overlay update failed"
            );
        }
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_version_number_empty_dir() {
        let tmp = std::env::temp_dir().join("tillandsias-test-overlay-next-ver");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        assert_eq!(next_version_number(&tmp), 1);

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn next_version_number_existing_versions() {
        let tmp = std::env::temp_dir().join("tillandsias-test-overlay-next-ver2");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join("v1")).unwrap();
        std::fs::create_dir_all(tmp.join("v2")).unwrap();
        std::fs::create_dir_all(tmp.join("v5")).unwrap();

        assert_eq!(next_version_number(&tmp), 6);

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn next_version_number_ignores_non_version_dirs() {
        let tmp = std::env::temp_dir().join("tillandsias-test-overlay-next-ver3");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join("v1")).unwrap();
        std::fs::create_dir_all(tmp.join("current")).unwrap();
        std::fs::create_dir_all(tmp.join("temp")).unwrap();

        assert_eq!(next_version_number(&tmp), 2);

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn should_check_versions_no_stamp() {
        let tmp = std::env::temp_dir().join("tillandsias-test-overlay-stamp1");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        assert!(should_check_versions(&tmp));

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn should_check_versions_recent_stamp() {
        let tmp = std::env::temp_dir().join("tillandsias-test-overlay-stamp2");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        // Create stamp file (mtime = now)
        std::fs::File::create(tmp.join(LAST_CHECK_STAMP)).unwrap();

        assert!(!should_check_versions(&tmp));

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn manifest_roundtrip() {
        let tmp = std::env::temp_dir().join("tillandsias-test-overlay-manifest-rt");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let manifest = ToolsManifest {
            version: 1,
            created: "2026-01-01T00:00:00Z".to_string(),
            forge_image: "tillandsias-forge:v0.1.100.50".to_string(),
            tools: {
                let mut map = HashMap::new();
                map.insert(
                    "claude".to_string(),
                    ToolEntry {
                        version: "1.0.34".to_string(),
                        installed: "2026-01-01T00:00:00Z".to_string(),
                    },
                );
                map
            },
        };

        write_manifest(&tmp, &manifest).unwrap();
        let read_back = read_manifest(&tmp).unwrap();

        assert_eq!(read_back.version, 1);
        assert_eq!(read_back.forge_image, "tillandsias-forge:v0.1.100.50");
        assert_eq!(
            read_back.tools.get("claude").unwrap().version,
            "1.0.34"
        );

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn touch_check_stamp_creates_file() {
        let tmp = std::env::temp_dir().join("tillandsias-test-overlay-touch");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let stamp = tmp.join(LAST_CHECK_STAMP);
        assert!(!stamp.exists());

        touch_check_stamp(&tmp);
        assert!(stamp.exists());

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn prune_old_versions_keeps_one() {
        let tmp = std::env::temp_dir().join("tillandsias-test-overlay-prune");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join("v1")).unwrap();
        std::fs::create_dir_all(tmp.join("v2")).unwrap();
        std::fs::create_dir_all(tmp.join("v3")).unwrap();
        std::fs::create_dir_all(tmp.join("v4")).unwrap();

        // Create current symlink pointing to v4
        #[cfg(unix)]
        std::os::unix::fs::symlink("v4", tmp.join("current")).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_dir("v4", tmp.join("current")).unwrap();

        prune_old_versions(&tmp);

        // Only v4 (current) should remain, all others pruned
        assert!(!tmp.join("v1").exists(), "v1 should be pruned");
        assert!(!tmp.join("v2").exists(), "v2 should be pruned");
        assert!(!tmp.join("v3").exists(), "v3 should be pruned (no rollback slot)");
        assert!(tmp.join("v4").exists(), "v4 should remain (current)");

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[cfg(unix)]
    #[test]
    fn swap_current_symlink_atomic() {
        let tmp = std::env::temp_dir().join("tillandsias-test-overlay-swap");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join("v1")).unwrap();
        std::fs::create_dir_all(tmp.join("v2")).unwrap();

        // Create initial symlink
        std::os::unix::fs::symlink("v1", tmp.join("current")).unwrap();
        assert_eq!(
            std::fs::read_link(tmp.join("current")).unwrap().to_string_lossy(),
            "v1"
        );

        // Swap to v2
        swap_current_symlink(&tmp, "v2").unwrap();
        assert_eq!(
            std::fs::read_link(tmp.join("current")).unwrap().to_string_lossy(),
            "v2"
        );

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn current_version_name_reads_symlink() {
        let tmp = std::env::temp_dir().join("tillandsias-test-overlay-curver");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join("v3")).unwrap();

        #[cfg(unix)]
        std::os::unix::fs::symlink("v3", tmp.join("current")).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_dir("v3", tmp.join("current")).unwrap();

        assert_eq!(current_version_name(&tmp), Some("v3".to_string()));

        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn current_version_name_returns_none_when_missing() {
        let tmp = std::env::temp_dir().join("tillandsias-test-overlay-curver-none");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        assert_eq!(current_version_name(&tmp), None);

        std::fs::remove_dir_all(&tmp).ok();
    }
}
