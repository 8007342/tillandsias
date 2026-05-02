// On Windows, we use "console" subsystem (the default) so CLI output works
// from any terminal. For tray-only mode (no args), the console window is
// hidden via FreeConsole() after startup.
// On non-Windows, the attribute is irrelevant.

mod accountability;
mod build_lock;
mod ca;
mod cleanup;
mod cli;
#[cfg(target_os = "linux")]
mod desktop;
mod desktop_env;
mod embedded;
mod event_loop;
mod github;
mod gpu;
mod handlers;
mod i18n;
mod init;
mod launch;
mod log_format;
mod logging;
mod menu;
mod runner;
mod secrets;
mod singleton;
mod strings;
mod tray_spawn;
mod uninstall;
mod update_cli;
mod update_log;
mod updater;

/// Chromium launcher for browser isolation.
#[cfg(target_os = "linux")]
mod chromium_launcher;

/// MCP server for browser window control (Unix only).
#[cfg(target_os = "linux")]
mod mcp_browser;

use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicU64, Ordering};

use tauri::tray::TrayIconBuilder;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use tillandsias_core::config::load_global_config;
use tillandsias_core::event::{BuildProgressEvent, MenuCommand};
use tillandsias_core::genus::TrayIconState;
use tillandsias_core::icons;
use tillandsias_core::state::{ContainerInfo, Os, PlatformInfo, TrayState};
use tillandsias_podman::{PodmanClient, PodmanEventStream, detect_gpu_devices};
use tillandsias_scanner::{Scanner, ScannerConfig};

use updater::UpdateState;

/// Global tray icon handle — needed for dynamic menu rebuilds.
/// Set once during setup, never replaced.
static TRAY_ICON: std::sync::OnceLock<Mutex<tauri::tray::TrayIcon>> = std::sync::OnceLock::new();

fn main() {
    // On Windows, hide the console window for tray-only mode (no args).
    // CLI mode keeps the console so output is visible in any terminal.
    #[cfg(target_os = "windows")]
    {
        if std::env::args().len() <= 1 {
            unsafe {
                windows_sys::Win32::System::Console::FreeConsole();
            }
        }
    }

    // Parse CLI arguments first — before any heavy initialization.
    let (cli_mode, log_config) = match cli::parse() {
        Some(parsed) => parsed,
        None => {
            // --help or --version was printed, exit cleanly
            std::process::exit(0);
        }
    };

    // Version mode — print version and exit.
    if matches!(cli_mode, cli::CliMode::Version) {
        println!("Tillandsias v{}", env!("TILLANDSIAS_FULL_VERSION"));
        std::process::exit(0);
    }

    // Init mode — pre-build images and exit.
    if let cli::CliMode::Init { force, debug: _ } = cli_mode {
        let success = init::run_with_force(force, false);
        std::process::exit(if success { 0 } else { 1 });
    }

    // Stats mode — print disk usage report and exit.
    if matches!(cli_mode, cli::CliMode::Stats) {
        let success = cleanup::run_stats();
        std::process::exit(if success { 0 } else { 1 });
    }

    // Clean mode — remove stale artifacts and exit.
    if matches!(cli_mode, cli::CliMode::Clean) {
        let success = cleanup::run_clean();
        std::process::exit(if success { 0 } else { 1 });
    }

    // Update mode — check for updates and apply if available, then exit.
    if matches!(cli_mode, cli::CliMode::Update) {
        let success = update_cli::run();
        std::process::exit(if success { 0 } else { 1 });
    }

    // Uninstall mode — remove Tillandsias from the system and exit.
    // @trace spec:app-lifecycle
    if let cli::CliMode::Uninstall { wipe } = cli_mode {
        std::process::exit(if crate::uninstall::run(wipe) { 0 } else { 1 });
    }

    // GitHub Login mode — run authentication flow interactively and exit.
    if matches!(cli_mode, cli::CliMode::GitHubLogin) {
        let _log_guard = logging::init(&log_config);
        let success = runner::run_github_login();
        std::process::exit(if success { 0 } else { 1 });
    }

    // Diagnostics mode — stream container logs and exit.
    // @trace spec:cli-diagnostics
    if let cli::CliMode::Diagnostics { path, debug } = cli_mode {
        let _log_guard = logging::init(&log_config);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let result = rt.block_on(async {
            handlers::handle_diagnostics(path.as_deref(), debug).await
        });
        std::process::exit(if result.is_ok() { 0 } else { 1 });
    }

    // If CLI attach mode, run the container runner and exit — no tray app.
    if let cli::CliMode::Attach {
        path,
        image,
        debug,
        bash,
        agent_override,
    } = cli_mode
    {
        // Initialize tracing for file logging (CLI output uses println!)
        let _log_guard = logging::init(&log_config);

        // @trace spec:cli-mode, spec:tray-cli-coexistence
        // When invoked from a graphical session, also bring up the tray icon
        // in a detached child process so the user has a tray to manage other
        // projects while the foreground attach runs (and after it exits).
        // Spawned BEFORE runner::run so the tray comes up while the CLI does
        // its enclave bring-up. Singleton guard in the child handles the
        // "tray already running" case silently.
        if desktop_env::has_graphical_session() {
            if let Err(e) = tray_spawn::spawn_detached_tray() {
                tracing::warn!(error = %e, "Tray spawn failed — CLI continues");
            } else {
                println!("  Tillandsias tray launched in background — open the menu for project actions.");
            }
        }

        let success = runner::run(path, &image, debug, bash, agent_override);
        std::process::exit(if success { 0 } else { 1 });
    }

    // --- Tray mode below ---

    // Initialize tracing — dual output (stderr if TTY + file appender) in all builds.
    // Hold the guard so the non-blocking file writer flushes on shutdown.
    let _log_guard = logging::init(&log_config);


    // AppImage desktop integration — install .desktop file and icons on first run.
    // Must happen after logging init (so we can trace) and before tray setup
    // (so the icon is available when GNOME processes the tray window).
    #[cfg(target_os = "linux")]
    desktop::ensure_desktop_integration();

    // Singleton guard — only one tray instance at a time.
    // If another instance is already running, exit silently.
    if singleton::try_acquire().is_err() {
        std::process::exit(0);
    }

    info!("Tillandsias starting");

    // @trace spec:secrets-management, spec:native-secrets-store, spec:podman-orchestration
    // Crash-recovery sweep. TerminateProcess / SIGKILL bypass Rust's Drop
    // guards, so a prior session that was force-killed can leave behind:
    //   (1) ephemeral token files in the tmpfs-tokens directory
    //   (2) running tillandsias-* containers with stale token-file mounts
    // The tokens themselves stay valid in the OS keyring; what we clean
    // here is everything that the dead session was supposed to tear down.
    // Both sweeps are idempotent and no-op if the prior session exited
    // cleanly.
    crate::secrets::cleanup_all_token_files();
    if let Ok(rt) = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        rt.block_on(handlers::sweep_orphan_containers());
    }

    // Detect platform
    let platform = PlatformInfo {
        os: Os::detect(),
        has_podman: false,
        has_podman_machine: false,
        gpu_devices: detect_gpu_devices()
            .iter()
            .map(|d| d.replace("--device=", ""))
            .collect(),
    };

    let initial_state = TrayState::new(platform);
    let state = Arc::new(Mutex::new(initial_state));

    // Channel for menu commands → event loop
    let (menu_tx, menu_rx) = mpsc::channel::<MenuCommand>(64);
    let (shutdown_tx, _shutdown_rx) = mpsc::channel::<()>(1);

    // Channel for browser window requests from MCP server → event loop
    // @trace spec:browser-mcp-server
    let (browser_tx, browser_rx) = mpsc::channel::<MenuCommand>(64);

    // Channel for build progress events (handlers → event loop)
    let (build_tx, build_rx) = mpsc::channel::<BuildProgressEvent>(64);

    let state_for_setup = state.clone();

    let update_state = UpdateState::default();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(update_state.clone())
        .setup(move |app| {
            let app_handle = app.handle().clone();

            // Register the global AppHandle used by the opencode-web webview
            // @tombstone superseded:browser-isolation-tray-integration
            // Old webview app handle setup — removed with browser isolation transition.
            // crate::webview::set_app_handle(app_handle.clone());

            // Spawn updater background tasks
            updater::spawn_update_tasks(&app_handle, update_state);

            // Build initial tray menu
            let tray_menu = {
                let s = state_for_setup.lock().unwrap();
                menu::build_tray_menu(&app_handle, &s)?
            };

            // Build tray icon — store handle so it persists and callbacks remain active
            // Icon bytes come from the SVG→PNG build pipeline (Ionantha pup = startup state)
            // @trace spec:tray-icon-lifecycle
            let icon = tauri::image::Image::from_bytes(icons::tray_icon_png(TrayIconState::Pup))
                .expect("embedded tray icon is valid PNG");

            let tray = TrayIconBuilder::new()
                .icon(icon)
                .tooltip("Tillandsias")
                .menu(&tray_menu)
                .on_menu_event({
                    let menu_tx = menu_tx.clone();
                    let app_handle = app_handle.clone();
                    let state_for_menu = state_for_setup.clone();
                    move |_app, event| {
                        let raw_id = event.id().as_ref();
                        let id = menu::ids::strip_gen(raw_id);
                        debug!(menu_id = %id, "Menu event received");

                        // Blooming → Mature: any menu interaction acknowledges
                        // the "something new" state and transitions to idle.
                        // @trace spec:tray-icon-lifecycle
                        {
                            let mut s = state_for_menu.lock().unwrap();
                            if s.tray_icon_state == TrayIconState::Blooming {
                                s.tray_icon_state = TrayIconState::Mature;
                                if let Some(tray_lock) = TRAY_ICON.get()
                                    && let Ok(tray) = tray_lock.lock()
                                {
                                    if let Ok(icon) = tauri::image::Image::from_bytes(
                                        icons::tray_icon_png(TrayIconState::Mature),
                                    ) {
                                        if let Err(e) = tray.set_icon(Some(icon)) {
                                            debug!(error = %e, "Tray icon update failed (cosmetic)");
                                        }
                                    }
                                }
                            }
                        }

                        // Quit fast-path — exit immediately, no channel round-trip
                        if id == menu::ids::QUIT {
                            info!("Quit requested");
                            singleton::release();
                            std::process::exit(0);
                        }

                        handle_menu_click(id, &menu_tx, &app_handle);
                    }
                })
                .build(app)?;

            // Store tray handle globally so it persists and can be used for menu rebuilds
            let _ = TRAY_ICON.set(Mutex::new(tray));

            // Spawn async runtime tasks
            let state_for_loop = state_for_setup.clone();
            let app_handle_for_loop = app_handle.clone();

            tauri::async_runtime::spawn(async move {
                // Check podman availability
                let client = PodmanClient::new();
                let has_podman = client.is_available().await;
                let mut has_machine = if Os::detect().needs_podman_machine() {
                    client.is_machine_running().await
                } else {
                    false
                };

                // On macOS/Windows, auto-init and auto-start podman machine
                if has_podman && Os::detect().needs_podman_machine() && !has_machine {
                    // Initialize machine if none exists (first-time setup)
                    if !client.has_machine().await {
                        info!("No podman machine found, initializing...");
                        if !client.init_machine().await {
                            // TODO: Remove fallback — make this a hard error
                            warn!(
                                accountability = true,
                                category = "runtime",
                                safety = "DEGRADED: podman machine init failed — container operations unavailable",
                                spec = "podman-machine",
                                "Podman machine init failed"
                            );
                        }
                    }
                    info!("Podman machine not running, starting automatically...");
                    if client.start_machine().await {
                        // Wait for the API socket to be ready before proceeding.
                        // On macOS, `podman machine start` returns before the socket
                        // is fully ready, causing subsequent commands to fail.
                        if client.wait_for_ready(5).await {
                            has_machine = true;
                        } else {
                            // TODO: Remove fallback — make this a hard error
                            warn!(
                                accountability = true,
                                category = "runtime",
                                safety = "DEGRADED: podman API not ready — container operations may fail",
                                spec = "podman-machine",
                                "Podman machine started but API not ready after retries"
                            );
                        }
                    } else {
                        // TODO: Remove fallback — make this a hard error
                        warn!(
                            accountability = true,
                            category = "runtime",
                            safety = "DEGRADED: podman machine not running — all container operations unavailable",
                            spec = "podman-machine",
                            "Podman machine auto-start failed — falling back to dried state"
                        );
                    }
                }

                // Podman is usable only if the binary exists AND, on macOS/Windows,
                // the podman machine is running. All podman operations gate on this.
                let podman_usable =
                    has_podman && (!Os::detect().needs_podman_machine() || has_machine);

                {
                    let mut s = state_for_loop.lock().unwrap();
                    s.platform.has_podman = has_podman;
                    s.platform.has_podman_machine = has_machine;
                    s.has_podman = podman_usable;
                    if !podman_usable {
                        s.tray_icon_state = TrayIconState::Dried;
                    }
                }

                if !has_podman {
                    warn!("Podman not found. Install podman to use Tillandsias.");
                } else if Os::detect().needs_podman_machine() && !has_machine {
                    warn!("Podman Machine not running. Start it with: podman machine start");
                }

                if !podman_usable {
                    // Set Dried icon immediately
                    if let Some(tray_lock) = TRAY_ICON.get()
                        && let Ok(tray) = tray_lock.lock()
                    {
                        if let Ok(icon) = tauri::image::Image::from_bytes(icons::tray_icon_png(
                            TrayIconState::Dried,
                        )) {
                            if let Err(e) = tray.set_icon(Some(icon)) {
                                debug!(error = %e, "Tray icon update failed (cosmetic)");
                            }
                        }
                    }
                    // Rebuild menu to show Dried state
                    rebuild_menu(&app_handle_for_loop, &state_for_loop);
                }

                // Discover existing containers on startup (graceful restart)
                //
                // Containers surviving a previous session are discovered here and
                // restored into state.running so the menu shows the correct flower
                // icons and lifecycle states immediately. Only running/creating
                // containers are restored — stopped/exited ones are ignored.
                if podman_usable {
                    match client.list_containers("tillandsias-").await {
                        Ok(containers) => {
                            let mut s = state_for_loop.lock().unwrap();
                            for entry in containers {
                                // Map podman state strings to ContainerState.
                                // Skip anything that is not actively running or starting.
                                let container_state = match entry.state.as_str() {
                                    "running" => tillandsias_core::event::ContainerState::Running,
                                    "created" | "configured" => {
                                        tillandsias_core::event::ContainerState::Creating
                                    }
                                    // exited, stopped, dead, removing, paused, unknown — skip.
                                    _ => continue,
                                };

                                // Container name encodes project + genus; skip if unparseable.
                                if let Some((project_name, genus)) =
                                    ContainerInfo::parse_container_name(&entry.name)
                                {
                                    s.running.push(ContainerInfo {
                                        name: entry.name,
                                        project_name,
                                        genus,
                                        state: container_state,
                                        port_range: (0, 0),
                                        container_type:
                                            tillandsias_core::state::ContainerType::Forge, // Default for discovered containers
                                        display_emoji: genus.flower().to_string(), // Default to flower for discovered containers
                                    });
                                }
                            }
                            info!(
                                count = s.running.len(),
                                "Restored running containers from prior session"
                            );
                        }
                        Err(e) => {
                            warn!(error = %e, "Failed to discover existing containers on startup");
                        }
                    }
                }

                // @trace spec:enclave-network, spec:proxy-container, spec:tray-app,
                // spec:git-mirror-service, spec:inference-container, spec:init-command
                //
                // Unified initialization — build ALL images like --init does.
                // Ensures the tray is fully ready on first launch without requiring
                // a separate `--init` run. Menus stay disabled until all images are
                // confirmed present (or built). Builds are sequential: proxy first
                // (foundation), then forge, git, inference.
                //
                // Image types and their user-facing chip names:
                const INIT_IMAGE_TYPES: &[(&str, &str, fn() -> String)] = &[
                    ("proxy",     "Enclave",          handlers::proxy_image_tag),
                    ("forge",     "Forge",            handlers::forge_image_tag),
                    ("git",       "Code Mirror",      handlers::git_image_tag),
                    ("inference", "Inference Engine",  handlers::inference_image_tag),
                ];

                if podman_usable {
                    // Step 1: Ensure the enclave network exists (needed before any
                    // container or image build that routes through the proxy).
                    info!("Ensuring enclave network exists (required for all operations)");
                    if let Err(e) = handlers::ensure_enclave_network_pub().await {
                        warn!(error = %e, "Enclave network creation failed — builds may bypass proxy cache");
                    }

                    // Step 2: Check which images are missing.
                    let check_client = tillandsias_podman::PodmanClient::new();
                    let mut needs_build = Vec::new();

                    for &(image_name, chip_name, tag_fn) in INIT_IMAGE_TYPES {
                        let tag = tag_fn();

                        // Retry image_exists check — defense-in-depth against transient
                        // socket failures after machine start on macOS.
                        let mut present = false;
                        for attempt in 0..3u32 {
                            if check_client.image_exists(&tag).await {
                                present = true;
                                break;
                            }
                            if attempt < 2 {
                                debug!(attempt, tag = %tag, "image_exists returned false, retrying...");
                                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                            }
                        }

                        if present {
                            info!(tag = %tag, image = image_name, "Image present at launch");
                        } else {
                            info!(tag = %tag, image = image_name, "Image absent at launch — queued for build");
                            needs_build.push((image_name, chip_name, tag));
                        }
                    }

                    if needs_build.is_empty() {
                        // All images already present — go straight to ready state.
                        info!("All images present at launch — skipping builds");

                        // @tombstone obsolete:layered-tools-overlay
                        // Tools overlay build removed — agents are now baked into the forge image.
                        // Safe to delete after v0.1.163.
                        // Previously: Build tools overlay with hard failure if missing.
                        // Now: Agents are in the image, so just mark forge as available.
                        {
                            let mut s = state_for_loop.lock().unwrap();
                            s.forge_available = true;
                            s.tray_icon_state = TrayIconState::Mature;
                        }
                        if let Some(tray_lock) = TRAY_ICON.get()
                            && let Ok(tray) = tray_lock.lock()
                        {
                            if let Ok(icon) = tauri::image::Image::from_bytes(icons::tray_icon_png(
                                TrayIconState::Mature,
                            )) {
                                if let Err(e) = tray.set_icon(Some(icon)) {
                                    debug!(error = %e, "Tray icon update failed (cosmetic)");
                                }
                            }
                        }
                        rebuild_menu(&app_handle_for_loop, &state_for_loop);
                    }

                    if !needs_build.is_empty() {
                        // Step 3: Build missing images sequentially with per-component chips.
                        // Set icon to Building and keep forge_available = false.
                        {
                            let mut s = state_for_loop.lock().unwrap();
                            s.tray_icon_state = TrayIconState::Building;
                        }
                        if let Some(tray_lock) = TRAY_ICON.get()
                            && let Ok(tray) = tray_lock.lock()
                        {
                            if let Ok(icon) = tauri::image::Image::from_bytes(icons::tray_icon_png(
                                TrayIconState::Building,
                            )) {
                                if let Err(e) = tray.set_icon(Some(icon)) {
                                    debug!(error = %e, "Tray icon update failed (cosmetic)");
                                }
                            }
                        }
                        rebuild_menu(&app_handle_for_loop, &state_for_loop);

                        let mut proxy_ok = true;  // assume ok unless proxy is in needs_build and fails
                        let mut forge_ok = true;   // assume ok unless forge is in needs_build and fails

                        for (image_name, chip_name, tag) in &needs_build {
                            let chip_label = chip_name.to_string();

                            // Show "Building {name}..." chip
                            {
                                let mut s = state_for_loop.lock().unwrap();
                                s.active_builds
                                    .push(tillandsias_core::state::BuildProgress {
                                        image_name: chip_label.clone(),
                                        status: tillandsias_core::state::BuildStatus::InProgress,
                                        started_at: std::time::Instant::now(),
                                        completed_at: None,
                                    });
                            }
                            if build_tx.try_send(BuildProgressEvent::Started {
                                image_name: chip_label.clone(),
                            }).is_err() {
                                debug!("Build progress channel full/closed — UI may show stale state");
                            }
                            rebuild_menu(&app_handle_for_loop, &state_for_loop);

                            info!(image = *image_name, tag = %tag, "Building image at launch");

                            // Build image (blocking — podman build is synchronous)
                            let build_name = image_name.to_string();
                            let build_result = tokio::task::spawn_blocking(move || {
                                handlers::run_build_image_script_pub(&build_name)
                            })
                            .await;

                            match build_result {
                                Ok(Ok(())) => {
                                    info!(image = *image_name, tag = %tag, "Image built at launch");
                                    // Mark chip as completed
                                    {
                                        let mut s = state_for_loop.lock().unwrap();
                                        if let Some(entry) = s.active_builds
                                            .iter_mut()
                                            .find(|b| b.image_name == chip_label)
                                        {
                                            entry.status = tillandsias_core::state::BuildStatus::Completed;
                                            entry.completed_at = Some(std::time::Instant::now());
                                        }
                                    }
                                    if build_tx.try_send(BuildProgressEvent::Completed {
                                        image_name: chip_label,
                                    }).is_err() {
                                        debug!("Build progress channel full/closed — UI may show stale state");
                                    }
                                    rebuild_menu(&app_handle_for_loop, &state_for_loop);
                                }
                                Ok(Err(ref e)) => {
                                    warn!(image = *image_name, error = %e, "Image build failed at launch");
                                    if *image_name == "proxy" { proxy_ok = false; }
                                    if *image_name == "forge" { forge_ok = false; }
                                    {
                                        let mut s = state_for_loop.lock().unwrap();
                                        if let Some(entry) = s.active_builds
                                            .iter_mut()
                                            .find(|b| b.image_name == chip_label)
                                        {
                                            entry.status = tillandsias_core::state::BuildStatus::Failed(e.clone());
                                            entry.completed_at = Some(std::time::Instant::now());
                                        }
                                    }
                                    if build_tx.try_send(BuildProgressEvent::Failed {
                                        image_name: chip_label,
                                        reason: e.clone(),
                                    }).is_err() {
                                        debug!("Build progress channel full/closed — UI may show stale state");
                                    }
                                    rebuild_menu(&app_handle_for_loop, &state_for_loop);
                                    // Continue building remaining images — don't abort all
                                }
                                Err(ref e) => {
                                    warn!(image = *image_name, error = %e, "Image build task panicked at launch");
                                    if *image_name == "proxy" { proxy_ok = false; }
                                    if *image_name == "forge" { forge_ok = false; }
                                    let reason = format!("Build task panicked: {e}");
                                    {
                                        let mut s = state_for_loop.lock().unwrap();
                                        if let Some(entry) = s.active_builds
                                            .iter_mut()
                                            .find(|b| b.image_name == chip_label)
                                        {
                                            entry.status = tillandsias_core::state::BuildStatus::Failed(reason.clone());
                                            entry.completed_at = Some(std::time::Instant::now());
                                        }
                                    }
                                    if build_tx.try_send(BuildProgressEvent::Failed {
                                        image_name: chip_label,
                                        reason,
                                    }).is_err() {
                                        debug!("Build progress channel full/closed — UI may show stale state");
                                    }
                                    rebuild_menu(&app_handle_for_loop, &state_for_loop);
                                }
                            }
                        }

                        // Step 4: Build tools overlay now that forge image is ready.
                        // Hard failure — no per-container fallback. Overlay
                        // @tombstone obsolete:layered-tools-overlay
                        // Tools overlay check removed — agents are now baked into the forge image.
                        // Safe to delete after v0.1.163.
                        // Previously: Built tools overlay only if proxy + forge OK.

                        // Step 5: Set forge_available if proxy + forge built.
                        // forge_available gates menu items.
                        if proxy_ok && forge_ok {
                            {
                                let mut s = state_for_loop.lock().unwrap();
                                s.forge_available = true;
                                s.tray_icon_state = TrayIconState::Mature;
                            }
                            if let Some(tray_lock) = TRAY_ICON.get()
                                && let Ok(tray) = tray_lock.lock()
                            {
                                if let Ok(icon) = tauri::image::Image::from_bytes(icons::tray_icon_png(
                                    TrayIconState::Mature,
                                )) {
                                    if let Err(e) = tray.set_icon(Some(icon)) {
                                        debug!(error = %e, "Tray icon update failed (cosmetic)");
                                    }
                                }
                            }
                            // @trace spec:tray-app
                            // Desktop notification so the user knows the system is ready,
                            // even if they're not watching the tray menu.
                            handlers::send_notification(
                                "Tillandsias",
                                i18n::t("notifications.forge_ready"),
                            );
                        } else {
                            warn!(
                                proxy_ok,
                                forge_ok,
                                "Setup incomplete (images) — menus remain disabled"
                            );
                            {
                                let mut s = state_for_loop.lock().unwrap();
                                s.tray_icon_state = TrayIconState::Dried;
                            }
                            if let Some(tray_lock) = TRAY_ICON.get()
                                && let Ok(tray) = tray_lock.lock()
                            {
                                if let Ok(icon) = tauri::image::Image::from_bytes(icons::tray_icon_png(
                                    TrayIconState::Dried,
                                )) {
                                    if let Err(e) = tray.set_icon(Some(icon)) {
                                        debug!(error = %e, "Tray icon update failed (cosmetic)");
                                    }
                                }
                            }
                            handlers::send_notification(
                                "Tillandsias",
                                i18n::t("notifications.infrastructure_failed"),
                            );
                        }
                        rebuild_menu(&app_handle_for_loop, &state_for_loop);
                    }
                }

                // Set up scanner
                let global_config = load_global_config();
                let scanner_config = ScannerConfig::from_core_config(&global_config.scanner);
                let mut scanner = Scanner::new(scanner_config);

                // Initial scan
                let initial_changes = scanner.initial_scan();
                {
                    let mut s = state_for_loop.lock().unwrap();
                    for change in initial_changes {
                        if let tillandsias_core::project::ProjectChange::Discovered(project) =
                            change
                            && !s.projects.iter().any(|p| p.path == project.path)
                        {
                            s.projects.push(project);
                        }
                    }
                    info!(count = s.projects.len(), "Initial project scan complete");
                }

                // Rebuild menu after initial scan
                rebuild_menu(&app_handle_for_loop, &state_for_loop);

                // Start scanner watcher
                let (scanner_tx, scanner_rx) = mpsc::channel(256);
                let _scanner_task = tauri::async_runtime::spawn(async move {
                    if let Err(e) = scanner.watch(scanner_tx).await {
                        error!(error = ?e, "Scanner watcher failed");
                    }
                });

                // Start podman event stream
                let (podman_tx, podman_rx) = mpsc::channel(256);
                if podman_usable {
                    let podman_event_stream = PodmanEventStream::new("tillandsias-");
                    let _podman_task = tauri::async_runtime::spawn(async move {
                        podman_event_stream.stream(podman_tx).await;
                    });
                } else {
                    info!(
                        "Podman events stream skipped (podman unavailable or machine not running)"
                    );
                }

                // Start Unix socket listener for MCP browser server
                // @trace spec:browser-mcp-server
                #[cfg(target_os = "linux")]
                {
                    let browser_tx_clone = browser_tx.clone();
                    let _socket_task = tauri::async_runtime::spawn(async move {
                        if let Err(e) = listen_browser_socket(browser_tx_clone).await {
                            error!(error = %e, "Browser socket listener failed");
                        }
                    });
                }

                // Run main event loop
                let loop_state = { state_for_loop.lock().unwrap().clone() };

                let state_for_rebuild = state_for_loop.clone();
                let app_for_rebuild = app_handle_for_loop.clone();

                let on_state_change: event_loop::MenuRebuildFn =
                    Box::new(move |new_state: &TrayState| {
                        // Compute new icon state before acquiring the lock
                        let new_icon_state = new_state.compute_icon_state();

                        // Update shared state and detect icon transition
                        let old_icon_state = {
                            let mut s = state_for_rebuild.lock().unwrap();
                            let old = s.tray_icon_state;
                            s.projects.clone_from(&new_state.projects);
                            s.running.clone_from(&new_state.running);
                            s.has_podman = new_state.has_podman;
                            s.tray_icon_state = new_icon_state;
                            s.remote_repos.clone_from(&new_state.remote_repos);
                            s.remote_repos_fetched_at = new_state.remote_repos_fetched_at;
                            s.remote_repos_loading = new_state.remote_repos_loading;
                            s.cloning_project.clone_from(&new_state.cloning_project);
                            s.remote_repos_error
                                .clone_from(&new_state.remote_repos_error);
                            s.active_builds.clone_from(&new_state.active_builds);
                            s.forge_available = new_state.forge_available;
                            old
                        };

                        // Update tray icon if state changed
                        if new_icon_state != old_icon_state {
                            if let Some(tray_lock) = TRAY_ICON.get()
                                && let Ok(tray) = tray_lock.lock()
                            {
                                match tauri::image::Image::from_bytes(icons::tray_icon_png(
                                    new_icon_state,
                                )) {
                                    Ok(icon) => {
                                        if let Err(e) = tray.set_icon(Some(icon)) {
                                            debug!(error = %e, "Tray icon update failed (cosmetic)");
                                        }
                                        debug!(
                                            old = ?old_icon_state,
                                            new = ?new_icon_state,
                                            "Tray icon updated"
                                        );
                                    }
                                    Err(e) => {
                                        error!(error = %e, "Failed to build tray icon image");
                                    }
                                }
                            }
                        }

                        // Rebuild tray menu
                        rebuild_menu(&app_for_rebuild, &state_for_rebuild);
                    });

                event_loop::run(
                    loop_state,
                    scanner_rx,
                    podman_rx,
                    menu_rx,
                    browser_rx,
                    build_rx,
                    build_tx,
                    on_state_change,
                )
                .await;
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tillandsias")
        .run(move |_app, event| {
            // @trace spec:opencode-web-session, spec:app-lifecycle
            // Closing a webview window must not exit the tray. Tauri's default
            // behaviour treats the last closed window as "app done", but our
            // tray icon is not a window. Filter `web-*` close events early so
            // they never propagate to RunEvent::ExitRequested.
            if let tauri::RunEvent::WindowEvent {
                label,
                event: tauri::WindowEvent::CloseRequested { .. },
                ..
            } = &event
            {
                if label.starts_with("web-") {
                    tracing::debug!(
                        spec = "opencode-web-session",
                        label = %label,
                        "webview close intercepted — tray remains"
                    );
                    return;
                }
            }

            if let tauri::RunEvent::ExitRequested { .. } = event {
                info!("Exit requested");

                // @trace spec:proxy-container, spec:enclave-network
                // Stop the proxy container and remove the enclave network on exit.
                // Uses a blocking runtime since we are in the sync RunEvent handler.
                if let Ok(rt) = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    rt.block_on(async {
                        handlers::stop_inference().await;
                        handlers::stop_proxy().await;
                        handlers::cleanup_enclave_network().await;
                    });
                }

                singleton::release();
                let _ = shutdown_tx.blocking_send(());
            }
        });
}

/// Fingerprint of the last menu rebuild — avoids redundant `set_menu` calls
/// that can steal window focus on Windows and AppImage.
static LAST_MENU_FINGERPRINT: AtomicU64 = AtomicU64::new(0);

/// Compute a cheap fingerprint of menu-relevant state.
/// Only structural changes (project count, running count, build chips, forge status)
/// warrant a full menu rebuild.
fn menu_fingerprint(s: &TrayState) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    // Include i18n generation so language changes force a rebuild
    i18n::generation().hash(&mut h);
    s.projects.len().hash(&mut h);
    s.running.len().hash(&mut h);
    s.active_builds.len().hash(&mut h);
    s.forge_available.hash(&mut h);
    s.has_podman.hash(&mut h);
    s.tray_icon_state.hash(&mut h);
    s.remote_repos_loading.hash(&mut h);
    s.cloning_project.hash(&mut h);
    // Hash project names to detect additions/removals
    for p in &s.projects {
        p.name.hash(&mut h);
    }
    // Hash running container names
    for r in &s.running {
        r.name.hash(&mut h);
    }
    // Hash build chip names + status
    for b in &s.active_builds {
        b.image_name.hash(&mut h);
        std::mem::discriminant(&b.status).hash(&mut h);
    }
    h.finish()
}

/// Rebuild the tray menu from current state and apply it to the tray icon.
/// Skips the rebuild if the menu-relevant state hasn't changed, avoiding
/// focus-stealing on Windows and AppImage.
fn rebuild_menu(app_handle: &tauri::AppHandle, state: &Arc<Mutex<TrayState>>) {
    let s = state.lock().unwrap();

    // Skip rebuild if menu content hasn't changed
    let fp = menu_fingerprint(&s);
    let prev = LAST_MENU_FINGERPRINT.swap(fp, Ordering::Relaxed);
    if fp == prev {
        return;
    }

    match menu::build_tray_menu(app_handle, &s) {
        Ok(new_menu) => {
            if let Some(tray_lock) = TRAY_ICON.get()
                && let Ok(tray) = tray_lock.lock()
            {
                if let Err(e) = tray.set_menu(Some(new_menu)) {
                    debug!(error = %e, "Tray menu update failed (cosmetic)");
                }
                debug!(
                    projects = s.projects.len(),
                    running = s.running.len(),
                    "Tray menu rebuilt"
                );
            }
        }
        Err(e) => {
            error!(error = %e, "Failed to rebuild tray menu");
        }
    }
}

/// Dispatch a menu click ID to the appropriate `MenuCommand`.
fn handle_menu_click(id: &str, tx: &mpsc::Sender<MenuCommand>, _app: &tauri::AppHandle) {
    // Strip the generation suffix (e.g., "quit#5" -> "quit") added to avoid
    // libappindicator's menu ID caching bug that causes blank labels.
    let id = menu::ids::strip_gen(id);

    let command = match id {
        menu::ids::QUIT => None, // Handled via fast-path above
        menu::ids::GITHUB_LOGIN => Some(MenuCommand::GitHubLogin),
        menu::ids::CLAUDE_RESET_CREDENTIALS => Some(MenuCommand::ClaudeResetCredentials),
        menu::ids::SETTINGS => Some(MenuCommand::Settings),
        menu::ids::REFRESH_REMOTE_PROJECTS => Some(MenuCommand::RefreshRemoteProjects),
        "root-terminal" => Some(MenuCommand::RootTerminal),
        _ => {
            if let Some((action, payload)) = menu::ids::parse(id) {
                match action {
                    "attach" => Some(MenuCommand::AttachHere {
                        project_path: payload.into(),
                    }),
                    // New explicit action buttons for projects
                    // @trace spec:tray-minimal-ux
                    "opencode" => Some(MenuCommand::OpenCodeProject {
                        project_path: payload.into(),
                    }),
                    // @trace spec:browser-isolation-tray-integration
                    "opencode-web" => Some(MenuCommand::OpenCodeWebProject {
                        project_path: payload.into(),
                    }),
                    // @trace spec:tray-minimal-ux
                    "claude" => Some(MenuCommand::ClaudeProject {
                        project_path: payload.into(),
                    }),
                    // @trace spec:tray-minimal-ux
                    "maintenance" => Some(MenuCommand::MaintenanceProject {
                        project_path: payload.into(),
                    }),
                    "terminal" => Some(MenuCommand::Terminal {
                        project_path: payload.into(),
                    }),
                    "serve" => Some(MenuCommand::ServeHere {
                        project_path: payload.into(),
                    }),
                    // "start" ID no longer emitted from menu but kept
                    // for safety in case external callers use it.
                    "start" => Some(MenuCommand::Start {
                        project_path: payload.into(),
                    }),
                    "stop" => {
                        if let Some((_, genus)) = ContainerInfo::parse_container_name(payload) {
                            Some(MenuCommand::Stop {
                                container_name: payload.to_string(),
                                genus,
                            })
                        } else {
                            warn!(id, "Cannot parse container name from stop action");
                            None
                        }
                    }
                    // @trace spec:opencode-web-session, spec:tray-app
                    "stop-project" => Some(MenuCommand::StopProject {
                        project_path: payload.into(),
                    }),
                    "destroy" => {
                        if let Some((_, genus)) = ContainerInfo::parse_container_name(payload) {
                            Some(MenuCommand::Destroy {
                                container_name: payload.to_string(),
                                genus,
                            })
                        } else {
                            warn!(id, "Cannot parse container name from destroy action");
                            None
                        }
                    }
                    "clone" => {
                        // Payload format: "<full_name>\t<name>"
                        if let Some((full_name, name)) = payload.split_once('\t') {
                            Some(MenuCommand::CloneProject {
                                full_name: full_name.to_string(),
                                name: name.to_string(),
                            })
                        } else {
                            warn!(id, "Cannot parse clone project from menu ID");
                            None
                        }
                    }
                    "select-agent" => Some(MenuCommand::SelectAgent {
                        agent: payload.to_string(),
                    }),
                    "select-lang" => Some(MenuCommand::SelectLanguage {
                        language: payload.to_string(),
                    }),
                    _ => {
                        debug!(action, "Unknown menu action");
                        None
                    }
                }
            } else {
                None
            }
        }
    };

    if let Some(cmd) = command {
        if tx.try_send(cmd).is_err() {
            debug!("Menu command channel full/closed — action may be dropped");
        }
    }
}

/// Listen on Unix socket for browser window requests from MCP server.
///
/// The MCP server (running in forge containers) connects to this socket
/// and sends JSON-RPC requests to open browser windows.
///
/// @trace spec:browser-mcp-server
#[cfg(target_os = "linux")]
async fn listen_browser_socket(tx: mpsc::Sender<MenuCommand>) -> Result<(), String> {
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::io::{BufRead, BufReader};
    use std::path::Path;

    let socket_path = "/run/tillandsias/tray.sock";

    // Remove stale socket if it exists
    if Path::new(socket_path).exists() {
        std::fs::remove_file(socket_path)
            .map_err(|e| format!("Failed to remove stale socket: {}", e))?;
    }

    let listener = UnixListener::bind(socket_path)
        .map_err(|e| format!("Failed to bind Unix socket '{}': {}", socket_path, e))?;

    // Set permissions so forge containers can connect
    std::fs::set_permissions(socket_path, std::os::unix::fs::PermissionsExt::from_mode(0o666))
        .map_err(|e| format!("Failed to set socket permissions: {}", e))?;

    info!(
        spec = "browser-mcp-server",
        socket = socket_path,
        "Browser socket listener started"
    );

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let tx = tx.clone();
                tauri::async_runtime::spawn(async move {
                    if let Err(e) = handle_browser_socket_connection(stream, tx).await {
                        debug!(error = %e, "Browser socket connection failed");
                    }
                });
            }
            Err(e) => {
                error!(error = %e, "Browser socket accept failed");
            }
        }
    }

    Ok(())
}

/// Handle a single browser socket connection from MCP server.
#[cfg(target_os = "linux")]
async fn handle_browser_socket_connection(
    stream: std::os::unix::net::UnixStream,
    tx: mpsc::Sender<MenuCommand>,
) -> Result<(), String> {
    use std::io::{BufRead, BufReader};

    let reader = BufReader::new(&stream);
    let mut lines = reader.lines();

    while let Some(line_result) = lines.next() {
        let line = line_result.map_err(|e| e.to_string())?;
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        match serde_json::from_str::<serde_json::Value>(&line) {
            Ok(request) => {
                let method = request.get("method").and_then(|m| m.as_str());
                let params = request.get("params");

                match method {
                    Some("open_browser_window") => {
                        if let Some(params) = params {
                            let project = params.get("project").and_then(|p| p.as_str());
                            let url = params.get("url").and_then(|u| u.as_str());
                            let window_type = params.get("window_type").and_then(|w| w.as_str());

                            if let (Some(project), Some(url), Some(window_type)) = (project, url, window_type) {
                                let cmd = MenuCommand::OpenBrowserWindow {
                                    project: project.to_string(),
                                    url: url.to_string(),
                                    window_type: window_type.to_string(),
                                };
                                if tx.send(cmd).await.is_err() {
                                    error!("Browser command channel closed");
                                    break;
                                }
                            }
                        }
                    }
                    _ => {
                        debug!(method = ?method, "Unknown browser socket method");
                    }
                }
            }
            Err(e) => {
                debug!(error = %e, "Failed to parse browser socket request");
            }
        }
    }

    Ok(())
}
