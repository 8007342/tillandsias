//! `tillandsias --init` — pre-build all container images.
//!
//! Builds proxy, forge, git, and inference images so they're ready
//! before the user opens the tray. Uses the build lock to coordinate.
//!
//! @trace spec:init-command, spec:proxy-container, spec:git-mirror-service, spec:inference-container

use crate::build_lock;
use crate::embedded;
use crate::handlers::{
    forge_image_tag, git_image_tag, inference_image_tag, proxy_image_tag, prune_old_images,
};
use crate::i18n;
use crate::strings;

/// All image types to build, in order.
/// Proxy first (foundation), then forge (main), then git + inference.
const IMAGE_TYPES: &[(&str, fn() -> String)] = &[
    ("proxy", proxy_image_tag),
    ("forge", forge_image_tag),
    ("git", git_image_tag),
    ("inference", inference_image_tag),
];

/// Run the init command. When `force` is true, rebuild even if images exist.
pub fn run_with_force(force: bool) -> bool {
    println!("{}", i18n::t("init.preparing"));
    println!();

    // On macOS/Windows, podman requires a VM (podman machine).
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

    let script = source_dir.join("scripts").join("build-image.sh");
    if !script.exists() {
        eprintln!("  [internal] Script not found at: {}", script.display());
        return false;
    }

    let mut all_success = true;

    for (image_name, tag_fn) in IMAGE_TYPES {
        let tag = tag_fn();

        // Remove existing image if force-rebuilding
        if force && image_exists(&tag) {
            let _ = tillandsias_podman::podman_cmd_sync()
                .args(["rmi", "--force", &tag])
                .output();
        }

        println!("  {}", i18n::tf("init.build.building", &[("name", image_name)]));

        // Acquire build lock for this image type
        if build_lock::is_running(image_name) {
            println!("    {}", i18n::t("init.build.waiting_for_build"));
            if let Err(e) = build_lock::wait_for_build(image_name) {
                eprintln!("    [internal] Wait timed out: {e}");
                all_success = false;
                continue;
            }
            if image_exists(&tag) {
                println!("  {}", i18n::tf("init.build.image_ready", &[("name", image_name), ("tag", &tag)]));
                continue;
            }
        }

        let _ = build_lock::acquire(image_name);

        // Build with inherited stdio so the user sees progress
        // @trace spec:init-command
        #[cfg(not(target_os = "windows"))]
        let status = std::process::Command::new(&script)
            .arg(*image_name)
            .args(["--tag", &tag, "--backend", "fedora"])
            .current_dir(&source_dir)
            .env_remove("LD_LIBRARY_PATH")
            .env_remove("LD_PRELOAD")
            .env("PODMAN_PATH", tillandsias_podman::find_podman_path())
            .stdin(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit())
            .status();

        #[cfg(target_os = "windows")]
        let status = {
            let image_dir = match *image_name {
                "proxy" => "proxy",
                "git" => "git",
                "inference" => "inference",
                _ => "default",
            };
            let containerfile = source_dir
                .join("images")
                .join(image_dir)
                .join("Containerfile");
            let context_dir = source_dir.join("images").join(image_dir);

            // @trace spec:agent-cheatsheets, spec:cross-platform
            // Stage `.cheatsheets/` into the forge build context. Linux/macOS
            // do this inside scripts/build-image.sh (lines 273-283), but the
            // Windows init path bypasses the shell script and calls podman
            // directly — so we replicate the same staging logic here.
            //
            // Source order: (1) $TILLANDSIAS_WORKSPACE/cheatsheets when set
            // (covers `cargo run` from a checkout), (2) MISSING.md placeholder
            // matching the Linux fallback. The Containerfile's `COPY
            // .cheatsheets/ /opt/cheatsheets-image/` resolves either way.
            if image_dir == "default" {
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

            tillandsias_podman::podman_cmd_sync()
                .args(["build", "--tag", &tag, "-f"])
                .arg(&containerfile)
                .arg(&context_dir)
                .stdin(std::process::Stdio::inherit())
                .stdout(std::process::Stdio::inherit())
                .stderr(std::process::Stdio::inherit())
                .status()
        };

        build_lock::release(image_name);

        match status {
            Ok(s) if s.success() => {
                println!("  {}", i18n::tf("init.build.build_success", &[("name", image_name), ("tag", &tag)]));
            }
            Ok(s) => {
                eprintln!(
                    "  {}",
                    i18n::tf("init.build.build_failed", &[
                        ("name", image_name),
                        ("code", &s.code().unwrap_or(-1).to_string()),
                    ])
                );
                all_success = false;
            }
            Err(e) => {
                eprintln!(
                    "  {}",
                    i18n::tf("init.build.build_error", &[("name", image_name), ("error", &e.to_string())])
                );
                all_success = false;
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

    // Tools overlay tombstoned — agents (claude, opencode, openspec) are
    // hard-installed in the forge image at /usr/local/bin/. No overlay build
    // required during --init.
    // @trace spec:tombstone-tools-overlay, spec:init-command

    // @trace spec:enclave-network, spec:init-command
    if all_success {
        println!();
        println!("  {}", i18n::t("init.build.enclave_title"));
        println!("  {}", i18n::t("init.build.proxy_desc"));
        println!("  {}", i18n::t("init.build.forge_desc"));
        println!("  {}", i18n::t("init.build.git_desc"));
        println!("  {}", i18n::t("init.build.inference_desc"));
    }

    println!();
    if all_success {
        println!("{}", i18n::t("init.ready_run"));
    } else {
        eprintln!("  {}", i18n::t("init.build.some_failed"));
    }
    all_success
}

/// Entry point for `tillandsias --init` (no --force).
#[allow(dead_code)] // CLI entry point — called from main when --init has no --force flag
pub fn run() -> bool {
    run_with_force(false)
}

/// Build the forge image without the init banner/flow.
/// Used by --github-login to build inline before running the auth script.
#[allow(dead_code)] // API surface — used by --github-login CLI path
pub fn run_build_only() -> Result<(), String> {
    let source_dir = embedded::write_image_sources().map_err(|e| {
        eprintln!("  [internal] Failed to extract embedded image sources: {e}");
        strings::SETUP_ERROR
    })?;

    let script = source_dir.join("scripts").join("build-image.sh");
    let tag = forge_image_tag();

    #[cfg(not(target_os = "windows"))]
    let status = std::process::Command::new(&script)
        .arg("forge")
        .args(["--tag", &tag, "--backend", "fedora"])
        .current_dir(&source_dir)
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .map_err(|e| {
            eprintln!("  [internal] Failed to launch build script: {e}");
            strings::SETUP_ERROR
        })?;

    #[cfg(target_os = "windows")]
    let status = {
        let containerfile = source_dir.join("images").join("default").join("Containerfile");
        let context_dir = source_dir.join("images").join("default");
        // @trace spec:agent-cheatsheets, spec:cross-platform
        // Stage `.cheatsheets/` (mirrors the run_with_force Windows path).
        // Without this, the forge Containerfile's `COPY .cheatsheets/`
        // step fails with "no such file or directory".
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
        tillandsias_podman::podman_cmd_sync()
            .args(["build", "--tag", &tag, "-f"])
            .arg(&containerfile)
            .arg(&context_dir)
            .stdin(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit())
            .status()
            .map_err(|e| {
                eprintln!("  [internal] Failed to launch podman build: {e}");
                strings::SETUP_ERROR
            })?
    };

    embedded::cleanup_image_sources();

    if status.success() {
        prune_old_images();
        Ok(())
    } else {
        Err(strings::SETUP_ERROR.into())
    }
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
/// @trace spec:agent-cheatsheets, spec:cross-platform
#[cfg(target_os = "windows")]
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
