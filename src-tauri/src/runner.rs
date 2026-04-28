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
/// (normal return, panic, SIGINT after podman forwards it, etc.) — but only
/// when no tray was spawned alongside this CLI session. When a graphical
/// session is detected, the tray child takes over enclave ownership and
/// this guard becomes a no-op so the tray's containers survive CLI exit.
///
/// @trace spec:enclave-network, spec:tray-cli-coexistence, spec:cli-mode
struct EnclaveCleanupGuard {
    project_name: String,
}

impl Drop for EnclaveCleanupGuard {
    fn drop(&mut self) {
        // If the parent CLI ran in a graphical session, a tray child was
        // spawned and now owns the enclave (proxy/git/inference). Tearing
        // down here would yank infrastructure out from under it. The tray's
        // own crash-recovery sweep handles the case where the tray spawn
        // failed silently.
        // @trace spec:tray-cli-coexistence
        if crate::desktop_env::has_graphical_session() {
            tracing::debug!(
                spec = "tray-cli-coexistence",
                project = %self.project_name,
                "EnclaveCleanupGuard skipped — tray child owns the enclave"
            );
            return;
        }

        // Headless CLI: nothing else owns these containers, so clean up.
        // Build a minimal tokio runtime for async cleanup.
        // This is safe in Drop — we're the last thing running before process exit.
        if let Ok(rt) = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            rt.block_on(async {
                let runtime = default_runtime();
                crate::handlers::stop_git_service(&self.project_name, runtime.clone()).await;
                crate::handlers::stop_inference(runtime.clone()).await;
                crate::handlers::stop_proxy(runtime).await;
                crate::handlers::cleanup_enclave_network().await;
            });
        }
    }
}
use tillandsias_podman::PodmanClient;
use tillandsias_podman::runtime::default_runtime;

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
    // Serialize all image builds — rootless podman corrupts overlay storage
    // when concurrent `podman build` operations run simultaneously.
    // Uses the same global mutex from handlers.rs.
    // @trace spec:default-image
    let _build_guard = crate::handlers::build_mutex_lock();

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

    let tag = crate::handlers::forge_image_tag();

    if debug {
        println!("  [debug] Resolved image build context for tag {}", tag);
    }

    // @trace spec:cross-platform, spec:windows-wsl-runtime
    // On Windows, the runtime backend is WSL (no podman). The forge image is
    // already an imported WSL distro (tillandsias-forge) created by `--init`.
    // We do NOT call podman build here — that would launch a non-existent
    // process and cascade-fail attach. Instead: verify the distro exists.
    // If missing, surface a clear error directing the user to `--init`.
    //
    // (origin/main carried a stub `podman build` arm here from earlier
    // unblock-work; superseded by this WSL-distro check, dropped per user
    // direction during merge.)
    #[cfg(target_os = "windows")]
    {
        let _ = source_dir; // unused on Windows path
        let distro = format!("tillandsias-{}", image_name);
        let mut listing_cmd = std::process::Command::new("wsl.exe");
        tillandsias_podman::no_window_sync(&mut listing_cmd);
        let listing = listing_cmd
            .args(["--list", "--quiet"])
            .output()
            .map_err(|e| {
                eprintln!("  [error] Cannot query WSL: {e}");
                strings::SETUP_ERROR
            })?;
        let raw = listing.stdout;
        // wsl --list --quiet emits UTF-16 LE; strip nulls/CRs to scan ASCII.
        let text: String = raw.iter().filter(|&&b| b != 0 && b != b'\r').map(|&b| b as char).collect();
        let exists = text.lines().any(|line| line.trim() == distro);
        crate::build_lock::release(image_name);
        if exists {
            if debug {
                eprintln!("  [debug] WSL distro {} present — skipping build (Windows uses WSL runtime, not podman)", distro);
            }
            return Ok(());
        }
        eprintln!(
            "  [error] WSL distro '{}' not imported. Run: tillandsias --init",
            distro
        );
        return Err(strings::SETUP_ERROR.into());
    }

    // On Unix and Windows, call podman build directly.
    // Image builds do NOT go through the proxy — SSL bump requires CA trust
    // that build containers don't have. See handlers.rs for full rationale.
    // @trace spec:direct-podman-calls
    #[cfg(not(target_os = "windows"))]
    {
        let containerfile = source_dir.join("images").join("default").join("Containerfile");
        // Use source_dir as context so all COPY commands work (scripts/, images/default/, config-overlay/, etc)
        let context_dir = &source_dir;

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
            .arg(context_dir)
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
            // Prune older versioned forge images to reclaim disk space
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
/// no on-disk gh state, no Claude dir mounts. Git identity comes from
/// env vars.
///
/// @trace spec:native-secrets-store
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

    let port_mapping = tillandsias_core::state::Os::detect().needs_podman_machine();

    // @trace spec:forge-hot-cold-split
    // Compute the per-launch tmpfs budget for /home/forge/src from the bare
    // git mirror's pack size (same logic as the tray handler path).
    let global_cfg = tillandsias_core::config::load_global_config();
    let hot_path_budget_mb = crate::launch::compute_hot_budget_with_limits(
        project_name,
        cache,
        global_cfg.forge.hot_path_inflation,
        global_cfg.forge.hot_path_max_mb,
    );

    tillandsias_core::container_profile::LaunchContext {
        container_name: container_name.to_string(),
        project_path: project_path.to_path_buf(),
        project_name: project_name.to_string(),
        cache_dir: cache.to_path_buf(),
        port_range,
        host_os,
        detached: false,
        is_watch_root: false,
        custom_mounts: project_config.mounts,
        image_tag: image_tag.to_string(),
        selected_language: global_cfg.i18n.language.clone(),
        // @trace spec:enclave-network
        // On Linux: CLI-mode forge containers join the enclave network.
        // On podman machine: no network flag (default), localhost port mapping.
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
    diagnostics: bool,
    bash: bool,
    agent_override: Option<SelectedAgent>,
    prompt: Option<String>,
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
        Ok(p) => crate::embedded::simplify_path(&p),
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

    // @trace spec:runtime-diagnostics-stream, spec:cross-platform
    // Start diagnostics streaming AS EARLY AS POSSIBLE so the tails see the
    // git-daemon spawn, forge entrypoint, etc., from frame 1. The handle is
    // held until this function returns (Drop kills the children).
    let _diag_handle = if diagnostics {
        Some(crate::diagnostics::start())
    } else {
        None
    };

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

    // @trace spec:cli-mode, spec:app-lifecycle
    // First Ctrl+C: clean up enclave infrastructure and exit 0.
    // Second Ctrl+C: fall through to default termination (so user can always
    // force-quit). The handler runs in a tokio task on the same runtime that
    // drives podman; the foreground `podman run -it --rm` still owns the TTY.
    //
    // When a tray child is running alongside this CLI (graphical session),
    // Ctrl+C just exits this CLI cleanly — the tray and the enclave keep
    // serving the user's other projects. The forge container dies with
    // --rm naturally because podman receives the SIGINT before us.
    //
    // When headless (no tray), this CLI is the sole owner of the enclave
    // and we tear it down explicitly so nothing is left running after exit.
    //
    // A second Ctrl+C falls through to default termination so the user can
    // always force-quit if cleanup hangs.
    let cleanup_started = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    {
        let started = cleanup_started.clone();
        let project_for_cleanup = project_name.clone();
        rt.spawn(async move {
            // Wait for first SIGINT.
            let _ = tokio::signal::ctrl_c().await;
            if started
                .compare_exchange(
                    false,
                    true,
                    std::sync::atomic::Ordering::SeqCst,
                    std::sync::atomic::Ordering::SeqCst,
                )
                .is_err()
            {
                return;
            }
            // i18n key `cli.stopping` does not exist yet — hardcoded English
            // for v1; translate when the rest of the cli.* family gets a pass.
            eprintln!("\n  Stopping...");

            // @trace spec:tray-cli-coexistence, spec:cli-mode
            if crate::desktop_env::has_graphical_session() {
                eprintln!("  Tray is still running — open the menu for project actions.");
                std::process::exit(0);
            }

            // Headless: this CLI is the sole owner. Tear down the enclave.
            let runtime = default_runtime();
            crate::handlers::stop_git_service(&project_for_cleanup, runtime.clone()).await;
            crate::handlers::stop_inference(runtime.clone()).await;
            crate::handlers::stop_proxy(runtime).await;
            crate::handlers::cleanup_enclave_network().await;
            std::process::exit(0);
        });
    }

    let client = PodmanClient::new();

    // Verify podman is available
    let has_podman = rt.block_on(client.is_available());
    if !has_podman {
        eprintln!("{}", i18n::t("errors.no_podman"));
        return false;
    }

    // @trace spec:cross-platform, spec:windows-wsl-runtime, spec:podman-orchestration
    // On macOS, ensure podman machine is initialized and running. On Windows
    // we DO NOT need podman machine — Tillandsias runs against WSL2 distros
    // directly (tillandsias-forge, tillandsias-git, tillandsias-proxy,
    // tillandsias-router, tillandsias-inference) imported by `--init`. The
    // podman-machine-default WSL distro that Podman Desktop creates is
    // unrelated and irrelevant; querying it via the podman REST API can
    // transiently report "not running" even when it is, blocking attach
    // unnecessarily. Linux uses native podman without a machine.
    #[cfg(target_os = "macos")]
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

    // Tools overlay tombstoned — agents hard-installed in forge image.
    // @trace spec:tombstone-tools-overlay

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
            // @trace spec:opencode-web-session
            SelectedAgent::OpenCodeWeb => {
                tillandsias_core::container_profile::forge_opencode_web_profile()
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

    // @trace spec:runtime-diagnostics
    // Pass user-provided prompt to the agent via environment variable
    if let Some(prompt_text) = prompt {
        run_args.push("--env".to_string());
        run_args.push(format!("TILLANDSIAS_PROMPT={}", prompt_text));
    }

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

    // @trace spec:secrets-management
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
    if ctx.use_port_mapping {
        println!("  Enclave (port mapping):");
        println!("    proxy      \u{2192} localhost:3128 (allowlist), localhost:3129 (builds)");
        println!("    git-service \u{2192} localhost:9418 (mirror)");
        println!("    inference  \u{2192} localhost:11434 (ollama, optional)");
    } else {
        println!("  Enclave:");
        println!("    proxy      \u{2192} strict:3128 (allowlist), permissive:3129 (builds)");
        println!("    git-service \u{2192} git://9418 (mirror)");
        println!("    inference  \u{2192} http://11434 (ollama, optional)");
    }

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

    // @trace spec:cross-platform, spec:windows-wsl-runtime, spec:git-mirror-service
    // Windows: launch forge via wsl.exe directly. Drop the podman run_args
    // (mounts, --userns, --cap-drop, etc.) — those are podman-specific.
    //
    // Architecture preserved from Linux/podman:
    //  - Forge clones the project from git://localhost:9418/<project> at
    //    entrypoint startup (NOT bind-mounted). All WSL2 distros share one
    //    netns; the git daemon in tillandsias-git binds 127.0.0.1:9418 and
    //    is reachable from the forge distro at the same address.
    //  - Working tree lives in the forge distro (ephemeral; lost on stop).
    //  - Mirror lives on host at %LOCALAPPDATA%/tillandsias/mirrors/<project>
    //    (long-lived). Bare repo there is the bridge to GitHub.
    //
    // We pass TILLANDSIAS_GIT_SERVICE=localhost so the entrypoint's
    // `git clone git://${TILLANDSIAS_GIT_SERVICE}:9418/...` resolves correctly.
    // Bash mode skips the entrypoint and goes straight to /bin/bash in the
    // distro's home (no project clone — bash mode is for diagnostics).
    #[cfg(target_os = "windows")]
    let status = {
        let _ = &run_args; // unused on Windows path
        let distro = "tillandsias-forge";
        let mut cmd = std::process::Command::new("wsl.exe");
        cmd.arg("-d").arg(distro)
            .arg("--user").arg("forge");

        // For bash mode: cd to a project working dir on /mnt/c/... so the
        // user can poke at the source on the host. For opencode/claude:
        // start in /home/forge so the entrypoint's clone lands in
        // /home/forge/src/<project> (matching Linux semantics).
        if bash {
            let cwd_arg: String = {
                let p = project_path.to_string_lossy();
                let bytes = p.as_bytes();
                if bytes.len() >= 3 && bytes[1] == b':' && (bytes[2] == b'\\' || bytes[2] == b'/') {
                    let drive = (bytes[0] as char).to_ascii_lowercase();
                    let rest = p[2..].replace('\\', "/");
                    format!("/mnt/{drive}{rest}")
                } else {
                    p.into_owned()
                }
            };
            cmd.arg("--cd").arg(&cwd_arg).arg("--").arg("/bin/bash").arg("-l");
        } else {
            // Pass env vars for the entrypoint via wsl.exe -e prefix:
            // wsl.exe doesn't have --env so we wrap the entrypoint in env(1).
            let entry = match selected_agent {
                SelectedAgent::OpenCode => "/usr/local/bin/entrypoint-forge-opencode.sh",
                SelectedAgent::Claude => "/usr/local/bin/entrypoint-forge-claude.sh",
                SelectedAgent::OpenCodeWeb => "/usr/local/bin/entrypoint-forge-opencode-web.sh",
            };
            // @trace spec:cross-platform, spec:windows-wsl-runtime, spec:git-mirror-service
            // Match Linux flow: forge clones from git://localhost:9418/<project>.
            // Requires WSL2 mirrored networking (configured in ~/.wslconfig).
            // The git daemon runs in tillandsias-git distro (started by
            // ensure_git_service_running_wsl) and shares localhost with this
            // forge distro under mirrored mode.
            cmd.arg("--cd").arg("/home/forge").arg("--exec").arg("env")
                .arg(format!("TILLANDSIAS_PROJECT={}", project_name))
                .arg("TILLANDSIAS_GIT_SERVICE=localhost:9418")
                .arg("TILLANDSIAS_AGENT=opencode")
                .arg("LANG=en_US.UTF-8")
                .arg("LANGUAGE=en_US.UTF-8")
                .arg(format!("GIT_AUTHOR_NAME={}", ctx.git_author_name))
                .arg(format!("GIT_AUTHOR_EMAIL={}", ctx.git_author_email))
                .arg(format!("GIT_COMMITTER_NAME={}", ctx.git_author_name))
                .arg(format!("GIT_COMMITTER_EMAIL={}", ctx.git_author_email));
            // @trace spec:runtime-diagnostics-stream
            // --diagnostics implies TILLANDSIAS_DEBUG=1 so the entrypoint's
            // trace_lifecycle calls actually emit (stderr + log file).
            if diagnostics {
                cmd.arg("TILLANDSIAS_DEBUG=1");
            }
            cmd.arg(entry);
        }
        cmd.status()
    };

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
            // @trace spec:cli-mode, spec:tray-cli-coexistence
            // On a graphical session main.rs spawned the tray child before
            // calling runner::run, so by the time podman exits cleanly the
            // tray is still up. Tell the user where Tillandsias went.
            // Headless sessions never get a tray, so suppress the line.
            if crate::desktop_env::has_graphical_session() {
                println!("  \u{2713} OpenCode session ended \u{2014} Tillandsias tray is still running.");
            }
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
/// container on the default bridge network (for direct internet to github.com),
/// run the auth flow, and let `--rm` clean it up.
///
/// Returns `true` on success, `false` on failure.
///
/// @trace spec:git-mirror-service, spec:secrets-management
pub fn run_github_login() -> bool {
    crate::cli::print_welcome_banner(false);

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    let client = tillandsias_podman::PodmanClient::new();

    // Always launch a dedicated ephemeral container for the auth flow.
    //
    // Rationale: an already-running per-project git-service is `--read-only`
    // with a tmpfs list that does NOT include `/home/git/.config`. `gh auth
    // login` would try to mkdir that path and fail. Even if we widened the
    // tmpfs, exec'ing into the long-lived service would skip the host-side
    // `gh auth token` extraction + keyring store, leaving the host vault
    // empty. One unified path: `run_github_login_git_service` spins up its
    // own writable container, runs the auth, extracts the token, persists
    // to the host OS keyring, then tears the container down.
    // @trace spec:git-mirror-service, spec:secrets-management, spec:native-secrets-store
    let tag = crate::handlers::git_image_tag();

    if !rt.block_on(client.image_exists(&tag)) {
        println!();
        println!("  Building git service image first...");
        if let Err(e) = run_build_image_script("git", false) {
            eprintln!("  Failed to build git service image: {e}");
            return false;
        }
    }

    // Run gh auth login in a temporary GIT SERVICE container (NOT forge).
    // The forge is UNTRUSTED (runs AI-generated code, npm deps, etc).
    // GitHub credentials must NEVER touch the forge environment.
    // The git service image now has gh installed (Alpine github-cli package).
    // No enclave network needed — the login container uses default bridge
    // for direct internet access to github.com.
    // @trace spec:secrets-management
    run_github_login_git_service(&tag)
}

/// Run `gh auth login` in a temporary git service container, then extract
/// the OAuth token + username and persist them to the host's native keyring.
///
/// Lifecycle:
///   1. Prompt for git identity (name/email) → host `<cache>/secrets/git/.gitconfig`
///   2. Start a keep-alive git-service container (no host mount, no `--rm`)
///   3. `podman exec -it` into it to run `gh auth login` interactively
///   4. `podman exec` to run `gh auth token` + `gh api user --jq .login`
///   5. Store the token in the native keyring via `secrets::store_github_token`
///      (Windows Credential Manager / macOS Keychain / Linux Secret Service)
///   6. `podman stop` + `podman rm` the keep-alive container — all gh state
///      dies with it
///
/// Uses the default bridge network (NOT the enclave) — the login container
/// only needs direct internet access to github.com for the OAuth flow.
///
/// @trace spec:git-mirror-service, spec:secrets-management, spec:native-secrets-store
fn run_github_login_git_service(tag: &str) -> bool {
    let cache = tillandsias_core::config::cache_dir();
    let gitconfig = cache.join("secrets").join("git").join(".gitconfig");
    if let Some(parent) = gitconfig.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    // @trace spec:secrets-management
    // Git identity prompt — always ask during GitHub Login so the user can
    // confirm or correct values. Pre-fill the defaults from the tillandsias
    // cache if set; otherwise fall back to the host `~/.gitconfig`. Whatever
    // the user accepts (or types) is written to the cache gitconfig — that's
    // the copy forge containers mount for commit authorship.
    let (default_name, default_email) = crate::launch::read_git_identity(&cache);
    println!();
    println!("  Confirm your git identity (used for commit authorship).");
    println!("  Press Enter to accept the default in brackets.");
    println!();

    let name = prompt_with_default("  Your name", &default_name);
    let email = prompt_with_default("  Your email", &default_email);

    if name.is_empty() || email.is_empty() {
        eprintln!("  Name and email are required — aborting.");
        return false;
    }
    let content = format!("[user]\n\tname = {name}\n\temail = {email}\n");
    if let Err(e) = std::fs::write(&gitconfig, &content) {
        eprintln!("  Error: failed to save git identity to {}: {e}", gitconfig.display());
        return false;
    }
    println!("  \u{2713} Git identity saved.");
    println!();

    println!("  Starting GitHub authentication...");
    println!("  (Running in the trusted git service container — credentials never touch the forge)");
    println!();

    // Shared security flags across every podman invocation below.
    // @trace spec:secrets-management
    let security_flags = [
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        "--userns=keep-id",
        "--security-opt=label=disable",
    ];

    let podman_path = tillandsias_podman::find_podman_path();
    let container_name = "tillandsias-gh-login";

    // Defensive cleanup: a previous aborted run may have left the container
    // behind. `podman rm -f` on a missing name is a harmless no-op.
    let _ = tillandsias_podman::podman_cmd_sync()
        .args(["rm", "-f", container_name])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    // @trace spec:native-secrets-store
    // Step 1: start a keep-alive container. NO host mount for gh state —
    // the OAuth token will be harvested via `gh auth token` inside this same
    // container and stored in the host keyring. When we stop + rm the
    // container below, all gh on-disk state is destroyed with it.
    let start_status = tillandsias_podman::podman_cmd_sync()
        .args(["run", "-d", "--init"])
        .args(["--name", container_name])
        .args(security_flags)
        .args(["--entrypoint", "sleep"])
        .arg(tag)
        .arg("infinity")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::inherit())
        .status();
    match start_status {
        Ok(s) if s.success() => {}
        Ok(_) => {
            eprintln!("  Error: failed to start login container.");
            return false;
        }
        Err(e) => {
            eprintln!("  Error: failed to start login container: {e}");
            return false;
        }
    }

    // Drop guard: stop + rm the container on every exit path below so a
    // failed flow doesn't leak credentials-bearing state.
    struct LoginContainerGuard<'a> {
        podman: &'a str,
        name: &'a str,
    }
    impl Drop for LoginContainerGuard<'_> {
        fn drop(&mut self) {
            let _ = std::process::Command::new(self.podman)
                .args(["rm", "-f", self.name])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();
        }
    }
    let _guard = LoginContainerGuard {
        podman: podman_path,
        name: container_name,
    };

    // Step 2: interactive `gh auth login` via podman exec. Use raw Command
    // (not podman_cmd_sync) so stdin/stdout/stderr inherit the real TTY —
    // the CREATE_NO_WINDOW wrapper in podman_cmd_sync on Windows breaks the
    // interactive device-code flow.
    // @trace spec:secrets-management, spec:cross-platform
    let status = std::process::Command::new(podman_path)
        .args(["exec", "-it", container_name])
        .args(["gh", "auth", "login", "--git-protocol", "https"])
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status();
    match status {
        Ok(s) if s.success() => {}
        Ok(_) => {
            eprintln!("  GitHub authentication failed.");
            return false;
        }
        Err(e) => {
            eprintln!("  Error: failed to exec gh auth login: {e}");
            return false;
        }
    }

    // Step 3: extract token via `gh auth token`.
    //
    // Security posture for the extraction:
    //   - stdin = Stdio::null  → child can't read host stdin
    //   - stdout = Stdio::piped → token bytes flow into a memory buffer in
    //     this host process; they NEVER reach a terminal device. Even if
    //     the user invoked `tillandsias --github-login` from a TTY, the
    //     pipe redirection severs the child's stdout from the parent's
    //     terminal fd before the child runs. Belt-and-suspenders: explicit
    //     here so future changes to `podman_cmd_sync()` defaults can't
    //     silently revert to Stdio::inherit.
    //   - stderr = Stdio::piped → captured for diagnostics; gh's stderr
    //     never contains the token, but on error we redact stderr below
    //     before printing.
    //   - The captured token is wrapped in `zeroize::Zeroizing<String>` so
    //     its heap allocation is overwritten when the local goes out of
    //     scope, mitigating process-memory scrape / core-dump disclosure.
    // @trace spec:secrets-management, spec:native-secrets-store
    use zeroize::Zeroizing;
    let token_out = tillandsias_podman::podman_cmd_sync()
        .args(["exec", container_name, "gh", "auth", "token"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .output();
    let token: Zeroizing<String> = match token_out {
        Ok(o) if o.status.success() => {
            Zeroizing::new(String::from_utf8_lossy(&o.stdout).trim().to_string())
        }
        Ok(o) => {
            // Don't echo gh's stderr verbatim — it shouldn't contain the
            // token but we don't want to be the one to find out otherwise.
            // Surface a generic message; raw stderr is in the file logs only.
            tracing::error!(
                spec = "secrets-management",
                exit_code = o.status.code().unwrap_or(-1),
                "gh auth token failed (raw stderr suppressed from console for safety)"
            );
            eprintln!("  Error: `gh auth token` exited non-zero. See file logs under `--log-secrets-management` for details.");
            return false;
        }
        Err(e) => {
            eprintln!("  Error: failed to run `gh auth token`: {e}");
            return false;
        }
    };
    if token.is_empty() {
        eprintln!("  Error: extracted empty token from gh — aborting.");
        return false;
    }

    // Step 4: extract GitHub username via `gh api user`. Same headless
    // piping discipline (defense-in-depth even though `--jq .login` only
    // returns a public-by-design username field).
    let user_out = tillandsias_podman::podman_cmd_sync()
        .args(["exec", container_name, "gh", "api", "user", "--jq", ".login"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .output();
    let github_user = match user_out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => String::new(), // non-fatal; username is advisory
    };

    // Step 5: persist token in the host OS keyring. The `&str` deref of
    // Zeroizing<String> is what crosses into the keyring API; the keyring
    // crate copies it once into the OS vault and our local buffer is
    // wiped on Drop at the end of this function.
    // @trace spec:native-secrets-store, spec:secrets-management
    if let Err(e) = crate::secrets::store_github_token(&token) {
        eprintln!("  Error: failed to store token in host keyring: {e}");
        return false;
    }

    // Step 6: the drop guard will tear down the container on return,
    // destroying the ephemeral gh on-disk state with it.

    println!();
    if github_user.is_empty() {
        println!("  \u{2713} GitHub token saved to host keyring.");
    } else {
        println!("  \u{2713} GitHub token saved to host keyring for {github_user}.");
    }
    println!();
    true
}

fn prompt_with_default(label: &str, default: &str) -> String {
    use std::io::{Write, BufRead};
    let stdout = std::io::stdout();
    let stdin = std::io::stdin();

    if default.is_empty() {
        print!("{label}: ");
    } else {
        print!("{label} [{default}]: ");
    }
    if let Err(e) = stdout.lock().flush() {
        warn!(error = %e, "Failed to flush stdout");
    }

    let mut input = String::new();
    let _ = stdin.lock().read_line(&mut input);
    let trimmed = input.trim();
    if trimmed.is_empty() {
        default.to_string()
    } else {
        trimmed.to_string()
    }
}

/// Stream /strategic/service.log from all running containers for a project.
/// Observation-only — does not start any containers.
/// Returns true on clean exit (Ctrl+C), false if no containers found.
///
/// Stream /strategic/service.log from all running containers for a project.
/// Observation-only — does not start any containers.
/// Returns true on clean exit (Ctrl+C), false if no containers found.
///
/// @trace spec:runtime-diagnostics
pub fn run_diagnostics(path: PathBuf, prompt: Option<String>) -> bool {
    let _ = prompt; // Currently unused, reserved for future agent integration
    let project_name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".to_string());

    println!();
    println!("  Diagnostics — streaming logs for '{project_name}'");
    println!("  (Ctrl+C to exit)");
    println!();

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");

    rt.block_on(async move {
        use tokio::io::{AsyncBufReadExt, BufReader};

        #[cfg(unix)]
        let mut ctrl_c = match tokio::signal::unix::signal(
            tokio::signal::unix::SignalKind::interrupt(),
        ) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("  [diagnostics] Cannot install signal handler: {e}");
                return false;
            }
        };

        let mut known: std::collections::HashSet<String> = Default::default();
        let mut exit_requested = false;

        loop {
            // Check for Ctrl+C
            #[cfg(unix)]
            if known.len() > 0 {
                tokio::select! {
                    _ = ctrl_c.recv() => {
                        exit_requested = true;
                    }
                    _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {}
                }
            }

            #[cfg(windows)]
            {
                tokio::select! {
                    _ = tokio::signal::ctrl_c() => {
                        exit_requested = true;
                    }
                    _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {}
                }
            }

            if exit_requested {
                println!();
                println!("  Diagnostics session ended.");
                return true;
            }

            // Discover running containers for this project.
            // @trace spec:runtime-diagnostics
            let output = match tokio::process::Command::new("podman")
                .args(["ps", "--format", "{{.Names}}", "--filter", "status=running"])
                .output()
                .await
            {
                Ok(o) => o,
                Err(_) => {
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                    continue;
                }
            };

            // Filter containers matching pattern: tillandsias-<project>-<genus> or tillandsias-git-<project>
            // @trace spec:runtime-diagnostics
            let names: Vec<String> = String::from_utf8_lossy(&output.stdout)
                .lines()
                .map(str::trim)
                .filter(|n| {
                    n.contains(&format!("tillandsias-{project_name}-"))
                        || *n == format!("tillandsias-git-{project_name}")
                })
                .map(str::to_string)
                .collect();

            if known.is_empty() && names.is_empty() {
                println!("  No running containers found for project '{project_name}'.");
                return false;
            }

            for name in &names {
                if known.contains(name) {
                    continue;
                }
                known.insert(name.clone());

                // Parse container name to service identifier (e.g., tillandsias-java-aeranthos → aeranthos)
                // @trace spec:runtime-diagnostics
                let service = diagnostics_service_name(&name, &project_name);
                println!("  [{service}] attaching...");

                // Stream /strategic/service.log from container via podman exec tail -f
                // @trace spec:runtime-diagnostics
                let child = tokio::process::Command::new("podman")
                    .args(["exec", &name, "tail", "-f", "/strategic/service.log"])
                    .stdout(std::process::Stdio::piped())
                    .stderr(std::process::Stdio::null())
                    .spawn();

                match child {
                    Ok(mut c) => {
                        if let Some(stdout) = c.stdout.take() {
                            let svc = service.clone();
                            // Spawn async task to read and print log lines
                            // @trace spec:runtime-diagnostics
                            tokio::spawn(async move {
                                let mut lines = BufReader::new(stdout).lines();
                                while let Ok(Some(line)) = lines.next_line().await {
                                    println!("[{svc}] {line}");
                                }
                                println!("[{svc}] [offline]");
                            });
                        }
                    }
                    Err(_) => println!("[{service}] [offline]"),
                }
            }

            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        }
    })
}

/// Extract service name from container name.
/// Examples: tillandsias-java-aeranthos → aeranthos, tillandsias-git-java → git
/// @trace spec:runtime-diagnostics
fn diagnostics_service_name(container_name: &str, project_name: &str) -> String {
    if container_name == &format!("tillandsias-git-{project_name}") {
        return "git".to_string();
    }
    if let Some(rest) = container_name.strip_prefix(&format!("tillandsias-{project_name}-")) {
        return rest.to_string();
    }
    container_name.to_string()
}
