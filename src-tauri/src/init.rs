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
pub fn run() -> bool {
    run_with_force(false)
}

/// Build the forge image without the init banner/flow.
/// Used by --github-login to build inline before running the auth script.
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
