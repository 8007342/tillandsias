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
mod github_health;
mod gpu;
mod handlers;
mod i18n;
mod init;
mod launch;
mod log_format;
mod mirror_sync;
mod logging;
mod menu;
mod runner;
mod tray_menu;
mod secrets;
mod singleton;
mod strings;
// Tools-overlay module tombstoned 2026-04-25 — agent binaries (claude,
// openspec, opencode) are now hard-installed in the forge image at
// /usr/local/bin/. See openspec/changes/archive/2026-04-25-tombstone-tools-overlay/.
mod tray_spawn;
mod uninstall;
mod update_cli;
mod update_log;
mod updater;
mod browser;

use std::sync::{Arc, Mutex};

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

/// Global pre-built tray menu. Stage transitions and projects-submenu
/// rebuilds drive this handle directly. Set once during setup.
///
/// @trace spec:simplified-tray-ux
static TRAY_MENU: std::sync::OnceLock<tray_menu::TrayMenu<tauri::Wry>> =
    std::sync::OnceLock::new();

/// Latest credential probe result. Cached for the process lifetime; only
/// re-runs on user-initiated sign-in / sign-out actions per the spec.
///
/// @trace spec:simplified-tray-ux
static CREDENTIAL_HEALTH: std::sync::OnceLock<
    Mutex<Option<crate::github_health::CredentialHealth>>,
> = std::sync::OnceLock::new();

/// Shared TrayState handle, used by background tasks (credential probe,
/// menu rebuilds from outside the event loop) without threading Arcs
/// through every signature.
///
/// @trace spec:simplified-tray-ux
static TRAY_STATE_HANDLE: std::sync::OnceLock<Arc<Mutex<TrayState>>> = std::sync::OnceLock::new();

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
    if let cli::CliMode::Init { force } = cli_mode {
        let success = init::run_with_force(force);
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
        // @trace spec:simplified-tray-ux
        // Pre-UI sweep: removes orphaned tillandsias-* containers
        // (running OR stopped) and force-removes the enclave network
        // before the event loop accepts user input.
        rt.block_on(handlers::pre_ui_cleanup_stale_containers());
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
    // @trace spec:simplified-tray-ux
    // Make the shared state accessible to background tasks without
    // threading Arcs through every event_loop signature.
    let _ = TRAY_STATE_HANDLE.set(state.clone());

    // Channel for menu commands → event loop
    let (menu_tx, menu_rx) = mpsc::channel::<MenuCommand>(64);
    let (shutdown_tx, _shutdown_rx) = mpsc::channel::<()>(1);

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

            // @trace spec:opencode-web-session
            // OpenCode Web sessions now launch in the user's native browser
            // (see src-tauri/src/browser.rs). Tauri no longer hosts a
            // WebviewWindow for them — no AppHandle registration needed.

            // Spawn updater background tasks
            updater::spawn_update_tasks(&app_handle, update_state);

            // @trace spec:simplified-tray-ux
            // Pre-build the static tray menu once. Stage transitions toggle
            // set_enabled on individual handles instead of rebuilding the
            // tree (the legacy `menu::build_tray_menu` path is gone).
            let tm = tray_menu::TrayMenu::<tauri::Wry>::new(&app_handle)?;
            let menu_root = tm.root.clone();
            // Store the pre-built menu globally so the event loop can drive it.
            // Subsequent .new() calls would conflict; OnceLock prevents that.
            if TRAY_MENU.set(tm).is_err() {
                warn!("TRAY_MENU already initialised — duplicate setup?");
            }

            // Build tray icon — store handle so it persists and callbacks remain active
            // Icon bytes come from the SVG→PNG build pipeline (Ionantha pup = startup state)
            // @trace spec:tray-icon-lifecycle
            let icon = tauri::image::Image::from_bytes(icons::tray_icon_png(TrayIconState::Pup))
                .expect("embedded tray icon is valid PNG");

            let tray = TrayIconBuilder::new()
                .icon(icon)
                .tooltip("Tillandsias")
                .menu(&menu_root)
                .on_menu_event({
                    let menu_tx = menu_tx.clone();
                    let state_for_menu = state_for_setup.clone();
                    move |_app, event| {
                        // @trace spec:simplified-tray-ux
                        // Stable IDs, no generation suffix. The new TrayMenu
                        // reuses item handles forever, so libappindicator's
                        // blank-label cache bug does not apply.
                        let id = event.id().as_ref();
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
                                    && let Ok(icon) = tauri::image::Image::from_bytes(
                                        icons::tray_icon_png(TrayIconState::Mature),
                                    )
                                        && let Err(e) = tray.set_icon(Some(icon)) {
                                            debug!(error = %e, "Tray icon update failed (cosmetic)");
                                        }
                            }
                        }

                        // @trace spec:app-lifecycle
                        // Quit is dispatched through the menu channel so the event loop
                        // owns the sole shutdown_all() invocation.
                        if id == tray_menu::ids::QUIT {
                            info!("Quit requested");
                            if let Err(e) = menu_tx.blocking_send(MenuCommand::Quit) {
                                warn!(error = %e, "menu channel closed — falling back to direct exit");
                                singleton::release();
                                std::process::exit(0);
                            }
                            return;
                        }

                        // Include-remote toggle: read the CheckMenuItem state
                        // and forward the resolved value to the event loop so
                        // it can rebuild the projects submenu accordingly.
                        if id == tray_menu::ids::INCLUDE_REMOTE {
                            if let Some(menu) = TRAY_MENU.get() {
                                let include = menu.include_remote_checked();
                                if let Err(e) = menu_tx.try_send(MenuCommand::IncludeRemoteToggle { include }) {
                                    debug!(error = %e, "include-remote toggle dispatch failed");
                                }
                            }
                            return;
                        }

                        handle_menu_click(id, &menu_tx);
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
                        && let Ok(icon) = tauri::image::Image::from_bytes(icons::tray_icon_png(
                            TrayIconState::Dried,
                        ))
                            && let Err(e) = tray.set_icon(Some(icon)) {
                                debug!(error = %e, "Tray icon update failed (cosmetic)");
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

                        // @trace spec:tombstone-tools-overlay
                        // Tools overlay tombstoned — agents are hard-installed in
                        // the forge image at /usr/local/bin/ (see Containerfile).
                        // Forge is available as soon as its image is present.
                        let overlay_ok = true;

                        if overlay_ok {
                            {
                                let mut s = state_for_loop.lock().unwrap();
                                s.forge_available = true;
                                s.tray_icon_state = TrayIconState::Mature;
                            }
                            if let Some(tray_lock) = TRAY_ICON.get()
                                && let Ok(tray) = tray_lock.lock()
                                && let Ok(icon) = tauri::image::Image::from_bytes(icons::tray_icon_png(
                                    TrayIconState::Mature,
                                ))
                                    && let Err(e) = tray.set_icon(Some(icon)) {
                                        debug!(error = %e, "Tray icon update failed (cosmetic)");
                                    }
                        } else {
                            {
                                let mut s = state_for_loop.lock().unwrap();
                                s.tray_icon_state = TrayIconState::Dried;
                            }
                            if let Some(tray_lock) = TRAY_ICON.get()
                                && let Ok(tray) = tray_lock.lock()
                                && let Ok(icon) = tauri::image::Image::from_bytes(icons::tray_icon_png(
                                    TrayIconState::Dried,
                                ))
                                    && let Err(e) = tray.set_icon(Some(icon)) {
                                        debug!(error = %e, "Tray icon update failed (cosmetic)");
                                    }
                            handlers::send_notification(
                                "Tillandsias",
                                i18n::t("notifications.infrastructure_failed"),
                            );
                        }
                        rebuild_menu(&app_handle_for_loop, &state_for_loop);
                        // @trace spec:simplified-tray-ux
                        // All images already present — fire credential probe so we
                        // can transition Ready → Authed/NoAuth/NetIssue.
                        spawn_credential_probe(app_handle_for_loop.clone(), state_for_loop.clone());
                    } else {
                        // Step 3: Build missing images sequentially with per-component chips.
                        // Set icon to Building and keep forge_available = false.
                        {
                            let mut s = state_for_loop.lock().unwrap();
                            s.tray_icon_state = TrayIconState::Building;
                        }
                        if let Some(tray_lock) = TRAY_ICON.get()
                            && let Ok(tray) = tray_lock.lock()
                            && let Ok(icon) = tauri::image::Image::from_bytes(icons::tray_icon_png(
                                TrayIconState::Building,
                            ))
                                && let Err(e) = tray.set_icon(Some(icon)) {
                                    debug!(error = %e, "Tray icon update failed (cosmetic)");
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

                        // Step 4 tombstoned: tools overlay removed — agents are
                        // hard-installed in the forge image (/usr/local/bin/).
                        // @trace spec:tombstone-tools-overlay

                        // Step 5: Set forge_available only if proxy + forge built.
                        // forge_available gates menu items.
                        if proxy_ok && forge_ok {
                            {
                                let mut s = state_for_loop.lock().unwrap();
                                s.forge_available = true;
                                s.tray_icon_state = TrayIconState::Mature;
                            }
                            if let Some(tray_lock) = TRAY_ICON.get()
                                && let Ok(tray) = tray_lock.lock()
                                && let Ok(icon) = tauri::image::Image::from_bytes(icons::tray_icon_png(
                                    TrayIconState::Mature,
                                ))
                                    && let Err(e) = tray.set_icon(Some(icon)) {
                                        debug!(error = %e, "Tray icon update failed (cosmetic)");
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
                                "Setup incomplete — menus remain disabled"
                            );
                            {
                                let mut s = state_for_loop.lock().unwrap();
                                s.tray_icon_state = TrayIconState::Dried;
                            }
                            if let Some(tray_lock) = TRAY_ICON.get()
                                && let Ok(tray) = tray_lock.lock()
                                && let Ok(icon) = tauri::image::Image::from_bytes(icons::tray_icon_png(
                                    TrayIconState::Dried,
                                ))
                                    && let Err(e) = tray.set_icon(Some(icon)) {
                                        debug!(error = %e, "Tray icon update failed (cosmetic)");
                                    }
                            handlers::send_notification(
                                "Tillandsias",
                                i18n::t("notifications.infrastructure_failed"),
                            );
                        }
                        rebuild_menu(&app_handle_for_loop, &state_for_loop);
                        // @trace spec:simplified-tray-ux
                        // Builds finished (success or partial failure). Fire the
                        // credential probe so the tray transitions out of Ready.
                        if proxy_ok && forge_ok {
                            spawn_credential_probe(
                                app_handle_for_loop.clone(),
                                state_for_loop.clone(),
                            );
                        }
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

                // @trace spec:git-mirror-service
                // Startup mirror -> host sync: catch up any stranded commits
                // from a previous session (e.g. tray crash between mirror
                // receiving a push and the host working copy learning about
                // it). Fast-forward only, skips dirty / diverged / detached
                // hosts; see `src-tauri/src/mirror_sync.rs`.
                //
                // After the startup sweep, arm a filesystem watcher on the
                // mirrors root. Every subsequent ref update in any project's
                // mirror (from forge post-receive, startup retry-push, or
                // manual push) triggers an event-driven sync for just that
                // project. No polling; driven by inotify / FSEvents.
                {
                    let cfg = tillandsias_core::config::load_global_config();
                    let mirrors_root = tillandsias_core::config::cache_dir().join("mirrors");
                    crate::mirror_sync::sync_all_projects(
                        &mirrors_root,
                        &cfg.scanner.watch_paths,
                    );
                    if let Err(e) = crate::mirror_sync::spawn_watcher(
                        mirrors_root.clone(),
                        cfg.scanner.watch_paths.clone(),
                    ) {
                        warn!(
                            spec = "git-mirror-service",
                            error = %e,
                            "failed to arm mirror watcher — falls back to per-container-stop sync only"
                        );
                    }
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
                        if new_icon_state != old_icon_state
                            && let Some(tray_lock) = TRAY_ICON.get()
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

                        // Rebuild tray menu
                        rebuild_menu(&app_for_rebuild, &state_for_rebuild);
                    });

                event_loop::run(
                    loop_state,
                    scanner_rx,
                    podman_rx,
                    menu_rx,
                    build_rx,
                    build_tx,
                    on_state_change,
                    // @trace spec:app-lifecycle
                    // Hand the event loop an AppHandle so its Quit arm can call
                    // app.exit(0) after shutdown_all() — the only explicit exit
                    // path in the app.
                    app_handle_for_loop.clone(),
                )
                .await;
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tillandsias")
        .run(move |_app, event| {
            // @trace spec:app-lifecycle
            // Tauri no longer hosts any webview windows (OpenCode Web opens
            // in the user's native browser). The only window event we could
            // ever receive is defensive; RunEvent::ExitRequested handling
            // below keeps the tray alive against spurious auto-exits.

            // @trace spec:app-lifecycle
            // ExitRequested discriminates on `code`:
            //   code = None  -> Tauri auto-exit (last window closed). Prevent it —
            //                   the tray icon is the app's identity, not any window.
            //   code = Some  -> Explicit exit initiated by us (event_loop calls
            //                   app.exit(0) after shutdown_all). Finalize and let
            //                   Tauri exit. shutdown_all() already ran; we do NOT
            //                   re-run it here.
            if let tauri::RunEvent::ExitRequested { api, code, .. } = &event {
                if code.is_none() {
                    tracing::debug!(
                        spec = "app-lifecycle",
                        "ExitRequested(None) — auto-exit prevented (tray persists)"
                    );
                    api.prevent_exit();
                    return;
                }
                info!(code = ?code, "Exit requested — finalizing");
                singleton::release();
                let _ = shutdown_tx.blocking_send(());
            }
        });
}

// @trace spec:simplified-tray-ux
// Stage selection driver. Determines which of the five stages the menu
// should display from the live `TrayState` and the cached credential
// probe result. Pure function — no Tauri side-effects.
fn current_stage(s: &TrayState) -> tray_menu::Stage {
    use tillandsias_core::state::BuildStatus;

    // Booting: any in-progress build, or forge image not yet ready.
    let any_in_progress = s
        .active_builds
        .iter()
        .any(|b| matches!(b.status, BuildStatus::InProgress));
    if any_in_progress || !s.forge_available {
        return tray_menu::Stage::Booting;
    }

    // Once images are ready, fall back to the cached credential probe.
    // If the probe hasn't completed yet, show Ready (transient).
    let health = CREDENTIAL_HEALTH
        .get()
        .and_then(|m| m.lock().ok().and_then(|g| g.clone()));
    match health {
        Some(h) => tray_menu::stage_from_health(&h),
        None => tray_menu::Stage::Ready,
    }
}

/// Names of images currently being built — drives the building chip text.
fn in_progress_image_names(s: &TrayState) -> Vec<String> {
    use tillandsias_core::state::BuildStatus;
    s.active_builds
        .iter()
        .filter(|b| matches!(b.status, BuildStatus::InProgress))
        .map(|b| b.image_name.clone())
        .collect()
}

/// Apply the latest state to the pre-built tray menu.
///
/// 1. Pick the right Stage from credential health + build progress.
/// 2. Toggle stage-conditional items via `set_stage`.
/// 3. Refresh the building chip text from active builds.
/// 4. Rebuild the projects submenu (gated internally on a tuple change).
///
/// @trace spec:simplified-tray-ux
fn rebuild_menu(app_handle: &tauri::AppHandle, state: &Arc<Mutex<TrayState>>) {
    let Some(menu) = TRAY_MENU.get() else {
        debug!("TRAY_MENU not yet initialised — skipping rebuild");
        return;
    };
    let s = state.lock().unwrap();
    let stage = current_stage(&s);
    menu.set_stage(stage);

    let names = in_progress_image_names(&s);
    let refs: Vec<&str> = names.iter().map(|s| s.as_str()).collect();
    menu.update_building_chip(&refs);

    let include_remote = menu.include_remote_checked();
    if let Err(e) = menu.update_projects(app_handle, &s, include_remote) {
        debug!(error = %e, "update_projects failed (cosmetic)");
    }
}

/// Dispatch a menu click ID to the appropriate `MenuCommand`. Returns
/// `None` for IDs handled out-of-band (Quit, IncludeRemote — those are
/// resolved at the call site in `on_menu_event`).
fn handle_menu_click(id: &str, tx: &mpsc::Sender<MenuCommand>) {
    if let Some(cmd) = tray_menu::dispatch_click(id)
        && tx.try_send(cmd).is_err() {
            debug!("Menu command channel full/closed — action may be dropped");
        }
}

/// Run the GitHub credential health probe in a background task and store
/// the result in `CREDENTIAL_HEALTH`. After the probe completes the menu
/// is rebuilt so the stage transitions to Authed / NoAuth / NetIssue.
///
/// Cached for the process lifetime; only re-runs on user-initiated
/// sign-in / sign-out actions per the spec.
///
/// @trace spec:simplified-tray-ux
/// Refresh the pre-built menu's static labels (called after a language
/// change so the new strings take effect without rebuilding the tree).
///
/// @trace spec:simplified-tray-ux
pub(crate) fn refresh_menu_labels() {
    if let Some(menu) = TRAY_MENU.get() {
        menu.refresh_static_labels();
    }
}

/// Convenience wrapper for callers that already initialised
/// `TRAY_STATE_HANDLE` (i.e. anything after tray setup). Accepts only
/// the app handle; pulls the state Arc from the global slot.
///
/// @trace spec:simplified-tray-ux
pub(crate) fn reprobe_credentials(app_handle: tauri::AppHandle) {
    if let Some(state) = TRAY_STATE_HANDLE.get() {
        spawn_credential_probe(app_handle, state.clone());
    } else {
        debug!("TRAY_STATE_HANDLE not set — cannot re-probe credentials");
    }
}

pub(crate) fn spawn_credential_probe(
    app_handle: tauri::AppHandle,
    state: Arc<Mutex<TrayState>>,
) {
    // Initialise the slot if missing; clear it so the next read sees None
    // (Ready transient) until the new probe completes.
    let slot = CREDENTIAL_HEALTH.get_or_init(|| Mutex::new(None));
    if let Ok(mut g) = slot.lock() {
        *g = None;
    }
    tauri::async_runtime::spawn(async move {
        let health = crate::github_health::probe().await;
        info!(
            spec = "simplified-tray-ux",
            health = %health,
            "Credential probe complete — applying stage"
        );
        if let Some(slot) = CREDENTIAL_HEALTH.get()
            && let Ok(mut g) = slot.lock()
        {
            *g = Some(health);
        }
        rebuild_menu(&app_handle, &state);
    });
}
