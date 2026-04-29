//! `tillandsias --init` — pre-build all container images.
//!
//! Builds proxy, forge, git, and inference images so they're ready
//! before the user opens the tray. Uses the build lock to coordinate.
//!
//! @trace spec:init-command, spec:proxy-container, spec:git-mirror-service, spec:inference-container
//!
//! ## Sources of Truth
//!
//! - `cheatsheets/runtime/podman.md` — Podman image build commands and troubleshooting
//! - `cheatsheets/runtime/wsl-on-windows.md` — WSL import and distro management
//! - `docs/cross-platform-builds.md` — Cross-platform build strategy
//! - `openspec/specs/init-command/spec.md` — Init command specification

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Instant;

use crate::build_lock;
use crate::embedded;
use crate::handlers::{
    forge_image_tag, git_image_tag, inference_image_tag, proxy_image_tag, prune_old_images,
};
use crate::i18n;
use crate::image_builder::ImageBuilder;
use crate::strings;
use tillandsias_core::config::cache_dir;

/// Progress state for `--init` command.
///
/// Persists successfully built images so that if the process is interrupted
/// or some images fail, the completed work is saved and can be resumed.
///
/// @trace spec:init-command
/// ## Sources of Truth
/// - `cheatsheets/runtime/podman.md` — Podman commands for image management
/// - `openspec/specs/init-command/spec.md` — Init command specification
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, Default)]
struct InitProgress {
    /// Map of image_name -> (tag, timestamp_iso8601)
    completed: HashMap<String, (String, String)>,
    /// List of images that failed with their error messages
    failed: Vec<(String, String, String)>,
}

impl InitProgress {
    /// Path to the progress cache file.
    fn cache_path() -> PathBuf {
        cache_dir().join("init-progress.json")
    }

    /// Load progress from disk. Returns empty progress if file doesn't exist or is invalid.
    fn load() -> Self {
        let path = Self::cache_path();
        if !path.exists() {
            return Self::default();
        }
        match std::fs::read_to_string(&path) {
            Ok(content) => serde_json::from_str(&content).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    /// Save progress to disk.
    fn save(&self) {
        let path = Self::cache_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(&path, json);
        }
    }

    /// Mark an image as completed.
    fn mark_completed(&mut self, image_name: &str, tag: &str) {
        let _timestamp = chrono::Utc::now().to_rfc3339();
        self.completed
            .insert(image_name.to_string(), (tag.to_string(), _timestamp));
        // Remove from failed list if it was there
        self.failed.retain(|(name, _, _)| name != image_name);
        self.save();
    }

    /// Mark an image as failed.
    fn mark_failed(&mut self, image_name: &str, tag: &str, error: &str) {
        let _timestamp = chrono::Utc::now().to_rfc3339();
        self.failed
            .push((image_name.to_string(), tag.to_string(), error.to_string()));
        self.save();
    }

    /// Check if an image has been completed with the same tag.
    fn is_completed(&self, image_name: &str, tag: &str) -> bool {
        self.completed
            .get(image_name)
            .map(|(t, _)| t == tag)
            .unwrap_or(false)
    }

    /// Clear progress (for --force flag).
    fn clear(&mut self) {
        self.completed.clear();
        self.failed.clear();
        self.save();
    }
}

/// All image types to build, in order.
/// Proxy first (foundation), then forge (main), then git + inference.
/// @trace spec:init-command
/// ## Sources of Truth
/// - `cheatsheets/runtime/podman.md` — Podman image build commands
/// - `openspec/specs/init-command/spec.md` — Init command specification
const IMAGE_TYPES: &[(&str, fn() -> String)] = &[
    ("proxy", proxy_image_tag),
    ("forge", forge_image_tag),
    ("git", git_image_tag),
    ("inference", inference_image_tag),
];

/// Check if an image name is valid for individual build.
fn is_valid_image(name: &str) -> bool {
    IMAGE_TYPES.iter().any(|(n, _)| *n == name)
}

/// Run the init command. When `force` is true, rebuild even if images exist.
///
/// Dispatches by target OS:
/// - **Windows**: WSL-native path — `scripts/wsl-build/build-<service>.sh`
///   for each enclave service, then `wsl --import` each tarball.
///   No podman, no podman-machine. @trace spec:cross-platform
/// - **Linux / macOS**: existing podman path.
pub fn run_with_force(force: bool, image: Option<&str>, debug: bool) -> bool {
    #[cfg(target_os = "windows")]
    {
        // Windows doesn't support --image flag yet (builds all services)
        if image.is_some() {
            eprintln!("  [Windows] --image flag not yet supported, building all services");
        }
        run_with_force_wsl(force, image, debug)
    }
    #[cfg(not(target_os = "windows"))]
    {
        run_with_force_podman(force, image, debug)
    }
}

/// Linux/macOS implementation: builds enclave images via podman.
#[cfg(not(target_os = "windows"))]
fn run_with_force_podman(force: bool, image: Option<&str>, debug: bool) -> bool {
    let start_time = Instant::now();
    println!("{}", i18n::t("init.preparing"));
    if debug {
        println!("  [debug] Debug mode enabled");
        // Show podman system info for debugging
        if let Ok(output) = std::process::Command::new("podman").args(["system", "info"]).output() {
            if output.status.success() {
                println!("  [debug] Podman system info:");
                let info = String::from_utf8_lossy(&output.stdout);
                for line in info.lines().take(10) {
                    println!("    {line}");
                }
            }
        }
    }
    if let Some(img) = image {
        println!("  [debug] Building only image: {img}");
    }
    println!();

    // Load or initialize progress tracking
    let mut progress = InitProgress::load();
    if force {
        progress.clear();
        println!("  [progress] Cleared previous progress (--force specified)");
    } else {
        let completed_count = progress.completed.len();
        if completed_count > 0 {
            println!("  [progress] Found {completed_count} previously completed image(s) in cache");
        }
    }

    // On macOS, podman requires a VM (podman machine).
    // Init and start it before any image builds.
    // @trace spec:podman-orchestration
    if tillandsias_core::state::Os::detect().needs_podman_machine() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("tokio runtime for podman machine");
        let client = tillandsias_podman::PodmanClient::new();

        if !rt.block_on(client.has_machine()) {
            println!("  Initializing container runtime...");
            rt.block_on(client.init_machine());
        }
        if !rt.block_on(client.is_machine_running()) {
            println!("  Starting container runtime...");
            if !rt.block_on(client.start_machine()) {
                eprintln!("  \u{2717} Container runtime failed to start.");
                eprintln!("  Try manually: podman machine init && podman machine start");
                return false;
            }
            // Wait for API to be ready
            rt.block_on(client.wait_for_ready(10));
        }
    }

    // Always invoke the build script for each image — it handles staleness
    // internally via hash check and exits fast when up to date.
    // @trace spec:forge-staleness
    println!("  {}", i18n::t("init.setting_up"));
    println!("  {}", i18n::t("init.first_run_note"));
    println!();

    let source_dir = match embedded::write_image_sources() {
        Ok(dir) => dir,
        Err(e) => {
            eprintln!("  [internal] Failed to extract embedded image sources: {e}");
            return false;
        }
    };

    // Image builds are driven directly from Rust via ImageBuilder
    // @trace spec:direct-podman-calls

    let mut failed_images: Vec<(String, String, String)> = Vec::new();

    // Filter images if specific image requested
    let images_to_build: Vec<(&str, fn() -> String)> = if let Some(img) = image {
        if IMAGE_TYPES.iter().any(|(n, _)| *n == img) {
            vec![(img, IMAGE_TYPES.iter().find(|(n, _)| *n == img).unwrap().1)]
        } else {
            eprintln!("  [error] Invalid image name: {img}");
            eprintln!("  Valid images: proxy, forge, git, inference");
            return false;
        }
    } else {
        IMAGE_TYPES.to_vec()
    };

    let total_images = images_to_build.len();
    let mut completed_count = 0;

    for (index, (image_name, tag_fn)) in images_to_build.iter().enumerate() {
        let tag = tag_fn();
        let position = index + 1;

        // Skip if already completed with same tag (unless force)
        if !force && progress.is_completed(image_name, &tag) {
            println!("  [{position}/{total_images}] {image_name}: Already completed (tag: {tag})");
            completed_count += 1;
            continue;
        }

        println!("  [{position}/{total_images}] Building {image_name}...");
        if debug {
            println!("  [debug] Image: {image_name}, Tag: {tag}");
        }

        // Remove existing image if force-rebuilding
        if force && image_exists(&tag) {
            let _ = tillandsias_podman::podman_cmd_sync()
                .args(["rmi", "--force", &tag])
                .output();
        }

        // Acquire build lock for this image type
        if build_lock::is_running(image_name) {
            println!("    {}", i18n::t("init.build.waiting_for_build"));
            if let Err(e) = build_lock::wait_for_build(image_name) {
                let error_msg = format!("Wait timed out: {e}");
                eprintln!("    [internal] {error_msg}");
                failed_images.push((image_name.to_string(), tag.clone(), error_msg.clone()));
                progress.mark_failed(image_name, &tag, &error_msg);
                continue;
            }
            if image_exists(&tag) {
                println!("  [{position}/{total_images}] {image_name}: Image ready (tag: {tag})");
                progress.mark_completed(image_name, &tag);
                completed_count += 1;
                continue;
            }
        }

        let _ = build_lock::acquire(image_name);

        // @trace spec:agent-cheatsheets, spec:cross-platform, spec:windows-wsl-runtime
        // The direct-podman / ImageBuilder path doesn't run
        // scripts/build-image.sh, so it doesn't get the shell script's
        // `.cheatsheets/` staging step. Replicate it here when building the
        // forge ("default") image so `COPY .cheatsheets/ /opt/cheatsheets-image/`
        // in the Containerfile resolves.
        //
        // Source order: (1) `$TILLANDSIAS_WORKSPACE/cheatsheets` when set
        // (covers `cargo run` from a checkout), (2) MISSING.md placeholder
        // matching the legacy Linux fallback.
        if *image_name == "forge" {
            let context_dir = source_dir.join("images").join("default");
            let staged = context_dir.join(".cheatsheets");
            let _ = std::fs::remove_dir_all(&staged);
            let mut copied_from_workspace = false;
            if let Ok(workspace) = std::env::var("TILLANDSIAS_WORKSPACE") {
                let src = std::path::PathBuf::from(workspace).join("cheatsheets");
                if src.is_dir() {
                    if let Err(e) = copy_dir_recursive(&src, &staged) {
                        eprintln!(
                            "  [internal] cheatsheets staging from {} failed: {e}",
                            src.display()
                        );
                    } else {
                        copied_from_workspace = true;
                    }
                }
            }
            if !copied_from_workspace {
                if let Err(e) = std::fs::create_dir_all(&staged) {
                    eprintln!("  [internal] cheatsheets placeholder mkdir failed: {e}");
                } else if let Err(e) = std::fs::write(
                    staged.join("MISSING.md"),
                    "Cheatsheets directory missing at build time\n",
                ) {
                    eprintln!("  [internal] cheatsheets MISSING.md write failed: {e}");
                }
            }
        }

        // Build using ImageBuilder (direct podman, no bash script intermediary).
        // @trace spec:direct-podman-calls, spec:default-image
        let builder = ImageBuilder::new(source_dir.clone(), image_name.to_string(), tag.clone());
        let build_result = builder.build_image();

        build_lock::release(image_name);

        match build_result {
            Ok(()) => {
                println!("  [{position}/{total_images}] {image_name}: Build successful (tag: {tag})");

                // Tag image with 'latest' for easier reference
                let latest_tag = format!("tillandsias-{}:latest", image_name);
                let tag_result = tillandsias_podman::podman_cmd_sync()
                    .args(["tag", &tag, &latest_tag])
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::piped())
                    .output();

                match tag_result {
                    Ok(output) if output.status.success() => {
                        println!("    Tagged as: {latest_tag}");
                        if debug {
                            println!("  [debug] Tag command: podman tag {tag} {latest_tag}");
                        }
                    }
                    Ok(output) => {
                        let stderr = String::from_utf8_lossy(&output.stderr);
                        eprintln!("    Warning: failed to tag as latest: {stderr}");
                    }
                    Err(e) => {
                        eprintln!("    Warning: failed to tag as latest: {e}");
                    }
                }

                progress.mark_completed(image_name, &tag);
                completed_count += 1;
            }
            Err(e) => {
                eprintln!(
                    "  [{position}/{total_images}] {image_name}: Build failed: {e}"
                );

                // Debug output: provide actionable commands
                if debug {
                    eprintln!("  [debug] Troubleshooting commands (copy/paste):");
                    // Get container ID if available
                    if let Ok(output) = std::process::Command::new("podman")
                        .args(["ps", "--format", "{{.ID}} {{.Image}}"])
                        .output()
                    {
                        if output.status.success() {
                            let ps_output = String::from_utf8_lossy(&output.stdout);
                            for line in ps_output.lines() {
                                let parts: Vec<&str> = line.split_whitespace().collect();
                                if parts.len() >= 2 && parts[1].contains(image_name) {
                                    let container_id = parts[0];
                                    eprintln!("    podman logs {container_id}  # View build log");
                                    eprintln!("    podman run --rm {tag} tail -10 /var/log/tillandsias/*.log  # View container logs");
                                }
                            }
                        }
                    }
                    // Generic commands if container not found
                    eprintln!("    podman ps  # Find container ID");
                    eprintln!("    podman logs <container_id>  # View build log");
                    eprintln!("    podman run --rm {tag} tail -10 /var/log/tillandsias/*.log");
                }

                failed_images.push((image_name.to_string(), tag.clone(), e.clone()));
                progress.mark_failed(image_name, &tag, &e);
                // Continue to next image instead of stopping
                eprintln!("  Continuing with remaining images...");
            }
        }
    }

    embedded::cleanup_image_sources();

    // Clean up any leftover buildah containers from builds
    // @trace spec:default-image
    let _ = std::process::Command::new("buildah")
        .args(["rm", "--all"])
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    // Prune old images after building new ones
    prune_old_images();

    // Print summary report
    let elapsed = start_time.elapsed();
    println!();
    println!("═════════════════════════════════════════");
    println!("  Init Summary Report");
    println!("═════════════════════════════════════════");
    println!("  Total images: {total_images}");
    println!("  Completed:    {completed_count}");
    println!("  Failed:       {}", failed_images.len());
    println!("  Time elapsed: {:.1}s", elapsed.as_secs_f32());
    println!();

    if !failed_images.is_empty() {
        eprintln!("  Failed images:");
        for (image, tag, error) in &failed_images {
            eprintln!("    • {image} (tag: {tag})");
            eprintln!("      Error: {error}");
        }
        eprintln!();
        eprintln!("  Troubleshooting:");
        eprintln!("    • Check podman is running: podman ps");
        // Get actual container IDs for troubleshooting
        if let Ok(output) = std::process::Command::new("podman")
            .args(["ps", "--format", "{{.ID}} {{.Names}} {{.Image}}"])
            .output()
        {
            if output.status.success() {
                let ps_output = String::from_utf8_lossy(&output.stdout);
                eprintln!("    • View image build logs (copy/paste commands):");
                for line in ps_output.lines() {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if parts.len() >= 1 {
                        let container_id = parts[0];
                        eprintln!("      podman logs {container_id}");
                    }
                }
            }
        } else {
            eprintln!("    • View image build logs: podman ps (then: podman logs <container_id>)");
        }
        eprintln!("    • Retry only failed: tillandsias --init");
        eprintln!("    • Force rebuild all: tillandsias --init --force");
        eprintln!("    • Progress is saved — retry will skip completed images");
    }

    // Tools overlay tombstoned — agents (claude, opencode, openspec) are
    // hard-installed in the forge image at /usr/local/bin/. No overlay build
    // required during --init.
    // @trace spec:tombstone-tools-overlay, spec:init-command

    // @trace spec:enclave-network, spec:init-command
    if failed_images.is_empty() {
        println!("  {}", i18n::t("init.build.enclave_title"));
        println!("  {}", i18n::t("init.build.proxy_desc"));
        println!("  {}", i18n::t("init.build.forge_desc"));
        println!("  {}", i18n::t("init.build.git_desc"));
        println!("  {}", i18n::t("init.build.inference_desc"));
        println!();
        println!("{}", i18n::t("init.ready_run"));
        true
    } else {
        false
    }
}

/// Entry point for `tillandsias --init` (no --force).
#[allow(dead_code)] // CLI entry point — called from main when --init has no --force flag
pub fn run() -> bool {
    run_with_force(false, None, false)
}

/// Windows implementation: WSL-native build pipeline.
///
/// For each enclave service, run `scripts/wsl-build/build-<service>.sh`
/// to produce `target/wsl/tillandsias-<service>.tar`, then `wsl --import`
/// the tarball as `tillandsias-<service>` under
/// `%LOCALAPPDATA%\Tillandsias\WSL\<service>`.
///
/// The build scripts are extracted from `embedded.rs` into a per-process
/// dir under `runtime_dir()`, so deployed binaries work without the
/// workspace source on disk. Bash is required (`C:\Program Files\Git\usr\bin\bash.exe`
/// or any `bash.exe` on PATH); we exit early with a clear message otherwise.
///
/// @trace spec:cross-platform, spec:podman-orchestration
#[cfg(target_os = "windows")]
fn run_with_force_wsl(force: bool, _image: Option<&str>, debug: bool) -> bool {
    let start_time = Instant::now();
    println!("{}", i18n::t("init.preparing"));
    println!();

    // Load or initialize progress tracking
    let mut progress = InitProgress::load();
    if force {
        progress.clear();
        println!("  [progress] Cleared previous progress (--force specified)");
    } else {
        let completed_count = progress.completed.len();
        if completed_count > 0 {
            println!("  [progress] Found {completed_count} previously completed service(s) in cache");
        }
    }

    // Locate bash.exe — required to drive the wsl-build scripts.
    let bash = match find_bash_exe() {
        Some(p) => p,
        None => {
            eprintln!("  \u{2717} bash.exe not found on PATH.");
            eprintln!("    Install Git for Windows (https://git-scm.com/download/win) and try again.");
            return false;
        }
    };
    println!("  using bash: {}", bash.display());

    // Extract embedded image sources (scripts/wsl-build/, images/, etc.).
    let source_dir = match embedded::write_image_sources() {
        Ok(dir) => dir,
        Err(e) => {
            eprintln!("  [internal] Failed to extract embedded image sources: {e}");
            return false;
        }
    };

    let wsl_build_dir = source_dir.join("scripts").join("wsl-build");
    let target_wsl_dir = source_dir.join("target").join("wsl");
    let _ = std::fs::create_dir_all(&target_wsl_dir);

    // Each enclave service maps to a build script + a runtime distro name.
    // enclave-init runs first because forge-offline egress rules apply at
    // VM cold-boot via [boot] command in its wsl.conf.
    // proxy first (foundation), then forge (heaviest), then git/inference/router.
    let services: &[(&str, &str)] = &[
        ("enclave-init", "build-enclave-init.sh"),
        ("proxy", "build-proxy.sh"),
        ("forge", "build-forge.sh"),
        ("git", "build-git.sh"),
        ("inference", "build-inference.sh"),
        ("router", "build-router.sh"),
    ];

    let total_services = services.len();
    let mut completed_count = 0;
    let mut failed_services: Vec<(String, String)> = Vec::new();

    for (index, (service, script)) in services.iter().enumerate() {
        let position = index + 1;
        let distro = format!("tillandsias-{service}");

        // Skip if already completed (unless force)
        if !force && progress.completed.contains_key(*service) {
            println!("  [{position}/{total_services}] {service}: Already completed");
            completed_count += 1;
            continue;
        }

        if force {
            // wsl --unregister wipes the existing distro + VHDX.
            let _ = std::process::Command::new("wsl.exe")
                .args(["--unregister", &distro])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();
        } else if wsl_distro_exists(&distro) {
            println!("  [{position}/{total_services}] {service}: Already imported (skipping)");
            progress.mark_completed(*service, "imported");
            completed_count += 1;
            continue;
        }

        // Run the build script.
        let script_path = wsl_build_dir.join(script);
        println!("  [{position}/{total_services}] Building {service} via {}", script.to_string());
        let build_status = std::process::Command::new(&bash)
            .arg(&script_path)
            .current_dir(&source_dir)
            .stdin(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit())
            .status();

        let build_succeeded = match build_status {
            Ok(s) if s.success() => true,
            Ok(s) => {
                let error = format!("Build failed (exit {})", s.code().unwrap_or(-1));
                eprintln!("  \u{2717} {service}: {error}");
                failed_services.push((service.to_string(), error.clone()));
                progress.mark_failed(*service, "build", &error);
                eprintln!("  Continuing with remaining services...");
                false
            }
            Err(e) => {
                let error = format!("Build error: {e}");
                eprintln!("  \u{2717} {service}: {error}");
                failed_services.push((service.to_string(), error.clone()));
                progress.mark_failed(*service, "build", &error);
                eprintln!("  Continuing with remaining services...");
                false
            }
        };

        if !build_succeeded {
            continue;
        }

        // Locate the produced tarball — the build script puts it in
        // <repo_or_source_root>/target/wsl/. embedded.rs writes scripts
        // under source_dir, and lib-common.sh derives TILL_REPO_ROOT
        // relative to the script's location, so the tarball ends up in
        // source_dir/target/wsl/.
        let tarball = target_wsl_dir.join(format!("tillandsias-{service}.tar"));
        if !tarball.exists() {
            let error = format!("Expected tarball missing: {}", tarball.display());
            eprintln!("  \u{2717} {service}: {error}");
            failed_services.push((service.to_string(), error));
            progress.mark_failed(*service, "tarball", "Missing tarball");
            eprintln!("  Continuing with remaining services...");
            continue;
        }

        // wsl --import. Install location is %LOCALAPPDATA%\Tillandsias\WSL\<service>.
        let local_appdata = std::env::var("LOCALAPPDATA").unwrap_or_else(|_| {
            std::env::var("USERPROFILE")
                .map(|p| format!("{p}\\AppData\\Local"))
                .unwrap_or_default()
        });
        let install_dir = std::path::PathBuf::from(local_appdata)
            .join("Tillandsias")
            .join("WSL")
            .join(service);
        let _ = std::fs::create_dir_all(&install_dir);

        // @trace spec:windows-wsl-runtime, spec:cross-platform
        // @cheatsheet runtime/wsl-on-windows.md
        // Remove any stale ext4.vhdx left behind by a prior import. WSL's
        // `--unregister` is supposed to delete the vhdx atomically, but
        // there are documented cases where the file remains:
        //   - the distro was still mounted by another wsl.exe process at
        //     unregister time (file lock survives, vhdx orphaned),
        //   - the user terminated wsl.exe mid-shutdown,
        //   - antivirus software held the file briefly while scanning.
        // When the vhdx exists, `wsl --import` fails with
        //   Wsl/Service/RegisterDistro/ERROR_FILE_EXISTS
        // Documented at:
        //   https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro
        // We pre-delete the vhdx so import can proceed cleanly. Failing to
        // delete (file still locked) is logged but does not block the
        // attempt — wsl --import will surface the same error if relevant.
        let stale_vhdx = install_dir.join("ext4.vhdx");
        if stale_vhdx.exists() {
            match std::fs::remove_file(&stale_vhdx) {
                Ok(()) => println!(
                    "  \u{2192} removed stale {} from prior import",
                    stale_vhdx.display()
                ),
                Err(e) => eprintln!(
                    "  \u{2717} could not remove stale {}: {e} \
                     (wsl --import may now fail with ERROR_FILE_EXISTS)",
                    stale_vhdx.display()
                ),
            }
        }

        println!("  \u{2192} wsl --import {distro}");
        let import_status = std::process::Command::new("wsl.exe")
            .args(["--import"])
            .arg(&distro)
            .arg(&install_dir)
            .arg(&tarball)
            .args(["--version", "2"])
            .stdin(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit())
            .status();

        match import_status {
            Ok(s) if s.success() => {
                println!("  [{position}/{total_services}] {service}: Import successful");
                progress.mark_completed(*service, "imported");
                completed_count += 1;
            }
            Ok(s) => {
                let error = format!("wsl --import failed (exit {})", s.code().unwrap_or(-1));
                eprintln!("  \u{2717} {service}: {error}");
                failed_services.push((service.to_string(), error.clone()));
                progress.mark_failed(*service, "import", &error);
                eprintln!("  Continuing with remaining services...");
            }
            Err(e) => {
                let error = format!("wsl --import error: {e}");
                eprintln!("  \u{2717} {service}: {error}");
                failed_services.push((service.to_string(), error.clone()));
                progress.mark_failed(*service, "import", &error);
                eprintln!("  Continuing with remaining services...");
            }
        }
    }

    embedded::cleanup_image_sources();

    // Print summary report
    let elapsed = start_time.elapsed();
    println!();
    println!("═══════════════════════════════════════");
    println!("  Init Summary Report (Windows/WSL)");
    println!("═══════════════════════════════════════");
    println!("  Total services: {total_services}");
    println!("  Completed:     {completed_count}");
    println!("  Failed:        {}", failed_services.len());
    println!("  Time elapsed:  {:.1}s", elapsed.as_secs_f32());
    println!();

    if !failed_services.is_empty() {
        eprintln!("  Failed services:");
        for (service, error) in &failed_services {
            eprintln!("    • {service}");
            eprintln!("      Error: {error}");
        }
        eprintln!();
        eprintln!("  Troubleshooting:");
        eprintln!("    • Check WSL is running: wsl --list --verbose");
        eprintln!("    • Check available disk space: wsl df -h");
        eprintln!("    • View build logs: check the bash script output above");
        eprintln!("    • Retry only failed: tillandsias --init");
        eprintln!("    • Force rebuild all: tillandsias --init --force");
        eprintln!("    • Progress is saved — retry will skip completed services");
    }

    println!();
    if failed_services.is_empty() {
        println!("{}", i18n::t("init.ready_run"));
        true
    } else {
        eprintln!("  {}", i18n::t("init.build.some_failed"));
        false
    }
}

/// Locate bash.exe on Windows. Tries common Git for Windows install paths
/// then falls back to PATH lookup via `where`.
#[cfg(target_os = "windows")]
fn find_bash_exe() -> Option<std::path::PathBuf> {
    static CANDIDATES: &[&str] = &[
        r"C:\Program Files\Git\usr\bin\bash.exe",
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files (x86)\Git\usr\bin\bash.exe",
    ];
    for p in CANDIDATES {
        if std::path::Path::new(p).exists() {
            return Some(std::path::PathBuf::from(p));
        }
    }
    // Fallback: ask the shell.
    let out = std::process::Command::new("where").arg("bash").output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout);
    s.lines().next().map(|l| std::path::PathBuf::from(l.trim()))
}

/// Check if a WSL distro is registered. Robust against UTF-16 LE output
/// of `wsl --list --quiet`.
#[cfg(target_os = "windows")]
fn wsl_distro_exists(name: &str) -> bool {
    let out = match std::process::Command::new("wsl.exe")
        .args(["--list", "--quiet"])
        .output()
    {
        Ok(o) => o,
        Err(_) => return false,
    };
    if !out.status.success() {
        return false;
    }
    // wsl.exe emits UTF-16 LE on Windows. Decode via String::from_utf16.
    let bytes = out.stdout;
    let utf16: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect();
    let decoded = String::from_utf16_lossy(&utf16);
    decoded
        .lines()
        .any(|l| l.trim().trim_matches('\u{feff}') == name)
}

/// Build the forge image without the init banner/flow.
/// Used by --github-login to build inline before running the auth script.
#[allow(dead_code)] // API surface — used by --github-login CLI path
pub fn run_build_only() -> Result<(), String> {
    let source_dir = embedded::write_image_sources().map_err(|e| {
        eprintln!("  [internal] Failed to extract embedded image sources: {e}");
        strings::SETUP_ERROR
    })?;

    let tag = forge_image_tag();

    // @trace spec:agent-cheatsheets, spec:cross-platform, spec:windows-wsl-runtime
    // Stage `.cheatsheets/` into the forge build context. Mirrors the staging
    // step inside scripts/build-image.sh so the direct-podman/ImageBuilder
    // path also resolves the Containerfile's `COPY .cheatsheets/` instruction.
    {
        let context_dir = source_dir.join("images").join("default");
        let staged = context_dir.join(".cheatsheets");
        let _ = std::fs::remove_dir_all(&staged);
        let mut copied_from_workspace = false;
        if let Ok(workspace) = std::env::var("TILLANDSIAS_WORKSPACE") {
            let src = std::path::PathBuf::from(workspace).join("cheatsheets");
            if src.is_dir() && copy_dir_recursive(&src, &staged).is_ok() {
                copied_from_workspace = true;
            }
        }
        if !copied_from_workspace {
            let _ = std::fs::create_dir_all(&staged);
            let _ = std::fs::write(
                staged.join("MISSING.md"),
                "Cheatsheets directory missing at build time\n",
            );
        }
    }

    // Build using ImageBuilder (direct podman, no bash script intermediary).
    // @trace spec:direct-podman-calls, spec:init-command, spec:default-image
    let builder = ImageBuilder::new(source_dir.clone(), "forge".to_string(), tag);
    builder.build_image()?;

    embedded::cleanup_image_sources();
    prune_old_images();
    Ok(())
}

/// Check if a podman image exists.
fn image_exists(tag: &str) -> bool {
    tillandsias_podman::podman_cmd_sync()
        .args(["image", "exists", tag])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Recursively copy `src` into `dst`. Used by the Windows --init path to
/// stage `.cheatsheets/` into the forge build context (see comment near
/// the COPY in images/default/Containerfile).
///
/// @trace spec:agent-cheatsheets, spec:cross-platform, spec:direct-podman-calls
/// Cross-platform: cheatsheet staging now runs on the
/// direct-podman/ImageBuilder path on Linux/macOS as well as Windows
/// (the bash build-image.sh used to handle it on Unix; the merged
/// ImageBuilder doesn't, so init.rs replicates the staging step
/// platform-agnostically). The function therefore can no longer be
/// cfg(target_os = "windows")-gated.
fn copy_dir_recursive(src: &std::path::Path, dst: &std::path::Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let from = entry.path();
        let to = dst.join(entry.file_name());
        let ft = entry.file_type()?;
        if ft.is_dir() {
            copy_dir_recursive(&from, &to)?;
        } else if ft.is_file() {
            std::fs::copy(&from, &to)?;
        }
    }
    Ok(())
}
