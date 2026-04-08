//! CLI container runner with user-friendly output.
//!
//! Launched when the user runs `tillandsias <path>`. Checks/builds the
//! image, prints formatted progress, then execs `podman run -it --rm`
//! with inherited stdio so the container terminal passes through.
//!
//! @trace spec:cli-mode, spec:podman-orchestration, spec:default-image

use std::path::{Path, PathBuf};

use tracing::warn;

use tillandsias_core::config::{
    GlobalConfig, SelectedAgent, cache_dir, load_global_config, load_project_config,
};
use tillandsias_core::genus::TillandsiaGenus;
use tillandsias_core::state::ContainerInfo;

/// Drop guard that cleans up enclave service containers on any exit path
/// (normal return, panic, SIGINT after podman forwards it, etc.).
/// @trace spec:enclave-network
struct EnclaveCleanupGuard {
    project_name: String,
}

impl Drop for EnclaveCleanupGuard {
    fn drop(&mut self) {
        // Build a minimal tokio runtime for async cleanup.
        // This is safe in Drop — we're the last thing running before process exit.
        if let Ok(rt) = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            rt.block_on(async {
                crate::handlers::stop_git_service(&self.project_name).await;
                crate::handlers::stop_inference().await;
                crate::handlers::stop_proxy().await;
                crate::handlers::cleanup_enclave_network().await;
            });
        }
    }
}
use tillandsias_podman::PodmanClient;

use crate::i18n;
use crate::strings;

/// Map a short image name to a full image tag.
///
/// For "forge", returns the versioned tag (e.g., `tillandsias-forge:v0.1.72`).
/// For other names or full tags (containing `:` or `/`), passes through as-is.
fn image_tag(name: &str) -> String {
    // If the name already contains a colon or slash, treat it as a full tag.
    if name.contains(':') || name.contains('/') {
        name.to_string()
    } else if name == "forge" {
        crate::handlers::forge_image_tag()
    } else {
        format!("tillandsias-{name}:latest")
    }
}

/// Run `build-image.sh` from the embedded binary scripts.
///
/// Extracts image sources + build scripts to temp, executes with inherited
/// stdio so the user sees progress, then cleans up.
fn run_build_image_script(image_name: &str, debug: bool) -> Result<(), String> {
    // Check if another process (e.g., tillandsias --init) is already building
    if crate::build_lock::is_running(image_name) {
        println!("  {}", i18n::t("cli.waiting_setup"));
        crate::build_lock::wait_for_build(image_name).map_err(|e| {
            if debug {
                eprintln!("  [debug] Build wait timed out: {e}");
            }
            strings::SETUP_ERROR
        })?;
        return Ok(());
    }

    crate::build_lock::acquire(image_name).map_err(|e| {
        if debug {
            eprintln!("  [debug] Cannot acquire build lock: {e}");
        }
        strings::SETUP_ERROR
    })?;

    let source_dir = crate::embedded::write_image_sources().map_err(|e| {
        if debug {
            eprintln!("  [debug] Failed to extract embedded image sources: {e}");
        }
        strings::SETUP_ERROR
    })?;

    let script = source_dir.join("scripts").join("build-image.sh");
    let tag = crate::handlers::forge_image_tag();

    if debug {
        println!(
            "  [debug] Running embedded: {} --tag {}",
            script.display(),
            tag
        );
    }

    // On Windows, call podman build directly instead of going through bash.
    // Git Bash's MSYS2 doesn't initialize properly from native Windows processes.
    #[cfg(target_os = "windows")]
    {
        let containerfile = source_dir.join("images").join("default").join("Containerfile");
        let context_dir = source_dir.join("images").join("default");

        if debug {
            println!(
                "  [debug] Running podman build --tag {} -f {}",
                tag,
                containerfile.display()
            );
        }

        let status = tillandsias_podman::podman_cmd_sync()
            .args(["build", "--tag", &tag, "-f"])
            .arg(&containerfile)
            .arg(&context_dir)
            .stdin(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit())
            .status()
            .map_err(|e| {
                eprintln!("  [debug] Failed to launch podman build: {e}");
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

        if status.success() {
            crate::handlers::prune_old_images();
            return Ok(());
        } else {
            if debug {
                eprintln!(
                    "  [debug] podman build exited with code {}",
                    status.code().unwrap_or(-1)
                );
            }
            return Err(strings::SETUP_ERROR.into());
        }
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
        // Pass the resolved podman path so build-image.sh can find podman
        // even when launched from Finder (which has a minimal PATH).
        .env("PODMAN_PATH", tillandsias_podman::find_podman_path());

    // Image builds do NOT go through the proxy — SSL bump requires CA trust
    // that build containers don't have. See handlers.rs for full rationale.

    let status = cmd
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .map_err(|e| {
            eprintln!("  [debug] Failed to launch build script: {e}");
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

    if status.success() {
        // Prune older versioned forge images to reclaim disk space
        crate::handlers::prune_old_images();
        Ok(())
    } else {
        if debug {
            eprintln!(
                "  [debug] Build script exited with code {}",
                status.code().unwrap_or(-1)
            );
        }
        Err(strings::SETUP_ERROR.into())
    }
    } // #[cfg(not(target_os = "windows"))]
}

/// Get the image size in human-readable form via `podman image inspect`.
fn image_size_display(tag: &str) -> String {
    let output = tillandsias_podman::podman_cmd_sync()
        .args(["image", "inspect", tag, "--format", "{{.Size}}"])
        .output();

    match output {
        Ok(o) if o.status.success() => {
            let size_str = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if let Ok(bytes) = size_str.parse::<u64>() {
                let mb = bytes / (1024 * 1024);
                format!("{mb} MB")
            } else {
                "unknown size".to_string()
            }
        }
        _ => "unknown size".to_string(),
    }
}

/// Build a [`LaunchContext`] for CLI mode.
///
/// Forge and terminal containers are credential-free: no token files,
/// no hosts.yml, no Claude dir mounts. Git identity comes from env vars.
fn build_cli_launch_context(
    container_name: &str,
    project_path: &Path,
    project_name: &str,
    cache: &Path,
    port_range: (u16, u16),
    image_tag: &str,
) -> tillandsias_core::container_profile::LaunchContext {
    let host_os = tillandsias_core::config::detect_host_os();

    // Read git identity from the cached gitconfig (written by gh-auth-login.sh).
    let (git_author_name, git_author_email) = crate::launch::read_git_identity(cache);

    // Custom mounts from project config
    let project_config = load_project_config(project_path);

    tillandsias_core::container_profile::LaunchContext {
        container_name: container_name.to_string(),
        project_path: project_path.to_path_buf(),
        project_name: project_name.to_string(),
        cache_dir: cache.to_path_buf(),
        port_range,
        host_os,
        detached: false,
        is_watch_root: false,
        token_file_path: None, // Forge/terminal containers are credential-free
        custom_mounts: project_config.mounts,
        image_tag: image_tag.to_string(),
        selected_language: tillandsias_core::config::load_global_config().i18n.language.clone(),
        // @trace spec:enclave-network
        // CLI-mode forge containers join the enclave network.
        network: Some(tillandsias_podman::ENCLAVE_NETWORK.to_string()),
        git_author_name,
        git_author_email,
    }
}

/// Run the CLI attach workflow.
///
/// When `bash` is true, the container entrypoint is overridden with `/bin/bash`
/// for troubleshooting (no default tools/IDE launched).
///
/// `agent_override` lets `--opencode` / `--claude` flags override the
/// configured agent for this session. Ignored when `bash` is true.
///
/// Returns `true` on success, `false` on failure.
pub fn run(
    path: PathBuf,
    image_name: &str,
    debug: bool,
    bash: bool,
    agent_override: Option<SelectedAgent>,
) -> bool {
    // Resolve and validate the project path.
    // AppImage changes CWD to its FUSE mount — resolve relative paths against
    // $OWD (Original Working Directory) so `tillandsias .` works correctly.
    // @trace spec:cli-mode
    let resolved = if path.is_relative() {
        if let Ok(owd) = std::env::var("OWD") {
            PathBuf::from(owd).join(&path)
        } else {
            path.clone()
        }
    } else {
        path.clone()
    };

    let project_path = match resolved.canonicalize() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Error: cannot resolve path '{}': {e}", path.display());
            return false;
        }
    };

    if !project_path.is_dir() {
        eprintln!("Error: '{}' is not a directory", project_path.display());
        return false;
    }

    let project_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".to_string());

    // Print the welcome banner before any other output — only in interactive mode.
    crate::cli::print_welcome_banner(debug);

    println!();
    println!("{}", i18n::tf("cli.attaching", &[("name", &project_name)]));

    // Resolve image
    let tag = image_tag(image_name);

    println!();
    println!("{}", i18n::tf("cli.checking_image", &[("tag", &tag)]));

    // Check if image exists
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("Failed to create tokio runtime");

    let client = PodmanClient::new();

    // Verify podman is available
    let has_podman = rt.block_on(client.is_available());
    if !has_podman {
        eprintln!("{}", i18n::t("errors.no_podman"));
        return false;
    }

    // On macOS/Windows, ensure podman machine is initialized and running
    if tillandsias_core::state::Os::detect().needs_podman_machine() {
        if !rt.block_on(client.has_machine()) {
            if debug {
                eprintln!("  [debug] No podman machine found, initializing...");
            }
            rt.block_on(client.init_machine());
        }
        if !rt.block_on(client.is_machine_running()) {
            if debug {
                eprintln!("  [debug] Starting podman machine...");
            }
            if !rt.block_on(client.start_machine()) {
                eprintln!("  Podman machine failed to start. Try: podman machine init && podman machine start");
                return false;
            }
            // Wait for API to be ready
            rt.block_on(client.wait_for_ready(5));
        }
    }

    // Try to build image via build-image.sh if available (dev mode).
    // Falls back to checking if image already exists (installed mode).
    let source_name = if image_name.contains(':') || image_name.contains('/') {
        "forge"
    } else {
        image_name
    };

    // Check if image already exists — skip build if present
    let image_exists = rt.block_on(client.image_exists(&tag));
    if !image_exists {
        println!("  {}", i18n::t("cli.ensuring_image"));
        if let Err(e) = run_build_image_script(source_name, debug)
            && debug
        {
            eprintln!("  Build script failed: {e}");
        }
    }

    // Verify image exists (either pre-existing or just built)
    let image_exists = image_exists || rt.block_on(client.image_exists(&tag));
    if image_exists {
        let size = image_size_display(&tag);
        println!("{}", i18n::tf("cli.image_ready", &[("size", &size)]));
    } else {
        eprintln!("  \u{2717} {}", i18n::t("errors.env_not_ready"));
        return false;
    }

    // Load config for port range
    let global_config = load_global_config();
    let project_config = load_project_config(&project_path);
    let resolved = global_config.merge_with_project(&project_config);
    let base_port = GlobalConfig::parse_port_range(&resolved.port_range).unwrap_or((3000, 3019));

    // Use Aeranthos genus for CLI mode (no allocator needed)
    let genus = TillandsiaGenus::Aeranthos;
    let container_name = ContainerInfo::container_name(&project_name, genus);

    // Ensure cache directory exists
    let cache = cache_dir();
    if let Err(e) = std::fs::create_dir_all(&cache) {
        warn!(error = %e, path = %cache.display(), "Failed to create cache directory");
    }

    // @trace spec:enclave-network, spec:proxy-container, spec:git-mirror-service, spec:inference-container
    // Single unified enclave setup: network, proxy, inference, mirror, git service.
    // Creates dummy state/build_tx internally — CLI mode has no tray event loop.
    if let Err(e) = crate::handlers::ensure_enclave_ready_cli(&rt, &project_path, &project_name) {
        eprintln!("  \u{2717} {}", i18n::t("errors.env_not_ready"));
        if debug {
            eprintln!("  [debug] Enclave setup failed: {e}");
        }
        return false;
    }

    // Drop guard ensures service containers are cleaned up on ANY exit path:
    // normal return, panic, Ctrl+C (podman forwards SIGINT, container exits,
    // .status() returns, then guard drops during stack unwinding).
    // @trace spec:enclave-network
    let _enclave_guard = EnclaveCleanupGuard {
        project_name: project_name.clone(),
    };

    // Select profile based on mode: --bash uses terminal profile, otherwise forge.
    // --opencode / --claude override the configured agent for this session.
    let selected_agent = agent_override.unwrap_or(global_config.agent.selected);
    let profile = if bash {
        tillandsias_core::container_profile::terminal_profile()
    } else {
        match selected_agent {
            SelectedAgent::OpenCode => {
                tillandsias_core::container_profile::forge_opencode_profile()
            }
            SelectedAgent::Claude => {
                tillandsias_core::container_profile::forge_claude_profile()
            }
        }
    };

    let ctx = build_cli_launch_context(
        &container_name,
        &project_path,
        &project_name,
        &cache,
        base_port,
        &tag,
    );
    let mut run_args = crate::launch::build_podman_args(&profile, &ctx);
    // @trace spec:proxy-container
    crate::handlers::inject_ca_chain_mounts_pub(&mut run_args);

    println!();
    if bash {
        println!("{}", i18n::t("cli.starting_terminal"));
    } else {
        println!("{}", i18n::t("cli.starting_env"));
    }
    println!("  Name:   {container_name}");
    // Enclave-only containers don't expose ports to the host
    let is_enclave = ctx.network.as_deref().is_some_and(|n| n.starts_with(tillandsias_podman::ENCLAVE_NETWORK));
    if !is_enclave {
        println!("  Ports:  {}-{}", base_port.0, base_port.1);
    }

    // @trace spec:secret-management
    // Show credential-free status transparently
    println!();
    println!("  Security: credential-free (no tokens, no secrets mounted)");
    if !ctx.git_author_name.is_empty() {
        println!("  Git ID:   {} <{}>", ctx.git_author_name, ctx.git_author_email);
    } else {
        println!("  Git ID:   not configured (run: tillandsias --login)");
    }
    println!("  Code:     cloned from git mirror service (not host mount)");

    // @trace spec:enclave-network
    println!();
    println!("  Enclave:");
    println!("    proxy      \u{2192} strict:3128 (allowlist), permissive:3129 (builds)");
    println!("    git-service \u{2192} git://9418 (mirror)");
    println!("    inference  \u{2192} http://11434 (ollama, optional)");

    if debug {
        println!();
        let debug_cmd: Vec<_> = run_args.iter().map(|a| {
            if a.contains(' ') { format!("'{a}'") } else { a.clone() }
        }).collect();
        println!("  [debug] podman run {}", debug_cmd.join(" "));
    }

    println!();
    println!("{}", i18n::t("cli.launching"));
    println!();

    // Execute podman with inherited stdio — terminal passes through.
    // On Windows, use raw Command to avoid CREATE_NO_WINDOW from
    // podman_cmd_sync() — it kills the interactive TTY that `-it` needs.
    #[cfg(target_os = "windows")]
    let status = std::process::Command::new(tillandsias_podman::find_podman_path())
        .arg("run")
        .args(&run_args)
        .status();

    #[cfg(not(target_os = "windows"))]
    let status = tillandsias_podman::podman_cmd_sync()
        .arg("run")
        .args(&run_args)
        .status();

    println!();

    // Service container cleanup handled by EnclaveCleanupGuard (Drop).

    match status {
        Ok(s) => {
            println!("{}", i18n::t("cli.env_stopped"));
            s.success()
        }
        Err(e) => {
            eprintln!("Error: failed to run podman: {e}");
            false
        }
    }
}

/// Run the GitHub login flow interactively in the current terminal.
///
/// Phase 3: If a git service container is already running for any project,
/// exec `gh auth login` inside it. Otherwise, start a temporary git service
/// container with D-Bus access on the enclave network, run the auth flow,
/// and let `--rm` clean it up.
///
/// Returns `true` on success, `false` on failure.
///
/// @trace spec:git-mirror-service, spec:secret-management
pub fn run_github_login() -> bool {
    crate::cli::print_welcome_banner(false);

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    let client = tillandsias_podman::PodmanClient::new();
    let podman_path = tillandsias_podman::find_podman_path();

    // Check if any git service container is already running via podman ps.
    // @trace spec:git-mirror-service
    let running_git = {
        let output = tillandsias_podman::podman_cmd_sync()
            .args(["ps", "--filter", "name=tillandsias-git-", "--format", "{{.Names}}"])
            .output();
        match output {
            Ok(o) if o.status.success() => {
                let names = String::from_utf8_lossy(&o.stdout);
                names.lines().next().map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
            }
            _ => None,
        }
    };

    if let Some(container_name) = running_git {
        println!();
        println!("  Found running git service: {container_name}");
        println!("  Running GitHub authentication inside it...");
        println!();

        let status = std::process::Command::new(&podman_path)
            .args(["exec", "-it", &container_name, "gh", "auth", "login", "--git-protocol", "https"])
            .stdin(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit())
            .status();

        return match status {
            Ok(s) => {
                if s.success() {
                    println!();
                    println!("  GitHub authentication complete.");
                    crate::secrets::migrate_token_to_keyring();
                }
                s.success()
            }
            Err(e) => {
                eprintln!("  Error: failed to exec into git service: {e}");
                false
            }
        };
    }

    // No git service running — ensure git image exists and start a temporary container.
    let tag = crate::handlers::git_image_tag();

    if !rt.block_on(client.image_exists(&tag)) {
        println!();
        println!("  Building git service image first...");
        if let Err(e) = run_build_image_script("git", false) {
            eprintln!("  Failed to build git service image: {e}");
            return false;
        }
    }

    // Ensure enclave network exists.
    if let Err(e) = rt.block_on(crate::handlers::ensure_enclave_network()) {
        eprintln!("  Warning: enclave network setup failed: {e}");
    }

    // On Windows, run gh auth login directly via podman (no bash).
    // On Unix, use the same direct approach (Phase 3 no longer needs the script).
    #[cfg(target_os = "windows")]
    return run_github_login_direct(&tag);

    #[cfg(not(target_os = "windows"))]
    return run_github_login_git_service(&tag);
}

/// Windows: run `gh auth login` directly in a temporary git service container via podman.
/// No bash, no scripts — just podman run.
// @trace spec:secret-management, spec:cross-platform, spec:git-mirror-service
#[cfg(target_os = "windows")]
fn run_github_login_direct(tag: &str) -> bool {

    let cache = tillandsias_core::config::cache_dir();
    let secrets_dir = cache.join("secrets");
    let gh_dir = secrets_dir.join("gh");
    let git_dir = secrets_dir.join("git");
    let gitconfig = git_dir.join(".gitconfig");

    if let Err(e) = std::fs::create_dir_all(&gh_dir) {
        warn!(error = %e, path = %gh_dir.display(), "Failed to create cache directory");
    }
    if let Err(e) = std::fs::create_dir_all(&git_dir) {
        warn!(error = %e, path = %git_dir.display(), "Failed to create cache directory");
    }
    if !gitconfig.exists() {
        if let Err(e) = std::fs::write(&gitconfig, "") {
            warn!(error = %e, path = %gitconfig.display(), "Failed to initialize gitconfig");
        }
    }

    // Prompt for git identity
    println!();
    println!("=== GitHub Login ===");
    println!();

    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();

    // Read existing name/email from gitconfig
    let existing_name = read_gitconfig_value(&gitconfig, "name");
    let existing_email = read_gitconfig_value(&gitconfig, "email");

    let git_name = prompt_with_default(&stdin, &mut stdout, "Your name (for git commits)", &existing_name);
    let git_email = prompt_with_default(&stdin, &mut stdout, "Your email (for git commits)", &existing_email);

    if git_name.is_empty() || git_email.is_empty() {
        eprintln!("  Name and email are required.");
        return false;
    }

    // Write gitconfig
    let gitconfig_content = format!("[user]\n\tname = {git_name}\n\temail = {git_email}\n");
    match std::fs::write(&gitconfig, gitconfig_content) {
        Ok(()) => println!("  Git identity saved: {git_name} <{git_email}>"),
        Err(e) => eprintln!("  WARNING: Failed to save git identity: {e}"),
    }

    // Security flags (same as gh-auth-login.sh)
    let security_flags = [
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        "--userns=keep-id",
        "--security-opt=label=disable",
    ];

    println!();
    println!("  Starting GitHub authentication...");
    println!("  (You'll be prompted to paste a GitHub token)");
    println!();

    // Run gh auth login interactively in forge container.
    // Use raw Command (not podman_cmd_sync) to avoid CREATE_NO_WINDOW
    // which kills the interactive TTY that gh auth login needs.
    let status = std::process::Command::new(tillandsias_podman::find_podman_path())
        .args(["run", "-it", "--rm", "--init", "--name", "tillandsias-gh-login"])
        .args(security_flags)
        .args(["--entrypoint", ""])
        .args(["-e", "GIT_CONFIG_GLOBAL=/home/forge/.config/tillandsias-git/.gitconfig"])
        .arg("-v").arg(format!("{}:/home/forge/.config/gh", gh_dir.display()))
        .arg("-v").arg(format!("{}:/home/forge/.config/tillandsias-git:rw", git_dir.display()))
        .arg(tag)
        .args(["gh", "auth", "login", "--git-protocol", "https"])
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status();

    if let Ok(s) = &status {
        if !s.success() {
            eprintln!("  GitHub authentication failed.");
            return false;
        }
    }

    // Run setup-git in a separate non-interactive container
    let _ = tillandsias_podman::podman_cmd_sync()
        .args(["run", "--rm", "--init"])
        .args(security_flags)
        .args(["--entrypoint", ""])
        .arg("-v").arg(format!("{}:/home/forge/.config/gh", gh_dir.display()))
        .arg("-v").arg(format!("{}:/home/forge/.config/tillandsias-git:rw", git_dir.display()))
        .arg(tag)
        .args(["gh", "auth", "setup-git"])
        .output();

    println!();
    println!("  GitHub authentication complete.");
    println!();

    // Migrate the token from hosts.yml to the native keyring so
    // subsequent launches can inject it via tmpfs.
    crate::secrets::migrate_token_to_keyring();

    true
}

#[cfg(target_os = "windows")]
fn read_gitconfig_value(path: &std::path::Path, key: &str) -> String {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .find_map(|line| {
            let trimmed = line.trim();
            if trimmed.starts_with(key) {
                trimmed.split('=').nth(1).map(|v| v.trim().to_string())
            } else {
                None
            }
        })
        .unwrap_or_default()
}

#[cfg(target_os = "windows")]
fn prompt_with_default(
    stdin: &std::io::Stdin,
    stdout: &mut std::io::Stdout,
    prompt: &str,
    default: &str,
) -> String {
    use std::io::Write;
    use std::io::BufRead;
    if default.is_empty() {
        print!("  {prompt}: ");
    } else {
        print!("  {prompt} [{default}]: ");
    }
    if let Err(e) = stdout.flush() {
        warn!(error = %e, "Failed to flush stdout for user prompt");
    }
    let mut input = String::new();
    // read_line failure yields empty input, which falls back to default — acceptable
    let _ = stdin.lock().read_line(&mut input);
    let trimmed = input.trim().to_string();
    if trimmed.is_empty() { default.to_string() } else { trimmed }
}

/// Unix: run `gh auth login` in a temporary git service container on the enclave network.
/// @trace spec:git-mirror-service, spec:enclave-network
#[cfg(not(target_os = "windows"))]
fn run_github_login_git_service(tag: &str) -> bool {
    println!();
    println!("  Starting GitHub authentication...");
    println!("  (You'll be prompted to paste a GitHub token)");
    println!();

    let network = tillandsias_podman::ENCLAVE_NETWORK;

    let status = tillandsias_podman::podman_cmd_sync()
        .args([
            "run", "-it", "--rm", "--init",
            "--name", "tillandsias-gh-login",
            "--cap-drop=ALL",
            "--security-opt=no-new-privileges",
            "--userns=keep-id",
            "--security-opt=label=disable",
            &format!("--network={network}"),
            "--entrypoint=",
        ])
        .arg(tag)
        .args(["gh", "auth", "login", "--git-protocol", "https"])
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status();

    match status {
        Ok(s) => {
            if s.success() {
                println!();
                println!("  GitHub authentication complete.");
                println!();
                crate::secrets::migrate_token_to_keyring();
            } else {
                eprintln!("  GitHub authentication failed.");
            }
            s.success()
        }
        Err(e) => {
            eprintln!("Error: failed to run GitHub login container: {e}");
            false
        }
    }
}
