//! Win32 NotifyIcon plumbing for the Windows tray.
//!
//! Owns the message pump, the menu builder, and the bridge between
//! `tillandsias-host-shell` events and Win32 `Shell_NotifyIcon` updates.
//!
//! ## Architecture
//!
//! 1. We register a hidden message-only window via `RegisterClassExW` +
//!    `CreateWindowExW`. All tray events route to this window's wndproc.
//! 2. The wndproc subscribes to:
//!    - `WM_TRAYICON` (our private callback message) for left/right click
//!      on the tray icon
//!    - `WM_TASKBARCREATED` (the broadcast message explorer sends when it
//!      restarts) to re-`Shell_NotifyIconW(NIM_ADD, …)` the icon
//!    - `WM_COMMAND` for menu item clicks
//! 3. Menu items are built from `tillandsias-host-shell::menu_state::build`
//!    using a per-paint ID table; click handlers dispatch by ID.
//! 4. A tokio current-thread runtime runs on the same thread as the
//!    message loop via `LocalSet`. The `WslLifecycle` task lives there,
//!    and progress callbacks flip the global menu state via a `Mutex`
//!    behind the window handle.
//!
//! @trace spec:windows-native-tray

#![allow(dead_code)]
#![allow(unsafe_op_in_unsafe_fn)]

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::OsString;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::process::CommandExt;
use std::sync::Mutex;

use tillandsias_host_shell::menu_action::{self, MenuAction};
use tillandsias_host_shell::menu_state::{
    self, MenuItem, MenuState, MenuStructure, ProjectEntry, SelectedAgent,
};
use tillandsias_host_shell::provisioning::{ProvisionPhase, ProvisionProgress};
use tillandsias_host_shell::pty::{intent_for_action, launch_spec};
use tillandsias_host_shell::scanner::{ProjectEvent, watch_projects};

use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::Graphics::Gdi::HBRUSH;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Shell::{
    NIF_ICON, NIF_INFO, NIF_MESSAGE, NIF_TIP, NIIF_ERROR, NIIF_INFO, NIIF_WARNING, NIM_ADD,
    NIM_DELETE, NIM_MODIFY, NOTIFYICONDATAW, Shell_NotifyIconW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DispatchMessageW,
    GetCursorPos, GetMessageW, HMENU, IDI_APPLICATION, LoadIconW, MF_CHECKED, MF_DISABLED,
    MF_GRAYED, MF_POPUP, MF_STRING, MSG, PostMessageW, PostQuitMessage, RegisterClassExW,
    RegisterWindowMessageW, SetForegroundWindow, TPM_BOTTOMALIGN, TPM_LEFTALIGN, TPM_RIGHTBUTTON,
    TrackPopupMenu, TranslateMessage, WM_APP, WM_COMMAND, WM_DESTROY, WM_LBUTTONUP, WM_RBUTTONUP,
    WNDCLASSEXW, WS_EX_TOOLWINDOW,
};
use windows::core::{PCWSTR, w};

use crate::wsl_lifecycle::WslLifecycle;

/// Our private window message; click on the tray icon routes here.
/// `WM_APP + 1` is the conventional range for app-defined messages.
pub const WM_TRAYICON: u32 = WM_APP + 1;

/// Unique ID assigned to the NotifyIcon — kept stable across the process
/// lifetime so `NIM_MODIFY`/`NIM_DELETE` consistently address it.
const TRAY_ICON_ID: u32 = 1;

/// Menu command-ID range bases.
const MENU_ID_BASE: u16 = 0x1000;
const MENU_ID_QUIT: u16 = 0xEFFF;

// Thread-local correlation table mapping Win32 menu command IDs to the
// portable `MenuItem.id` string. Built every right-click before
// `TrackPopupMenu`; consumed inside the `WM_COMMAND` handler.
thread_local! {
    static MENU_ID_TABLE: RefCell<HashMap<u16, String>> = RefCell::new(HashMap::new());
    static CURRENT_MENU: RefCell<MenuStructure> = RefCell::new(MenuStructure::initial_provisioning());
}

/// Shared state accessible from any thread.
static MENU_STATE: Mutex<Option<MenuState>> = Mutex::new(None);

/// Wraps `fresh_menu_state()` to inject the workspace VERSION into the
/// version footer ("vX.Y.Z — By Tlatoāni" — see menu_state::build_footer).
/// Without this override the tray's footer renders the static
/// `tillandsias-host-shell` `Cargo.toml` `version = "0.1.0"` instead of the
/// release tag the user actually installed. Same root cause + same fix
/// shape as the prior `--diagnose --json` `version`-field workspace-VERSION
/// fix; uses the same `WORKSPACE_VERSION` env var the windows-tray's
/// build.rs already emits. Filed coordination note for the macOS host /
/// host-shell shared crate to make this the default everywhere.
fn fresh_menu_state() -> MenuState {
    let mut state = MenuState::initial();
    state.version = env!("WORKSPACE_VERSION").to_string();
    state
}

/// Progress sink the WSL provisioning pipeline writes to. Each report
/// updates the cached `MenuState.status_text` and pokes the window so the
/// next paint reflects it.
pub struct TrayProgress {
    hwnd: HwndHandle,
}

#[derive(Clone, Copy)]
struct HwndHandle(HWND);

unsafe impl Send for HwndHandle {}
unsafe impl Sync for HwndHandle {}

impl TrayProgress {
    pub fn new(hwnd: HWND) -> Self {
        Self {
            hwnd: HwndHandle(hwnd),
        }
    }
}

impl ProvisionProgress for TrayProgress {
    fn report_phase(&self, phase: ProvisionPhase) {
        update_status_text(phase.status_text(), self.hwnd.0);
    }
    fn report_message(&self, message: &str) {
        // Sub-messages refine the current phase chip in-place — e.g. the
        // recipe path streams "Downloading rootfs N / M MB (P%)" through here
        // during materialization, mirroring the macOS fetch-progress chip
        // (slice 7, `f5443276`). Each subsequent `report_phase` call replaces
        // the chip with the next phase, so transitions are clean.
        update_status_text(message, self.hwnd.0);
    }
}

fn update_status_text(text: &str, hwnd: HWND) {
    if let Ok(mut guard) = MENU_STATE.lock() {
        if let Some(state) = guard.as_mut() {
            state.status_text = text.to_string();
        } else {
            let mut state = fresh_menu_state();
            state.status_text = text.to_string();
            *guard = Some(state);
        }
    }
    // Update the tooltip on the live icon so users can mouseover for a
    // quick read.
    let mut nid: NOTIFYICONDATAW = unsafe { std::mem::zeroed() };
    nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
    nid.hWnd = hwnd;
    nid.uID = TRAY_ICON_ID;
    nid.uFlags = NIF_TIP;
    write_utf16_into(&mut nid.szTip, text);
    unsafe {
        let _ = Shell_NotifyIconW(NIM_MODIFY, &nid);
    }
}

/// Severity of a tray balloon notification — maps to the Win11 toast icon.
#[derive(Clone, Copy, PartialEq, Eq)]
enum BalloonSeverity {
    Info,
    Warning,
    Error,
}

/// Pop a tray balloon notification (modern Win11 surfaces this as a toast in
/// the Action Center). Uses `NIM_MODIFY` with `NIF_INFO`, reusing the icon's
/// existing identity. Best-effort — silently no-op on `Shell_NotifyIconW`
/// failure (the chip + log still carry the same info).
fn show_balloon(hwnd: HWND, title: &str, message: &str, severity: BalloonSeverity) {
    let mut nid: NOTIFYICONDATAW = unsafe { std::mem::zeroed() };
    nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
    nid.hWnd = hwnd;
    nid.uID = TRAY_ICON_ID;
    nid.uFlags = NIF_INFO;
    write_utf16_into(&mut nid.szInfo, message);
    write_utf16_into(&mut nid.szInfoTitle, title);
    nid.dwInfoFlags = match severity {
        BalloonSeverity::Info => NIIF_INFO,
        BalloonSeverity::Warning => NIIF_WARNING,
        BalloonSeverity::Error => NIIF_ERROR,
    };
    unsafe {
        let _ = Shell_NotifyIconW(NIM_MODIFY, &nid);
    }
}

/// Compose the live chip text from a base phase line + an optional headless
/// `last_event`. When the event is `Some` and non-empty, appends `" \u{00B7} <evt>"`
/// (Unicode MIDDLE DOT) so the user can see what the in-VM headless is doing
/// (e.g. `"\u{1F7E2} Ready \u{00B7} forge-foo created"`). Pure + testable.
fn compose_chip_text(base: &str, last_event: Option<&str>) -> String {
    match last_event.map(str::trim).filter(|s| !s.is_empty()) {
        Some(evt) => format!("{base} \u{00B7} {evt}"),
        None => base.to_string(),
    }
}

fn write_utf16_into<const N: usize>(buf: &mut [u16; N], text: &str) {
    let encoded: Vec<u16> = OsString::from(text).encode_wide().take(N - 1).collect();
    for (slot, value) in buf
        .iter_mut()
        .zip(encoded.iter().chain(std::iter::once(&0)))
    {
        *slot = *value;
    }
}

/// Entry point invoked from `main`. Blocks until the user picks "Quit" on
/// the tray; returns `!` because the OS message loop owns the thread.
pub fn run() -> ! {
    // Route tracing to a file before anything logs — a GUI tray has no console.
    init_tracing();
    tracing::info!(log = %log_file_path().display(), "tillandsias tray starting");

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("build current-thread runtime");

    let local = tokio::task::LocalSet::new();

    let exit_code = local.block_on(&runtime, async {
        let hwnd = match unsafe { create_message_window() } {
            Ok(hwnd) => hwnd,
            Err(err) => {
                eprintln!("failed to create tray window: {err:?}");
                return 1;
            }
        };
        if let Err(err) = unsafe { add_tray_icon(hwnd) } {
            eprintln!("failed to register notify icon: {err:?}");
            return 1;
        }

        // Initialise menu state; the WSL lifecycle task will mutate it.
        {
            let mut guard = MENU_STATE.lock().unwrap();
            *guard = Some(fresh_menu_state());
        }

        // Host-side project discovery: scan %USERPROFILE%\src and keep the
        // menu's local-projects list current. This runs entirely on the host
        // and needs no VM, so the tray lists ~/src projects from first paint
        // (the popup rebuilds from MENU_STATE on every right-click).
        // @trace spec:host-shell-architecture.scanner.local-project-discovery@v1
        match watch_projects(&crate::wsl_lifecycle::user_src_dir()) {
            Ok(mut rx) => {
                tokio::task::spawn_local(async move {
                    while let Some(ev) = rx.recv().await {
                        apply_project_event(ev);
                    }
                });
            }
            Err(err) => {
                tracing::warn!(%err, "host-side ~/src project scan unavailable");
            }
        }

        // Spawn the WSL provisioning + lifecycle task, UNLESS dev mode asked us
        // to skip it. `--no-provision` (or TILLANDSIAS_NO_PROVISION=1) brings the
        // tray up in a clean, interactive state — no rootfs download, no
        // `wsl --import` — so the menu can be exercised locally before the VM /
        // recipe path lands. Progress is reported via the TrayProgress sink
        // which updates the tooltip and menu.
        if provisioning_enabled() {
            spawn_provisioning(hwnd);
        } else {
            tracing::info!(
                "provisioning skipped (--no-provision / TILLANDSIAS_NO_PROVISION); \
                 tray running in menu-only dev mode"
            );
            update_status_text("\u{26AA} Dev mode \u{2014} VM provisioning skipped", hwnd);
        }

        // Pump messages until WM_QUIT.
        let mut msg = MSG::default();
        loop {
            let r = unsafe { GetMessageW(&mut msg, HWND::default(), 0, 0) };
            if r.0 <= 0 {
                break;
            }
            unsafe {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            // A `Retry` click (handled synchronously in the wndproc above) only
            // sets a flag; spawn the new provisioning task here, in the LocalSet
            // context, right after dispatching the click that requested it.
            if RETRY_REQUESTED.swap(false, std::sync::atomic::Ordering::SeqCst) {
                spawn_provisioning(hwnd);
            }
            // Cooperative tokio drain.
            tokio::task::yield_now().await;
        }

        // Clean up the tray icon first so Quit gives instant visual feedback.
        unsafe {
            let mut nid: NOTIFYICONDATAW = std::mem::zeroed();
            nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
            nid.hWnd = hwnd;
            nid.uID = TRAY_ICON_ID;
            let _ = Shell_NotifyIconW(NIM_DELETE, &nid);
        }

        // Quit → graceful drain. The provision task (now being torn down with the
        // LocalSet) held the keepalive `wsl` session; on Windows a parent exit
        // does NOT reap that child, so without an explicit `wsl --terminate` the
        // utility VM (and the orphaned keepalive) would linger until WSL's own
        // idle timeout. Issue a bounded stop so the VM is torn down deterministically
        // — matches the macOS/Linux trays' Quit → drain contract.
        // @trace plan/steps/windows-next-thin-tray.md (Quit → graceful drain)
        if provisioning_enabled() {
            // Step 1: optimistic wire-level graceful drain (convergence packet
            // Q2 — `a10dc0f6`). Headless gets a chance to stop podman
            // containers cleanly before we yank the VM. Bounded so a hung
            // wire doesn't delay Quit; we fall through to the hard terminate
            // regardless of the outcome.
            let _ = tokio::time::timeout(
                std::time::Duration::from_secs(3),
                request_vm_shutdown(10_000),
            )
            .await;

            // Step 2: hard backstop — `wsl --terminate`. On Windows a parent
            // exit does NOT reap the keepalive `wsl --exec` child, so without
            // this the utility VM (and the orphaned keepalive) would linger
            // until WSL's own idle timeout.
            let lifecycle = WslLifecycle::new();
            let drain = lifecycle.graceful_shutdown();
            match tokio::time::timeout(std::time::Duration::from_secs(15), drain).await {
                Ok(Ok(())) => tracing::info!("VM drained on Quit (wsl --terminate)"),
                Ok(Err(err)) => tracing::warn!(%err, "VM drain on Quit failed"),
                Err(_) => tracing::warn!("VM drain on Quit timed out after 15s"),
            }
        }
        msg.wParam.0 as i32
    });
    std::process::exit(exit_code);
}

/// Directory the tray writes its log file to (`%LOCALAPPDATA%\tillandsias\logs`,
/// falling back to the temp dir if `LOCALAPPDATA` is somehow unset).
fn log_dir() -> std::path::PathBuf {
    std::env::var_os("LOCALAPPDATA")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("tillandsias")
        .join("logs")
}

/// The tray's log file — a fixed path so "Open Log" always knows where to look.
fn log_file_path() -> std::path::PathBuf {
    log_dir().join("tray.log")
}

/// Initialize file-based tracing. A release tray is a GUI-subsystem binary with
/// no console, so `tracing::{info,warn,error}!` events are lost unless routed to
/// a file. Writes (synchronously — tray log volume is tiny, and this avoids a
/// `WorkerGuard` that `process::exit` would skip flushing) to
/// `%LOCALAPPDATA%\tillandsias\logs\tray.log`, honoring `RUST_LOG` (default
/// `info`). Idempotent: a second call is a no-op (`try_init`).
fn init_tracing() {
    let dir = log_dir();
    let _ = std::fs::create_dir_all(&dir);
    let appender = tracing_appender::rolling::never(&dir, "tray.log");
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    let _ = tracing_subscriber::fmt()
        .with_writer(appender)
        .with_ansi(false)
        .with_target(false)
        .with_env_filter(filter)
        .try_init();
}

/// Reveal the tray log file in Explorer (`/select,` highlights it in its
/// folder), so the user doesn't depend on a `.log` default-app association.
fn open_log_file() {
    let path = log_file_path();
    // Explorer needs the path as a single argument; `/select,<path>` opens the
    // containing folder with the file highlighted.
    let _ = std::process::Command::new("explorer.exe")
        .arg(format!("/select,{}", path.display()))
        .spawn();
}

/// Headless diagnostic entry point (`tillandsias-tray --provision-once`): run the
/// recipe provisioning flow to completion, printing each phase to stdout, and
/// return a process exit code (0 = VM reached Ready over the control wire, 1 =
/// failed). A release tray is a GUI-subsystem binary with no console, so this
/// gives an observable, scriptable end-to-end provision run for CI smoke and the
/// live-provision dress rehearsal. Does NOT hold a keepalive — it provisions to
/// Ready, reports, and exits (the VM idles down normally afterward).
pub fn provision_once() -> i32 {
    struct ConsoleProgress;
    impl ProvisionProgress for ConsoleProgress {
        fn report_phase(&self, phase: ProvisionPhase) {
            println!("[provision] phase: {}", phase.status_text());
            tracing::info!(?phase, "provision phase");
        }
        fn report_message(&self, message: &str) {
            println!("[provision] {message}");
        }
    }

    init_tracing();
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(err) => {
            eprintln!("[provision] failed to build tokio runtime: {err}");
            return 1;
        }
    };
    println!("[provision] starting recipe provisioning (live dress rehearsal)\u{2026}");
    runtime.block_on(async {
        let lifecycle = WslLifecycle::new();
        match lifecycle
            .provision_via_recipe(std::sync::Arc::new(ConsoleProgress))
            .await
        {
            Ok(()) => {
                println!("[provision] RESULT: VM Ready \u{2014} control wire up \u{2713}");
                tracing::info!("provision-once: VM Ready");
                0
            }
            Err(err) => {
                eprintln!("[provision] RESULT: FAILED \u{2014} {err}");
                tracing::error!(%err, "provision-once failed");
                1
            }
        }
    })
}

/// Structured `--status-once` report. Mirrors the JSON shape of the `wire`
/// sub-object inside `--diagnose --json` (same field names + types), plus an
/// `exit_code` so a JSON consumer doesn't have to mirror the wire-state →
/// exit-code derivation. Pinned by `status_once_json_keys_pinned`.
#[derive(serde::Serialize)]
struct StatusReport {
    /// `true` once handshake succeeds. Mirrors `WireReport.reachable`.
    reachable: bool,
    /// Negotiated wire_version (`u16`) if handshake succeeded. Matches the
    /// `WIRE_VERSION` const type in `tillandsias-control-wire`.
    wire_version: Option<u16>,
    /// Debug-formatted `VmPhase` if `VmStatusReply` arrived.
    phase: Option<String>,
    /// In-VM headless reports `true` once podman responds to a no-op exec.
    podman_ready: Option<bool>,
    /// Free-form headless event string (None if not surfaced).
    last_event: Option<String>,
    /// Set on any failure path (open / handshake / request / unexpected reply).
    error: Option<String>,
    /// Final exit code so JSON consumers don't need to re-derive
    /// 0/2/1 from phase/reachable. See `--status-once` exit-code contract
    /// (`status-once-exit-codes` pin).
    exit_code: i32,
}

/// Compute the `--status-once` exit code from a freshly-collected status report.
/// 0 = Ready, 2 = reachable but not Ready, 1 = control wire unreachable / hard
/// error. Pure so a unit test can pin the matrix.
fn status_exit_code(report: &StatusReport) -> i32 {
    if !report.reachable {
        return 1;
    }
    match report.phase.as_deref() {
        Some("Ready") => 0,
        Some(_) => 2,
        None => 1,
    }
}

/// Headless diagnostic entry point (`tillandsias-tray --status-once`): connect to
/// an already-provisioned VM's HvSocket control wire, request `VmStatus`, and
/// print the phase / podman_ready / last_event. Exit code: 0 = Ready, 2 =
/// reachable but not Ready, 1 = control wire unreachable. Pairs with
/// `--provision-once` for scriptable installed-tray health checks (the GUI tray
/// has no console). Reuses the same handshake + `VmStatusRequest` path the
/// provisioning Connecting loop uses.
///
/// `format` mirrors the `--diagnose` format selector: `Human` prints the
/// pre-existing `[status] …` lines for human eyeballs, `Json` emits a single
/// `StatusReport` JSON object on stdout for support-tooling consumers.
pub fn status_once(format: DiagnoseFormat) -> i32 {
    init_tracing();
    let report = collect_status_report();
    match format {
        DiagnoseFormat::Human => print_status_human(&report),
        DiagnoseFormat::Json => print_status_json(&report),
    }
    report.exit_code
}

/// Build a `StatusReport` by opening the control wire, performing the
/// handshake, and issuing a `VmStatusRequest`. Captures every failure mode
/// as an `error` string so the structured output is the same shape on the
/// success and failure paths.
fn collect_status_report() -> StatusReport {
    let port = tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(err) => {
            return StatusReport {
                reachable: false,
                wire_version: None,
                phase: None,
                podman_ready: None,
                last_event: None,
                error: Some(format!("tokio runtime build failed: {err}")),
                exit_code: 1,
            };
        }
    };
    let mut report = runtime.block_on(async {
        use tillandsias_control_wire::transport::Transport;
        use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
        use tillandsias_host_shell::vsock_client::Client;

        let stream = match crate::hvsocket::open_hvsocket_stream(port).await {
            Ok(stream) => stream,
            Err(err) => {
                return StatusReport {
                    reachable: false,
                    wire_version: None,
                    phase: None,
                    podman_ready: None,
                    last_event: None,
                    error: Some(format!(
                        "control wire unreachable on vsock {port}: {err} (is the VM \
                         provisioned + running? try --provision-once)"
                    )),
                    exit_code: 0,
                };
            }
        };
        let mut client = Client::from_stream(Box::new(stream), Transport::Vsock { cid: 0, port });
        let wire_version = match client.handshake().await {
            Ok(v) => v,
            Err(err) => {
                return StatusReport {
                    reachable: false,
                    wire_version: None,
                    phase: None,
                    podman_ready: None,
                    last_event: None,
                    error: Some(format!("handshake failed: {err}")),
                    exit_code: 0,
                };
            }
        };
        let seq = client.allocate_seq();
        let envelope = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
            body: ControlMessage::VmStatusRequest { seq },
        };
        let reply = match client.request(&envelope).await {
            Ok(reply) => reply,
            Err(err) => {
                return StatusReport {
                    reachable: true,
                    wire_version: Some(wire_version),
                    phase: None,
                    podman_ready: None,
                    last_event: None,
                    error: Some(format!("VmStatusRequest failed: {err}")),
                    exit_code: 0,
                };
            }
        };
        match reply.body {
            ControlMessage::VmStatusReply {
                phase,
                podman_ready,
                last_event,
                ..
            } => StatusReport {
                reachable: true,
                wire_version: Some(wire_version),
                phase: Some(format!("{phase:?}")),
                podman_ready: Some(podman_ready),
                last_event,
                error: None,
                exit_code: 0,
            },
            other => StatusReport {
                reachable: true,
                wire_version: Some(wire_version),
                phase: None,
                podman_ready: None,
                last_event: None,
                error: Some(format!("unexpected reply to VmStatusRequest: {other:?}")),
                exit_code: 0,
            },
        }
    });
    report.exit_code = status_exit_code(&report);
    report
}

fn print_status_human(r: &StatusReport) {
    if let Some(v) = r.wire_version {
        println!("[status] control wire up (wire_version {v})");
    }
    if let Some(err) = &r.error {
        eprintln!("[status] {err}");
        return;
    }
    if let Some(phase) = &r.phase {
        println!("[status] phase:        {phase}");
    }
    if let Some(pr) = r.podman_ready {
        println!("[status] podman_ready: {pr}");
    }
    println!(
        "[status] last_event:   {}",
        r.last_event.as_deref().unwrap_or("(none)")
    );
}

fn print_status_json(r: &StatusReport) {
    match serde_json::to_string_pretty(r) {
        Ok(json) => println!("{json}"),
        Err(err) => eprintln!("[status] failed to serialize JSON: {err}"),
    }
}

/// Pinned chip text for control-wire degradation. Naming + byte sequence MUST
/// match macOS's identical const (slice 23, `cbeedb4a`) so a future refactor
/// on either side can't silently break the cross-tray UX-parity invariant —
/// operators see the same text for the same failure class. Pinned by
/// `wire_unreachable_chip_text_pinned`.
pub const WIRE_UNREACHABLE_CHIP_TEXT: &str = "\u{1F534} Wire unreachable";

/// Mark the live status chip as wire-unreachable. Called from the poll loop
/// when `refresh_vm_status` can't reach the in-VM headless — without this, a
/// mid-session wire failure (headless crash, VM terminated externally, etc.)
/// would leave the chip showing the last-known "Ready" state forever. Also
/// clears `MenuState.podman_ready` so per-project actions are correctly
/// re-gated. The next successful poll restores the phase + podman chip
/// naturally.
fn mark_wire_unreachable(hwnd: HWND) {
    if let Ok(mut guard) = MENU_STATE.lock() {
        guard.get_or_insert_with(fresh_menu_state).podman_ready = false;
    }
    update_status_text(WIRE_UNREACHABLE_CHIP_TEXT, hwnd);
}

/// Compose a one-line description of an `Error` reply the in-VM headless's
/// dispatcher returns when a request is unsupported / mis-routed / failed.
/// Used by `refresh_vm_status` / `refresh_cloud_projects` / `diagnose` so
/// operators see the dispatcher's "descriptive surface" (per the convergence
/// packet's Q1/Q2/Q4 matrix routing) instead of a silent fall-through.
fn describe_wire_error(code: tillandsias_control_wire::ErrorCode, message: &str) -> String {
    if message.is_empty() {
        format!("dispatcher error {code:?}")
    } else {
        format!("dispatcher error {code:?}: {message}")
    }
}

/// Condensed status-line text for a live VM phase + podman readiness. Drives the
/// shared `ids::STATUS` chip (and the tray tooltip) so the menu reflects real VM
/// health — converges with the macOS tray's status-chip-to-VM-phase wiring.
fn vm_phase_status_text(phase: tillandsias_control_wire::VmPhase, podman_ready: bool) -> String {
    use tillandsias_control_wire::VmPhase;
    match phase {
        VmPhase::Ready if podman_ready => "\u{1F7E2} Ready".to_string(),
        VmPhase::Ready => "\u{1F7E1} Ready (podman starting\u{2026})".to_string(),
        VmPhase::Provisioning => "\u{1F535} Provisioning\u{2026}".to_string(),
        VmPhase::Starting => "\u{1F535} Starting\u{2026}".to_string(),
        VmPhase::Draining => "\u{1F7E0} Draining\u{2026}".to_string(),
        VmPhase::Stopping => "\u{1F534} Stopping\u{2026}".to_string(),
        VmPhase::Failed => "\u{1F534} VM failed".to_string(),
    }
}

/// Poll the in-VM `VmStatus` once over the control wire and reflect it in the
/// shared `MenuState`: sets `podman_ready` (which gates per-project actions like
/// "Attach Here" in `menu_state::build`) and refreshes the status line + tooltip
/// from the live phase. Best-effort — a transient wire error leaves the last
/// known state untouched (logged at debug). Reuses the proven handshake +
/// `VmStatusRequest` path.
async fn refresh_vm_status(hwnd: HWND) {
    use tillandsias_control_wire::transport::{CONTROL_WIRE_VSOCK_PORT, Transport};
    use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
    use tillandsias_host_shell::vsock_client::Client;

    // Open HvSocket (Windows realization of vsock-connect) + drive the standard
    // host-shell Client — same shared Client + Hello/HelloAck + request path as
    // the macOS poll_vm_status_once (slice 4, `80d9196e`), only the transport
    // open differs per OS.
    let stream = match crate::hvsocket::open_hvsocket_stream(CONTROL_WIRE_VSOCK_PORT).await {
        Ok(stream) => stream,
        Err(err) => {
            tracing::debug!(%err, "vm status poll: control wire unreachable");
            mark_wire_unreachable(hwnd);
            return;
        }
    };
    let mut client = Client::from_stream(
        Box::new(stream),
        Transport::Vsock {
            cid: 0,
            port: CONTROL_WIRE_VSOCK_PORT,
        },
    );
    if let Err(err) = client.handshake().await {
        tracing::debug!(%err, "vm status poll: handshake failed");
        mark_wire_unreachable(hwnd);
        return;
    }
    let seq = client.allocate_seq();
    let envelope = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq,
        body: ControlMessage::VmStatusRequest { seq },
    };
    let reply = match client.request(&envelope).await {
        Ok(reply) => reply,
        Err(err) => {
            tracing::debug!(%err, "vm status poll: VmStatusRequest failed");
            mark_wire_unreachable(hwnd);
            return;
        }
    };
    match reply.body {
        ControlMessage::VmStatusReply {
            phase,
            podman_ready,
            last_event,
            ..
        } => {
            if let Ok(mut guard) = MENU_STATE.lock() {
                guard.get_or_insert_with(fresh_menu_state).podman_ready = podman_ready;
            }
            // status_text + tooltip (own MENU_STATE lock inside). Appends the
            // headless's `last_event` when present so the chip reflects in-VM
            // activity (e.g. "Ready · forge-foo created"), not just the phase.
            let base = vm_phase_status_text(phase, podman_ready);
            update_status_text(&compose_chip_text(&base, last_event.as_deref()), hwnd);
            tracing::debug!(?phase, podman_ready, "vm status polled");
        }
        // Per the control-dispatch convergence packet (5c67ddb9, aeb5499a) the
        // headless's vsock dispatcher returns an `Error{Unsupported, …}` frame
        // when a request has no inner handler yet. Surface it at WARN so an
        // operator sees why a poll didn't refresh the chip.
        ControlMessage::Error { code, message, .. } => {
            tracing::warn!("vm status poll: {}", describe_wire_error(code, &message));
        }
        other => {
            tracing::debug!("vm status poll: unexpected reply variant {}", other.kind());
        }
    }
}

/// Map a wire `LocalProjectEntry` ({label, guest_path, last_seen_unix}) onto the
/// shared menu `ProjectEntry`. `path` is the in-VM mount path the headless
/// reported — used by "Attach Here" forge-container launches as the cwd. `ready`
/// is `false` because per-project forge status isn't on the wire yet (slice 19
/// note). Mirrors macOS `local_entry_to_menu` (slice 19, `06088c41`).
fn local_entry_to_menu(entry: &tillandsias_control_wire::LocalProjectEntry) -> ProjectEntry {
    ProjectEntry {
        name: entry.label.clone(),
        path: entry.guest_path.clone(),
        ready: false,
    }
}

/// Poll the in-VM headless's `EnumerateLocalProjects` handler (convergence
/// packet Q4; landed in `05cc3a7d`) and merge the result into the shared
/// `MenuState.local_projects`. Complementary to the host-side `~/src` scanner
/// (which delivers immediate file-change updates without a running VM); the
/// wire poll picks up VM-side reconciliation on a slower cadence and matches
/// the macOS tray's polling shape (slice 19, `06088c41`).
///
/// Best-effort: a transient wire error / Error{Unsupported} leaves the
/// last-known list untouched (logged at debug / warn respectively).
async fn refresh_local_projects(_hwnd: HWND) {
    use tillandsias_control_wire::transport::{CONTROL_WIRE_VSOCK_PORT, Transport};
    use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
    use tillandsias_host_shell::vsock_client::Client;

    let stream = match crate::hvsocket::open_hvsocket_stream(CONTROL_WIRE_VSOCK_PORT).await {
        Ok(stream) => stream,
        Err(err) => {
            tracing::debug!(%err, "local projects refresh: control wire unreachable");
            return;
        }
    };
    let mut client = Client::from_stream(
        Box::new(stream),
        Transport::Vsock {
            cid: 0,
            port: CONTROL_WIRE_VSOCK_PORT,
        },
    );
    if let Err(err) = client.handshake().await {
        tracing::debug!(%err, "local projects refresh: handshake failed");
        return;
    }
    let seq = client.allocate_seq();
    let envelope = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq,
        body: ControlMessage::EnumerateLocalProjects { seq },
    };
    let reply = match client.request(&envelope).await {
        Ok(reply) => reply,
        Err(err) => {
            tracing::debug!(%err, "local projects refresh: request failed");
            return;
        }
    };
    match reply.body {
        ControlMessage::LocalProjectsReply { entries, .. } => {
            let mapped: Vec<ProjectEntry> = entries.iter().map(local_entry_to_menu).collect();
            let n = mapped.len();
            if let Ok(mut guard) = MENU_STATE.lock() {
                guard.get_or_insert_with(fresh_menu_state).local_projects = mapped;
            }
            tracing::debug!(count = n, "local projects refreshed (VM-side)");
        }
        // Per convergence packet item 4 (eddb5c00): surface the dispatcher's
        // Error so an operator sees why the local-projects didn't refresh.
        ControlMessage::Error { code, message, .. } => {
            tracing::warn!(
                "local projects refresh: {}",
                describe_wire_error(code, &message)
            );
        }
        other => {
            tracing::debug!(
                "local projects refresh: unexpected reply variant {}",
                other.kind()
            );
        }
    }
}

/// Send a `VmShutdownRequest` over the control wire as the optimistic
/// graceful-drain path before the hard `wsl --terminate` backstop.
///
/// Best-effort + bounded. When the in-VM headless's vsock-side inner handler
/// ships (currently unix-only, `a10dc0f6`) it gets `drain_timeout_ms` to stop
/// podman containers cleanly before we yank the VM. Today on vsock the
/// dispatcher routes per the matrix; no inner handler exists yet, so the
/// reply is `Error{Unsupported}`, which we log at info (it's the expected
/// current state). When linux adds the vsock arm this auto-upgrades with no
/// tray change. Convergence packet Q2.
async fn request_vm_shutdown(drain_timeout_ms: u32) {
    use tillandsias_control_wire::transport::{CONTROL_WIRE_VSOCK_PORT, Transport};
    use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
    use tillandsias_host_shell::vsock_client::Client;

    let stream = match crate::hvsocket::open_hvsocket_stream(CONTROL_WIRE_VSOCK_PORT).await {
        Ok(stream) => stream,
        Err(err) => {
            tracing::debug!(%err, "vm shutdown request: control wire unreachable");
            return;
        }
    };
    let mut client = Client::from_stream(
        Box::new(stream),
        Transport::Vsock {
            cid: 0,
            port: CONTROL_WIRE_VSOCK_PORT,
        },
    );
    if let Err(err) = client.handshake().await {
        tracing::debug!(%err, "vm shutdown request: handshake failed");
        return;
    }
    let seq = client.allocate_seq();
    let envelope = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq,
        body: ControlMessage::VmShutdownRequest {
            seq,
            drain_timeout_ms,
        },
    };
    let reply = match client.request(&envelope).await {
        Ok(reply) => reply,
        Err(err) => {
            tracing::debug!(%err, "vm shutdown request: send failed");
            return;
        }
    };
    match reply.body {
        ControlMessage::Error { code, message, .. } => {
            tracing::info!(
                "vm shutdown request: {} (wire-level drain not yet wired on vsock; falling back to wsl --terminate)",
                describe_wire_error(code, &message)
            );
        }
        other => {
            tracing::info!("vm shutdown request acknowledged: {}", other.kind());
        }
    }
}

/// Map a wire `CloudProjectEntry` ({label, owner, repo, default_branch}) onto the
/// shared menu `ProjectEntry` (the cloud-projects submenu the host renders).
/// `ProjectEntry::path` is the `owner/repo` slug (per its doc); `ready` is always
/// false for cloud projects (they have no in-VM forge container).
fn cloud_entry_to_menu(entry: &tillandsias_control_wire::CloudProjectEntry) -> ProjectEntry {
    ProjectEntry {
        name: entry.label.clone(),
        path: format!("{}/{}", entry.owner, entry.repo),
        ready: false,
    }
}

/// Poll the in-VM headless's `CloudRefreshRequest` (real `gh repo list` once
/// `e1a190d4` landed) and reflect the result in the shared
/// `MenuState.cloud_projects` so the menu's cloud-projects submenu shows the
/// logged-in user's repos. Best-effort: a transient wire error / unauthenticated
/// gh leaves the last-known list untouched (logged at debug).
async fn refresh_cloud_projects(_hwnd: HWND) {
    use tillandsias_control_wire::transport::{CONTROL_WIRE_VSOCK_PORT, Transport};
    use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
    use tillandsias_host_shell::vsock_client::Client;

    let stream = match crate::hvsocket::open_hvsocket_stream(CONTROL_WIRE_VSOCK_PORT).await {
        Ok(stream) => stream,
        Err(err) => {
            tracing::debug!(%err, "cloud refresh: control wire unreachable");
            return;
        }
    };
    let mut client = Client::from_stream(
        Box::new(stream),
        Transport::Vsock {
            cid: 0,
            port: CONTROL_WIRE_VSOCK_PORT,
        },
    );
    if let Err(err) = client.handshake().await {
        tracing::debug!(%err, "cloud refresh: handshake failed");
        return;
    }
    let seq = client.allocate_seq();
    let envelope = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq,
        body: ControlMessage::CloudRefreshRequest { seq },
    };
    let reply = match client.request(&envelope).await {
        Ok(reply) => reply,
        Err(err) => {
            tracing::debug!(%err, "cloud refresh: request failed");
            return;
        }
    };
    match reply.body {
        ControlMessage::CloudRefreshReply { projects, .. } => {
            let mapped: Vec<ProjectEntry> = projects.iter().map(cloud_entry_to_menu).collect();
            let n = mapped.len();
            if let Ok(mut guard) = MENU_STATE.lock() {
                guard.get_or_insert_with(fresh_menu_state).cloud_projects = mapped;
            }
            tracing::debug!(count = n, "cloud projects refreshed");
        }
        // Convergence packet (5c67ddb9): dispatcher returns Error{Unsupported}
        // for variants not yet wired on this transport. Surface it so an
        // operator can see why the cloud-projects submenu didn't refresh.
        ControlMessage::Error { code, message, .. } => {
            tracing::warn!("cloud refresh: {}", describe_wire_error(code, &message));
        }
        other => {
            tracing::debug!("cloud refresh: unexpected reply variant {}", other.kind());
        }
    }
}

/// Parse the SHA-256 pin for `key` (e.g. `"x86_64.tar"`) out of the embedded
/// recipe `manifest.toml` `[output.expected_rootfs_sha]` table, returning its
/// first 12 hex chars. Tolerates both the quoted-key form the recipe-publish CI
/// emits (`"x86_64.tar" = "<sha>"`) and the bare-key form a future author might
/// drop the quotes on. Any non-hex placeholder (e.g. `"pending-ci"`) fails the
/// `>= 12 hex chars` gate and returns `None` so the caller can fall back to a
/// "(not found / parse skipped)" message. Mirrors the macOS diagnose
/// manifest-pin parser (slice 11a, `a97b219a`).
fn parse_rootfs_sha_pin(manifest_toml: &str, key: &str) -> Option<String> {
    for line in manifest_toml.lines() {
        let trimmed = line.trim().trim_start_matches('"');
        if let Some(rest) = trimmed.strip_prefix(key) {
            let rest = rest.trim_start_matches(['"', ' ', '=']);
            let rest = rest.trim_start_matches('"');
            let sha: String = rest.chars().take_while(|c| c.is_ascii_hexdigit()).collect();
            if sha.len() >= 12 {
                return Some(sha[..12].to_string());
            }
        }
    }
    None
}

/// Headless diagnostic entry point (`tillandsias-tray --diagnose`): print a
/// bundled health report — tray version, log file, `wt.exe` availability,
/// `tillandsias` distro registration, live control-wire status (phase +
/// `podman_ready` + `last_event`), and the recent log tail — for installed-tray
/// support. Exit 0 if everything reachable + Ready; 2 if degraded; 1 on a hard
/// failure (no runtime, etc.). Pairs with `--provision-once` / `--status-once`.
/// Output format for `--diagnose`.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum DiagnoseFormat {
    /// Human-readable text report (default).
    Human,
    /// Machine-readable JSON object for support tooling.
    Json,
}

/// Structured diagnostic report. The `--diagnose` mode builds one of these and
/// formats it as either human-readable text or JSON, so support tooling parsing
/// the JSON sees the exact same fields the human report shows.
#[derive(serde::Serialize)]
struct DiagnoseReport {
    version: &'static str,
    /// Short git SHA of the commit this binary was built from. Baked at
    /// compile time by build.rs (`BUILD_COMMIT_SHA`); falls back to
    /// `"unknown"` if git wasn't available or the build was from a source
    /// tarball with no working tree. Useful for correlating a running tray
    /// to a specific commit when an operator pastes `--diagnose --json`
    /// into a bug report (the workspace `version` rolls only on release,
    /// so two binaries from the same release tag can still differ).
    build_commit: &'static str,
    log_path: String,
    log_exists: bool,
    wt_present: bool,
    distro: &'static str,
    distro_registered: bool,
    release_tag: &'static str,
    manifest_pin_x86_64_tar: Option<String>,
    wire: WireReport,
    recent_log_tail: Vec<String>,
}

#[derive(serde::Serialize)]
struct WireReport {
    reachable: bool,
    /// Debug-formatted VmPhase variant (e.g. `"Ready"`, `"Draining"`).
    phase: Option<String>,
    podman_ready: Option<bool>,
    last_event: Option<String>,
    /// On `reachable=false`: the reason (handshake failure, open error, etc.).
    error: Option<String>,
}

pub fn diagnose(format: DiagnoseFormat) -> i32 {
    init_tracing();
    let report = collect_report();
    match format {
        DiagnoseFormat::Human => print_human(&report),
        DiagnoseFormat::Json => print_json(&report),
    }
    exit_code_from(&report)
}

fn collect_report() -> DiagnoseReport {
    use tillandsias_control_wire::transport::{CONTROL_WIRE_VSOCK_PORT, Transport};
    use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
    use tillandsias_host_shell::vsock_client::Client;

    let log = log_file_path();
    let log_exists = log.exists();

    let wt_present = std::process::Command::new("where.exe")
        .arg("wt.exe")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    // `wsl.exe -l -q` emits UTF-16LE with a BOM by default; `WSL_UTF8=1` forces
    // plain UTF-8 so `String::from_utf8_lossy` actually sees readable lines.
    // Without this, `lines().any(eq DISTRO_NAME)` returned false even on a
    // registered distro — the bytes parsed as mojibake.
    let distro_registered = std::process::Command::new("wsl.exe")
        .env("WSL_UTF8", "1")
        .args(["-l", "-q"])
        .output()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .any(|l| l.trim() == crate::wsl_lifecycle::DISTRO_NAME)
        })
        .unwrap_or(false);

    let manifest_pin = parse_rootfs_sha_pin(crate::wsl_lifecycle::RECIPE_MANIFEST, "x86_64.tar");

    // Live control wire. Tokio runtime build is essentially infallible — on the
    // rare failure we still emit a (degraded) report rather than aborting.
    let wire = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime.block_on(async {
            let stream = match crate::hvsocket::open_hvsocket_stream(CONTROL_WIRE_VSOCK_PORT).await
            {
                Ok(s) => s,
                Err(err) => {
                    return WireReport {
                        reachable: false,
                        phase: None,
                        podman_ready: None,
                        last_event: None,
                        error: Some(format!("hvsocket open: {err}")),
                    };
                }
            };
            let mut client = Client::from_stream(
                Box::new(stream),
                Transport::Vsock {
                    cid: 0,
                    port: CONTROL_WIRE_VSOCK_PORT,
                },
            );
            if let Err(err) = client.handshake().await {
                return WireReport {
                    reachable: false,
                    phase: None,
                    podman_ready: None,
                    last_event: None,
                    error: Some(format!("handshake: {err}")),
                };
            }
            let seq = client.allocate_seq();
            let envelope = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq,
                body: ControlMessage::VmStatusRequest { seq },
            };
            match client.request(&envelope).await {
                Ok(reply) => match reply.body {
                    ControlMessage::VmStatusReply {
                        phase,
                        podman_ready,
                        last_event,
                        ..
                    } => WireReport {
                        reachable: true,
                        phase: Some(format!("{phase:?}")),
                        podman_ready: Some(podman_ready),
                        last_event,
                        error: None,
                    },
                    // Dispatcher returned Error (convergence packet item 2).
                    // Surface its code + message rather than just "unexpected reply".
                    ControlMessage::Error { code, message, .. } => WireReport {
                        reachable: true,
                        phase: None,
                        podman_ready: None,
                        last_event: None,
                        error: Some(describe_wire_error(code, &message)),
                    },
                    other => WireReport {
                        reachable: true,
                        phase: None,
                        podman_ready: None,
                        last_event: None,
                        error: Some(format!("unexpected reply: {}", other.kind())),
                    },
                },
                Err(err) => WireReport {
                    reachable: false,
                    phase: None,
                    podman_ready: None,
                    last_event: None,
                    error: Some(format!("VmStatusRequest: {err}")),
                },
            }
        }),
        Err(err) => WireReport {
            reachable: false,
            phase: None,
            podman_ready: None,
            last_event: None,
            error: Some(format!("tokio runtime build failed: {err}")),
        },
    };

    let recent_log_tail = std::fs::read_to_string(&log)
        .ok()
        .map(|content| {
            let lines: Vec<&str> = content.lines().collect();
            let start = lines.len().saturating_sub(20);
            lines[start..].iter().map(|s| s.to_string()).collect()
        })
        .unwrap_or_default();

    DiagnoseReport {
        // WORKSPACE_VERSION baked by build.rs from the repo-root VERSION file
        // so the JSON's `version` field matches the release tag instead of
        // the crate's static `Cargo.toml` `0.1.0`. See build.rs for details.
        version: env!("WORKSPACE_VERSION"),
        build_commit: env!("BUILD_COMMIT_SHA"),
        log_path: log.display().to_string(),
        log_exists,
        wt_present,
        distro: crate::wsl_lifecycle::DISTRO_NAME,
        distro_registered,
        release_tag: crate::wsl_lifecycle::RECIPE_RELEASE_TAG,
        manifest_pin_x86_64_tar: manifest_pin,
        wire,
        recent_log_tail,
    }
}

fn print_human(r: &DiagnoseReport) {
    println!("tillandsias-tray --diagnose");
    println!("===========================");
    println!("Version:      {}", r.version);
    println!("Build commit: {}", r.build_commit);
    println!("Log file:     {}", r.log_path);
    println!("Log exists:   {}", if r.log_exists { "yes" } else { "no" });
    println!(
        "wt.exe:       {}",
        if r.wt_present {
            "present \u{2713}"
        } else {
            "not found (bare console fallback will be used)"
        }
    );
    println!(
        "Distro `{}`:  {}",
        r.distro,
        if r.distro_registered {
            "registered \u{2713}"
        } else {
            "NOT registered (run --provision-once to provision)"
        }
    );
    println!("Release tag:  {}", r.release_tag);
    println!(
        "Manifest pin: x86_64.tar {}",
        r.manifest_pin_x86_64_tar
            .as_deref()
            .map(|sha| format!("{sha}\u{2026}"))
            .unwrap_or_else(|| "(not found / parse skipped)".to_string())
    );
    match (
        &r.wire.reachable,
        r.wire.phase.as_deref(),
        r.wire.podman_ready,
    ) {
        (true, Some("Ready"), Some(podman)) => {
            println!("Control wire: REACHABLE, phase=Ready, podman_ready={podman}");
            println!(
                "Last event:   {}",
                r.wire.last_event.as_deref().unwrap_or("(none)")
            );
        }
        (true, Some(phase), Some(podman)) => {
            println!(
                "Control wire: reachable but not Ready (phase={phase}, podman_ready={podman})"
            );
        }
        _ => {
            let why = r.wire.error.as_deref().unwrap_or("(unknown)");
            println!("Control wire: unreachable ({why})");
            println!(
                "              (is the VM provisioned + running? wsl -d tillandsias --exec true)"
            );
        }
    }
    if !r.recent_log_tail.is_empty() {
        println!();
        println!(
            "--- recent log tail ({} lines) ---",
            r.recent_log_tail.len()
        );
        for line in &r.recent_log_tail {
            println!("{line}");
        }
    }
}

fn print_json(r: &DiagnoseReport) {
    // `to_string_pretty` cannot fail for a serde-derived struct.
    println!(
        "{}",
        serde_json::to_string_pretty(r).expect("serialize DiagnoseReport")
    );
}

fn exit_code_from(r: &DiagnoseReport) -> i32 {
    let fully_healthy =
        r.distro_registered && r.wire.reachable && r.wire.phase.as_deref() == Some("Ready");
    if fully_healthy { 0 } else { 2 }
}

/// Set by the `Retry` menu click (in the wndproc) and drained by the message
/// loop, which spawns a fresh provisioning task in the LocalSet context.
static RETRY_REQUESTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// True while a provisioning task is running or has succeeded (and is parked
/// holding the VM keepalive). Guards `spawn_provisioning` so a `Retry` while
/// provisioning is already in flight — or already Ready — is a no-op; it's
/// cleared only when a provisioning attempt fails, re-enabling `Retry`.
static PROVISIONING_ACTIVE: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// Spawn the WSL recipe-provisioning task on the current LocalSet: fetch the
/// CI-published rootfs from the embedded manifest → `wsl --import` → systemd →
/// HvSocket control-wire handshake (proven E2E on real hardware 2026-05-26).
/// On success it flips the status to Ready and parks holding a VM keepalive
/// (WSL2 idles the utility VM down otherwise, dropping the control wire). On
/// failure it clears `PROVISIONING_ACTIVE` so `Retry` can try again.
///
/// Idempotent: a (re)trigger while a task is already active/parked is ignored.
fn spawn_provisioning(hwnd: HWND) {
    use std::sync::atomic::Ordering::SeqCst;
    if PROVISIONING_ACTIVE.swap(true, SeqCst) {
        tracing::info!("provisioning already active; ignoring (re)trigger");
        return;
    }
    let progress = std::sync::Arc::new(TrayProgress::new(hwnd));
    let lifecycle = WslLifecycle::new();
    tokio::task::spawn_local(async move {
        match lifecycle.provision_via_recipe(progress).await {
            Ok(()) => {
                tracing::info!("VM ready — control wire established");
                update_status_text("\u{1F7E2} Ready", hwnd);
                // Parking this task holds `_keepalive` for the tray's lifetime;
                // on Quit the LocalSet drops the task → kill_on_drop releases the
                // VM to idle normally again. PROVISIONING_ACTIVE stays set (Ready),
                // so Retry is a no-op while the VM is up.
                match lifecycle.spawn_keepalive() {
                    Ok(_keepalive) => {
                        tracing::info!("VM keepalive holding the control wire warm");
                        // Live status: poll VmStatus every tick (30 s) so the
                        // menu reflects real VM health — podman_ready gates
                        // per-project actions, and the status line tracks phase
                        // (Ready/Draining/Stopping). Refresh cloud projects on
                        // the first tick + every 10 ticks (~5 min) since
                        // `gh repo list` is a slower-changing input than VM
                        // status. Holds `_keepalive` for the tray's lifetime; on
                        // Quit the LocalSet drops the task → kill_on_drop.
                        let mut tick: u32 = 0;
                        loop {
                            refresh_vm_status(hwnd).await;
                            // Slower polls every 10 ticks (~5 min). Local fs
                            // walks are virtually free vs `gh repo list`, so
                            // run local first to keep the menu fresh fast.
                            // Order mirrors macOS slice 19 (`06088c41`).
                            if tick.is_multiple_of(10) {
                                refresh_local_projects(hwnd).await;
                                refresh_cloud_projects(hwnd).await;
                            }
                            tick = tick.wrapping_add(1);
                            tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                        }
                    }
                    Err(err) => {
                        eprintln!("VM keepalive spawn failed: {err}");
                        update_status_text("\u{1F7E1} Ready (VM may idle out)", hwnd);
                        // No keepalive to hold; still surface one live status read.
                        refresh_vm_status(hwnd).await;
                    }
                }
            }
            Err(err) => {
                eprintln!("WSL recipe provisioning failed: {err}");
                update_status_text("\u{1F534} Provisioning failed (Retry to try again)", hwnd);
                // Win11 surfaces this as a toast in the Action Center, so the
                // failure doesn't just sit invisibly in the tray icon waiting
                // for the user to mouseover. Clicking the toast brings the
                // tray to the foreground; the user picks Retry from the menu.
                show_balloon(
                    hwnd,
                    "Tillandsias \u{2014} provisioning failed",
                    &format!("{err}\n\nRight-click the tray icon \u{2192} Retry to try again."),
                    BalloonSeverity::Error,
                );
                // Re-enable Retry.
                PROVISIONING_ACTIVE.store(false, SeqCst);
            }
        }
    });
}

/// Whether the tray should drive WSL provisioning on launch. Dev mode disables
/// it via the `--no-provision` CLI flag or `TILLANDSIAS_NO_PROVISION` env var,
/// so the menu can be exercised locally without a VM or any downloads.
fn provisioning_enabled() -> bool {
    let env_skip = std::env::var_os("TILLANDSIAS_NO_PROVISION").is_some();
    let arg_skip = std::env::args().any(|a| a == "--no-provision");
    !(env_skip || arg_skip)
}

unsafe fn create_message_window() -> windows::core::Result<HWND> {
    let instance = GetModuleHandleW(None)?;
    let class_name = w!("TillandsiasTrayClass");

    let wnd_class = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        lpfnWndProc: Some(wndproc),
        hInstance: instance.into(),
        lpszClassName: class_name,
        hbrBackground: HBRUSH::default(),
        ..Default::default()
    };
    let atom = RegisterClassExW(&wnd_class);
    if atom == 0 {
        return Err(windows::core::Error::from_win32());
    }

    let hwnd = CreateWindowExW(
        WS_EX_TOOLWINDOW,
        class_name,
        w!("tillandsias-tray"),
        Default::default(),
        0,
        0,
        0,
        0,
        HWND::default(),
        HMENU::default(),
        instance,
        None,
    )?;

    // Register WM_TASKBARCREATED so we can re-add the icon when explorer
    // restarts. Per Win32 docs, the broadcast ID is registered once per
    // process via RegisterWindowMessageW.
    let _msg = RegisterWindowMessageW(w!("TaskbarCreated"));

    Ok(hwnd)
}

unsafe fn add_tray_icon(hwnd: HWND) -> windows::core::Result<()> {
    // Load the embedded tillandsias icon: resource ID 1 (`1 ICON
    // "tillandsias.ico"` in assets/tillandsias.rc, compiled by build.rs via
    // embed-resource). Fall back to the generic application icon if the
    // resource is absent (e.g. a build where the .rc was not compiled), so the
    // tray always has a glyph. @trace spec:windows-native-tray (w1)
    let instance = GetModuleHandleW(None)?;
    let hinst: HINSTANCE = instance.into();
    // MAKEINTRESOURCE(1): an integer resource id encoded as a pointer-sized
    // sentinel (never dereferenced by the loader). `without_provenance`
    // expresses that precisely and avoids clippy's manual-dangling-ptr lint.
    let icon = LoadIconW(hinst, PCWSTR(std::ptr::without_provenance::<u16>(1)))
        .or_else(|_| LoadIconW(None, IDI_APPLICATION))?;
    let mut nid: NOTIFYICONDATAW = std::mem::zeroed();
    nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
    nid.hWnd = hwnd;
    nid.uID = TRAY_ICON_ID;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = WM_TRAYICON;
    nid.hIcon = icon;
    write_utf16_into(&mut nid.szTip, "Tillandsias");
    let ok = Shell_NotifyIconW(NIM_ADD, &nid);
    if !ok.as_bool() {
        return Err(windows::core::Error::from_win32());
    }
    Ok(())
}

extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe {
        // Recompute WM_TASKBARCREATED per-call; cheap and avoids a static
        // OnceCell. The Win32 docs say the message ID is stable per session.
        let wm_taskbarcreated = RegisterWindowMessageW(w!("TaskbarCreated"));

        match msg {
            WM_DESTROY => {
                PostQuitMessage(0);
                LRESULT(0)
            }
            m if m == wm_taskbarcreated => {
                // Explorer restarted; re-add the icon.
                let _ = add_tray_icon(hwnd);
                LRESULT(0)
            }
            WM_TRAYICON => {
                let event = (lparam.0 & 0xFFFF) as u32;
                if event == WM_RBUTTONUP || event == WM_LBUTTONUP {
                    show_context_menu(hwnd);
                }
                LRESULT(0)
            }
            WM_COMMAND => {
                let cmd_id = (wparam.0 & 0xFFFF) as u16;
                handle_menu_command(hwnd, cmd_id);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
}

unsafe fn show_context_menu(hwnd: HWND) {
    // Rebuild menu from current state.
    let menu = {
        let guard = MENU_STATE.lock().unwrap();
        match guard.as_ref() {
            Some(state) => menu_state::build(state),
            None => MenuStructure::initial_provisioning(),
        }
    };

    let mut table = HashMap::<u16, String>::new();
    let hmenu = match build_popup_menu(menu.top_items(), MENU_ID_BASE, &mut table) {
        Ok(h) => h,
        Err(err) => {
            eprintln!("failed to build popup menu: {err:?}");
            return;
        }
    };
    MENU_ID_TABLE.with(|t| *t.borrow_mut() = table);
    CURRENT_MENU.with(|c| *c.borrow_mut() = menu);

    let mut pt = POINT::default();
    let _ = GetCursorPos(&mut pt);
    // Required so the menu dismisses correctly when the user clicks
    // elsewhere — see KB135788.
    let _ = SetForegroundWindow(hwnd);
    let _ = TrackPopupMenu(
        hmenu,
        TPM_LEFTALIGN | TPM_BOTTOMALIGN | TPM_RIGHTBUTTON,
        pt.x,
        pt.y,
        0,
        hwnd,
        None,
    );
    let _ = PostMessageW(hwnd, 0, WPARAM(0), LPARAM(0));
    let _ = DestroyMenu(hmenu);
}

/// Build a Win32 popup menu from a portable item list. Returns the freshly
/// created `HMENU` (caller owns and destroys). `next_id` is a counter that
/// allocates fresh u16 command IDs as we walk the tree.
unsafe fn build_popup_menu(
    items: &[MenuItem],
    base_id: u16,
    table: &mut HashMap<u16, String>,
) -> windows::core::Result<HMENU> {
    let hmenu = CreatePopupMenu()?;
    let mut next_id = base_id;
    for item in items {
        append_item(hmenu, item, &mut next_id, table)?;
    }
    Ok(hmenu)
}

unsafe fn append_item(
    parent: HMENU,
    item: &MenuItem,
    next_id: &mut u16,
    table: &mut HashMap<u16, String>,
) -> windows::core::Result<()> {
    let label = to_utf16(&item.label);
    let label_pcwstr = PCWSTR(label.as_ptr());

    if !item.children.is_empty() {
        // Submenu — recurse and use MF_POPUP.
        let sub = CreatePopupMenu()?;
        for child in &item.children {
            append_item(sub, child, next_id, table)?;
        }
        let mut flags = MF_STRING | MF_POPUP;
        if !item.enabled {
            flags |= MF_GRAYED | MF_DISABLED;
        }
        AppendMenuW(parent, flags, sub.0 as usize, label_pcwstr)?;
    } else {
        let cmd_id = if item.id == "quit" {
            MENU_ID_QUIT
        } else {
            let id = *next_id;
            *next_id = next_id.checked_add(1).unwrap_or(MENU_ID_BASE);
            id
        };
        let mut flags = MF_STRING;
        if !item.enabled {
            flags |= MF_GRAYED | MF_DISABLED;
        }
        if item.checked {
            flags |= MF_CHECKED;
        }
        AppendMenuW(parent, flags, cmd_id as usize, label_pcwstr)?;
        table.insert(cmd_id, item.id.clone());
    }
    Ok(())
}

fn to_utf16(s: &str) -> Vec<u16> {
    OsString::from(s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

unsafe fn handle_menu_command(hwnd: HWND, cmd_id: u16) {
    // Recover the portable string id for this Win32 command id. The Quit
    // leaf has a fixed command id and is not always present in the per-paint
    // table, so map it explicitly.
    let logical_id = if cmd_id == MENU_ID_QUIT {
        menu_state::ids::QUIT.to_string()
    } else {
        MENU_ID_TABLE.with(|t| t.borrow().get(&cmd_id).cloned().unwrap_or_default())
    };
    if logical_id.is_empty() {
        return;
    }
    let action = menu_action::resolve(&logical_id);
    tracing::info!(menu_id = %logical_id, action = ?action, "tray menu click");
    dispatch_action(hwnd, action);
}

/// Apply a host-side project scan event to the shared menu state.
fn apply_project_event(ev: ProjectEvent) {
    if let Ok(mut guard) = MENU_STATE.lock() {
        let state = guard.get_or_insert_with(fresh_menu_state);
        apply_project_event_to(state, &ev);
    }
}

/// Pure update rule for a project scan event — factored out of the global so
/// the dedup / sort / removal behaviour is unit-testable without Win32.
///
/// `Added` inserts a `local` [`ProjectEntry`] (deduped by directory basename,
/// kept name-sorted); `Removed` drops it. Paths with no usable basename are
/// ignored.
///
/// @trace spec:host-shell-architecture.scanner.local-project-discovery@v1
fn apply_project_event_to(state: &mut MenuState, ev: &ProjectEvent) {
    match ev {
        ProjectEvent::Added { path } => {
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                return;
            };
            if name.is_empty() || state.local_projects.iter().any(|p| p.name == name) {
                return;
            }
            state.local_projects.push(ProjectEntry {
                name: name.to_string(),
                path: path.to_string_lossy().into_owned(),
                ready: false,
            });
            state.local_projects.sort_by(|a, b| a.name.cmp(&b.name));
        }
        ProjectEvent::Removed { path } => {
            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                state.local_projects.retain(|p| p.name != name);
            }
        }
    }
}

/// Route a resolved [`MenuAction`] to its handler.
///
/// `Quit` posts `WM_DESTROY` so the message loop drains and exits on the next
/// iteration. The remaining actions need the in-VM control wire (vsock) or a
/// host-side spawn (GitHub device-flow terminal); those land in the
/// vsock-attach phase. Until then they are logged with their resolved type —
/// strictly better than the previous string special-casing, and the same
/// resolver the macOS tray will consume.
///
/// @trace spec:windows-native-tray
fn dispatch_action(hwnd: HWND, action: MenuAction) {
    match &action {
        MenuAction::Quit => unsafe {
            let _ = PostMessageW(hwnd, WM_DESTROY, WPARAM(0), LPARAM(0));
        },
        // Agent selection is fully wired: update the shared menu state so the
        // checkmark moves on the next paint.
        MenuAction::SelectAgent(agent) => {
            if let Ok(mut guard) = MENU_STATE.lock() {
                let state = guard.get_or_insert_with(fresh_menu_state);
                if apply_menu_action_state(state, &action) {
                    tracing::info!(?agent, "selected agent updated");
                }
            }
        }
        // The remaining arms are resolved + handled honestly, but their real
        // effect needs plumbing that is not present on Windows yet. Each logs
        // a specific reason rather than faking behaviour (w2 work queue).
        MenuAction::OpenObservatorium | MenuAction::OpenOpenCodeWeb => {
            // ShellExecute to the observatorium / OpenCode-Web URL lands with
            // the router/VM (gui-passthrough); there is no URL until then.
            tracing::info!(
                ?action,
                "browser action: no URL until the VM + router are up (gui-passthrough pending)"
            );
        }
        MenuAction::Retry => {
            // The message loop owns the LocalSet; it spawns the new provisioning
            // task on the next drain (right after this click is dispatched).
            if PROVISIONING_ACTIVE.load(std::sync::atomic::Ordering::SeqCst) {
                tracing::info!("retry ignored: provisioning already active / VM Ready");
            } else {
                tracing::info!("retry requested: re-triggering provisioning");
                RETRY_REQUESTED.store(true, std::sync::atomic::Ordering::SeqCst);
                update_status_text("\u{1F504} Retrying provisioning\u{2026}", hwnd);
            }
        }
        MenuAction::OpenLog => {
            tracing::info!(log = %log_file_path().display(), "opening tray log in Explorer");
            open_log_file();
        }
        // Attach / Maintain / GitHub-login all open an in-VM PTY. `intent_for_action`
        // picks the `PtyIntent`; `launch_spec` produces the exact forge-wrapped in-VM
        // argv; then we open it in a native Windows terminal via `wsl.exe`.
        MenuAction::Attach { .. } | MenuAction::Maintain { .. } | MenuAction::GithubLogin => {
            launch_open_shell_terminal(&action);
        }
        MenuAction::CloudOverflow | MenuAction::Inert => {}
    }
}

/// The currently selected coding agent, read from the shared menu state.
/// Defaults to the menu's initial agent if the state is not yet populated.
fn selected_agent() -> SelectedAgent {
    MENU_STATE
        .lock()
        .ok()
        .and_then(|g| g.as_ref().map(|s| s.selected_agent))
        .unwrap_or_else(|| fresh_menu_state().selected_agent)
}

/// Open a PTY-opening menu action (Attach / Maintain / GitHub-login) in a native
/// Windows terminal. `intent_for_action` → `launch_spec` resolve the exact
/// forge-wrapped in-VM argv (a project click → `podman exec -it
/// tillandsias-<proj>-forge …`; no project → the bare VM shell), and we hand
/// that argv to `wsl.exe -d <distro> --` inside a terminal window.
///
/// Per the cross-host agreement (tray-convergence-coordination.md: "Transport/UX
/// is per-OS — each tray uses its native terminal affordance; no need to
/// converge"), Windows uses `wsl.exe`'s built-in console↔in-VM-PTY bridge rather
/// than pumping a ConPTY over HvSocket. The *shell argv* is what converges with
/// the macOS Terminal.app path — both land in the same forge-container shell.
///
/// @trace plan/issues/tray-convergence-coordination.md (Open Shell — per-OS terminal, shared argv)
fn launch_open_shell_terminal(action: &MenuAction) {
    let Some((intent, project)) = intent_for_action(action, selected_agent()) else {
        tracing::warn!(?action, "no PTY intent for action (unexpected in this arm)");
        return;
    };
    // Default geometry until the tray owns a real terminal surface to size from.
    let spec = launch_spec(&intent, project.as_deref(), 24, 80);
    let distro = crate::wsl_lifecycle::DISTRO_NAME;
    let title = match project.as_deref() {
        Some(p) => format!("Tillandsias \u{2014} {p}"),
        None => "Tillandsias shell".to_string(),
    };
    match spawn_wsl_terminal(distro, &title, &spec.argv) {
        Ok(()) => tracing::info!(?intent, project = ?project, argv = ?spec.argv,
            "opened in-VM PTY in a native terminal (wsl.exe)"),
        Err(err) => tracing::warn!(%err, ?intent, project = ?project,
            "failed to open terminal for in-VM PTY"),
    }
}

/// Build the Windows Terminal (`wt.exe`) argv that opens `in_vm_argv` in the VM
/// via `wsl.exe -d <distro> --`, in a titled new tab. Pure + testable; the spawn
/// wrapper feeds this to `wt.exe` (with a bare-console fallback if wt is absent).
fn wt_terminal_argv(distro: &str, title: &str, in_vm_argv: &[String]) -> Vec<String> {
    let mut v = vec![
        "new-tab".to_string(),
        "--title".to_string(),
        title.to_string(),
        "wsl.exe".to_string(),
        "-d".to_string(),
        distro.to_string(),
        "--".to_string(),
    ];
    v.extend(in_vm_argv.iter().cloned());
    v
}

/// Open `in_vm_argv` in a native Windows terminal attached to the WSL2 distro.
/// Prefers Windows Terminal (`wt.exe`, ships with Win11); if it can't be spawned
/// (older host / not installed), falls back to `wsl.exe` in its own new console.
fn spawn_wsl_terminal(distro: &str, title: &str, in_vm_argv: &[String]) -> std::io::Result<()> {
    use std::process::Command;
    // CREATE_NEW_CONSOLE — the fallback `wsl.exe` gets its own console window
    // instead of inheriting the (hidden) tray process console.
    const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;

    match Command::new("wt.exe")
        .args(wt_terminal_argv(distro, title, in_vm_argv))
        .spawn()
    {
        Ok(_) => Ok(()),
        Err(_) => {
            // Fallback: bare `wsl.exe` in a fresh console.
            Command::new("wsl.exe")
                .arg("-d")
                .arg(distro)
                .arg("--")
                .args(in_vm_argv)
                .creation_flags(CREATE_NEW_CONSOLE)
                .spawn()
                .map(|_| ())
        }
    }
}

/// Apply the state-mutating effect of a menu action to the menu state.
/// Currently only agent selection mutates state; returns `true` if `state`
/// changed. Factored out of the global `MENU_STATE` so the rule is unit-testable.
///
/// @trace spec:windows-native-tray
fn apply_menu_action_state(state: &mut MenuState, action: &MenuAction) -> bool {
    match action {
        MenuAction::SelectAgent(agent) if state.selected_agent != *agent => {
            state.selected_agent = *agent;
            true
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Sanity: WM_TRAYICON is in the WM_APP private range so it cannot
    /// collide with system messages.
    #[test]
    fn wm_trayicon_is_in_app_range() {
        // Both are consts, so enforce the invariant at compile time.
        const { assert!(WM_TRAYICON >= WM_APP) };
    }

    /// `describe_wire_error` is the tray-side surface for the convergence
    /// packet's Error{Unsupported,…} replies (5c67ddb9, aeb5499a). Operators
    /// must see the dispatcher's code + message, not a silent fall-through.
    #[test]
    fn describe_wire_error_includes_code_and_message() {
        use tillandsias_control_wire::ErrorCode;
        let s = describe_wire_error(ErrorCode::Unsupported, "variant X not wired on vsock");
        assert!(s.contains("Unsupported"), "code missing: {s}");
        assert!(
            s.contains("variant X not wired on vsock"),
            "message missing: {s}"
        );
    }

    #[test]
    fn describe_wire_error_handles_empty_message() {
        use tillandsias_control_wire::ErrorCode;
        let s = describe_wire_error(ErrorCode::Internal, "");
        assert!(s.contains("Internal"));
        assert!(
            !s.contains(": "),
            "empty message must not leave a dangling colon: {s}"
        );
    }

    /// Pin the `--diagnose --json` schema so support tooling consuming the
    /// machine-readable output never breaks silently. The five tests below
    /// catch (a) renamed / removed top-level keys, (b) renamed / removed
    /// nested `wire.*` keys, (c) the `manifest_pin_x86_64_tar` Option being
    /// (de)serialized in an unexpected way, (d) `recent_log_tail` ceasing to
    /// be an array. A schema change here is a schema change for tooling —
    /// adjust both deliberately together.
    fn baseline_diagnose_report() -> DiagnoseReport {
        DiagnoseReport {
            version: "0.0.0-test",
            build_commit: "deadbeef",
            log_path: "C:\\path\\to\\tray.log".to_string(),
            log_exists: false,
            wt_present: true,
            distro: "tillandsias",
            distro_registered: false,
            release_tag: "v0.0.0",
            manifest_pin_x86_64_tar: Some("abcdef123456".to_string()),
            wire: WireReport {
                reachable: false,
                phase: None,
                podman_ready: None,
                last_event: None,
                error: Some("not provisioned".to_string()),
            },
            recent_log_tail: vec![],
        }
    }

    #[test]
    fn diagnose_json_top_level_keys_pinned() {
        let v: serde_json::Value =
            serde_json::to_value(baseline_diagnose_report()).expect("serialize");
        let obj = v.as_object().expect("top-level JSON object");
        for key in [
            "version",
            "build_commit",
            "log_path",
            "log_exists",
            "wt_present",
            "distro",
            "distro_registered",
            "release_tag",
            "manifest_pin_x86_64_tar",
            "wire",
            "recent_log_tail",
        ] {
            assert!(
                obj.contains_key(key),
                "diagnose --json missing top-level key: {key}"
            );
        }
    }

    #[test]
    fn diagnose_json_wire_object_keys_pinned() {
        let v: serde_json::Value =
            serde_json::to_value(baseline_diagnose_report()).expect("serialize");
        let wire = v
            .get("wire")
            .and_then(|w| w.as_object())
            .expect("wire object");
        for key in ["reachable", "phase", "podman_ready", "last_event", "error"] {
            assert!(
                wire.contains_key(key),
                "diagnose --json wire object missing key: {key}"
            );
        }
    }

    #[test]
    fn diagnose_json_manifest_pin_some_serializes_as_string() {
        let mut r = baseline_diagnose_report();
        r.manifest_pin_x86_64_tar = Some("a28cabe7c9df".to_string());
        let v: serde_json::Value = serde_json::to_value(r).expect("serialize");
        assert_eq!(
            v["manifest_pin_x86_64_tar"],
            serde_json::Value::String("a28cabe7c9df".to_string())
        );
    }

    #[test]
    fn diagnose_json_manifest_pin_none_serializes_as_null() {
        let mut r = baseline_diagnose_report();
        r.manifest_pin_x86_64_tar = None;
        let v: serde_json::Value = serde_json::to_value(r).expect("serialize");
        assert_eq!(v["manifest_pin_x86_64_tar"], serde_json::Value::Null);
    }

    /// The `--diagnose` / `--diagnose --json` exit code is a public contract
    /// (0 = fully healthy, 2 = degraded). Pins it so a future refactor cannot
    /// silently flip "degraded" to "ok" or vice-versa for support scripts that
    /// trigger on the exit code (e.g. `scripts/tray-diagnose.ps1`).
    #[test]
    fn exit_code_provisioned_zero_degraded_two() {
        // Fully healthy: distro registered AND wire reachable AND phase Ready.
        let mut healthy = baseline_diagnose_report();
        healthy.distro_registered = true;
        healthy.wire = WireReport {
            reachable: true,
            phase: Some("Ready".to_string()),
            podman_ready: Some(true),
            last_event: None,
            error: None,
        };
        assert_eq!(exit_code_from(&healthy), 0, "fully healthy -> 0");

        // Baseline (no distro, no wire) -> 2.
        assert_eq!(exit_code_from(&baseline_diagnose_report()), 2);

        // Distro only (wire still unreachable) -> 2.
        let mut deg = baseline_diagnose_report();
        deg.distro_registered = true;
        assert_eq!(exit_code_from(&deg), 2, "distro only -> 2");

        // Wire reachable but phase != Ready -> 2.
        deg.wire = WireReport {
            reachable: true,
            phase: Some("Starting".to_string()),
            podman_ready: Some(false),
            last_event: None,
            error: None,
        };
        assert_eq!(exit_code_from(&deg), 2, "phase != Ready -> 2");
    }

    #[test]
    fn diagnose_json_recent_log_tail_is_array() {
        let mut r = baseline_diagnose_report();
        r.recent_log_tail = vec!["line one".to_string(), "line two".to_string()];
        let v: serde_json::Value = serde_json::to_value(r).expect("serialize");
        let tail = v["recent_log_tail"]
            .as_array()
            .expect("recent_log_tail array");
        assert_eq!(tail.len(), 2);
        assert_eq!(tail[0], serde_json::Value::String("line one".to_string()));
    }

    /// The tray menu's version footer text ("v<VERSION> — By Tlatoāni") is
    /// fed from `MenuState.version`. `tillandsias-host-shell::MenuState::initial`
    /// fills that from `env!("CARGO_PKG_VERSION")` (the host-shell crate's
    /// static `Cargo.toml` "0.1.0"), so without our override the footer
    /// renders "v0.1.0 — …" instead of the release tag the user actually
    /// installed. `fresh_menu_state()` overrides the field with the
    /// workspace VERSION baked at build time (`WORKSPACE_VERSION` from
    /// `build.rs`). Pin so a future refactor that removes the override
    /// surfaces here pre-build instead of as a UX regression.
    #[test]
    fn fresh_menu_state_footer_reports_workspace_version() {
        let state = fresh_menu_state();
        assert_eq!(
            state.version,
            env!("WORKSPACE_VERSION"),
            "fresh_menu_state must inject WORKSPACE_VERSION (was {})",
            state.version
        );
        // Sanity: not the crate-static placeholder.
        assert_ne!(
            state.version, "0.1.0",
            "footer is still rendering CARGO_PKG_VERSION — workspace override regressed"
        );
    }

    fn baseline_status_report() -> StatusReport {
        StatusReport {
            reachable: false,
            wire_version: None,
            phase: None,
            podman_ready: None,
            last_event: None,
            error: Some("not provisioned".to_string()),
            exit_code: 1,
        }
    }

    /// Pin the `--status-once --json` top-level key set so a future refactor
    /// that drops or renames a field surfaces here, not at the support-tooling
    /// step. Mirrors `diagnose_json_top_level_keys_pinned` for the StatusReport
    /// shape. Bound by `litmus:windows-tray-diagnose-cli-surface`.
    #[test]
    fn status_once_json_keys_pinned() {
        let v: serde_json::Value =
            serde_json::to_value(baseline_status_report()).expect("serialize");
        let obj = v.as_object().expect("top-level JSON object");
        for key in [
            "reachable",
            "wire_version",
            "phase",
            "podman_ready",
            "last_event",
            "error",
            "exit_code",
        ] {
            assert!(
                obj.contains_key(key),
                "status-once --json missing top-level key: {key}"
            );
        }
    }

    /// `--status-once` exit-code contract (independent of the `--diagnose`
    /// matrix; same semantics as the human-mode bash-script consumer expects):
    /// 0 = Ready, 2 = reachable-but-not-Ready, 1 = unreachable. Pins the
    /// matrix so a refactor can't silently flip the codes for the support
    /// scripts that branch on them.
    #[test]
    fn status_once_exit_codes() {
        // Unreachable → 1.
        let mut r = baseline_status_report();
        assert_eq!(status_exit_code(&r), 1, "unreachable -> 1");

        // Reachable, phase Ready → 0.
        r.reachable = true;
        r.phase = Some("Ready".to_string());
        assert_eq!(status_exit_code(&r), 0, "Ready -> 0");

        // Reachable, phase non-Ready → 2.
        r.phase = Some("Starting".to_string());
        assert_eq!(status_exit_code(&r), 2, "non-Ready phase -> 2");

        // Reachable, phase absent (e.g. unexpected reply variant) → 1.
        r.phase = None;
        assert_eq!(status_exit_code(&r), 1, "reachable but no phase -> 1");
    }

    /// The chip composer appends a non-empty `last_event` after a Unicode
    /// MIDDLE DOT so the user sees in-VM activity in the tray. `None` or
    /// whitespace-only events leave the base phase line untouched.
    #[test]
    fn compose_chip_text_appends_last_event() {
        // None → bare base.
        assert_eq!(
            compose_chip_text("\u{1F7E2} Ready", None),
            "\u{1F7E2} Ready"
        );
        // Empty / whitespace → bare base (don't print a dangling separator).
        assert_eq!(
            compose_chip_text("\u{1F7E2} Ready", Some("")),
            "\u{1F7E2} Ready"
        );
        assert_eq!(
            compose_chip_text("\u{1F7E2} Ready", Some("   ")),
            "\u{1F7E2} Ready"
        );
        // Some(non-empty) → "<base> · <evt>".
        let out = compose_chip_text("\u{1F7E2} Ready", Some("forge-foo created"));
        assert!(out.starts_with("\u{1F7E2} Ready"));
        assert!(out.contains('\u{00B7}'));
        assert!(out.ends_with("forge-foo created"));
    }

    /// The manifest-pin parser reads `"x86_64.tar" = "<sha>"` out of the
    /// `[output.expected_rootfs_sha]` table — the actual shape recipe-publish
    /// emits — and returns the first 12 hex chars.
    #[test]
    fn parses_quoted_key_sha_form() {
        let manifest = r#"
[output.expected_rootfs_sha]
"x86_64.tar"  = "a28cabe7c9dfcf58e8a2c63d1885d968c5abbc4719c7e89152d4c5e492d38e99"
"aarch64.tar" = "a8435ed1a0c9294e9ca9f060eaacc3f059662908040037dec330d71a1b5f3028"
"#;
        assert_eq!(
            parse_rootfs_sha_pin(manifest, "x86_64.tar"),
            Some("a28cabe7c9df".to_string())
        );
    }

    /// Tolerate the bare-key form too (TOML accepts unquoted keys with only
    /// `[A-Za-z0-9_-]` plus dots; future manifest authors might drop the
    /// quotes on the simple arch keys).
    #[test]
    fn parses_bare_key_sha_form() {
        let manifest =
            "x86_64.tar  = \"a28cabe7c9dfcf58e8a2c63d1885d968c5abbc4719c7e89152d4c5e492d38e99\"\n";
        assert_eq!(
            parse_rootfs_sha_pin(manifest, "x86_64.tar"),
            Some("a28cabe7c9df".to_string())
        );
    }

    /// `"pending-ci"` (or any non-hex placeholder) MUST NOT parse as a pin —
    /// the report should show "(not found / parse skipped)" instead of printing
    /// garbage. The `>= 12 hex chars` gate makes this safe by construction.
    #[test]
    fn refuses_placeholder_pending_ci() {
        let manifest = r#"
[output.expected_rootfs_sha]
"x86_64.tar" = "pending-ci"
"#;
        assert!(parse_rootfs_sha_pin(manifest, "x86_64.tar").is_none());
    }

    /// Pin the wire-unreachable chip text so a future refactor (emoji swap,
    /// wording edit, localization) can't silently break the cross-tray UX
    /// parity invariant. Identical-named to macOS slice 23 (`cbeedb4a`); same
    /// three assertions — byte sequence, total length, leading codepoint.
    #[test]
    fn wire_unreachable_chip_text_pinned() {
        assert_eq!(WIRE_UNREACHABLE_CHIP_TEXT, "\u{1F534} Wire unreachable");
        assert_eq!(
            WIRE_UNREACHABLE_CHIP_TEXT.len(),
            21,
            "byte length drift: {} bytes",
            WIRE_UNREACHABLE_CHIP_TEXT.len()
        );
        assert_eq!(
            WIRE_UNREACHABLE_CHIP_TEXT.chars().next(),
            Some('\u{1F534}'),
            "first char must be U+1F534 LARGE RED CIRCLE (not U+23FA or other red glyph)"
        );
    }

    /// Local `ProjectEntry.path` is the in-VM `guest_path` (per its doc) so an
    /// `Attach Here` exec lands the forge container with the right cwd. Mirrors
    /// the macOS slice 19 mapping.
    #[test]
    fn local_entry_maps_to_guest_path() {
        let entry = tillandsias_control_wire::LocalProjectEntry {
            label: "tillandsias".to_string(),
            guest_path: "/mnt/c/Users/bullo/src/tillandsias".to_string(),
            last_seen_unix: 1700000000,
        };
        let mapped = local_entry_to_menu(&entry);
        assert_eq!(mapped.name, "tillandsias");
        assert_eq!(mapped.path, "/mnt/c/Users/bullo/src/tillandsias");
        assert!(
            !mapped.ready,
            "per-project ready flag isn't on the wire yet"
        );
    }

    /// Cloud `ProjectEntry.path` is the `owner/repo` slug (per its doc) so the
    /// menu's cloud-projects submenu shows a stable, gh-style identifier.
    #[test]
    fn cloud_entry_maps_to_owner_repo_slug() {
        let entry = tillandsias_control_wire::CloudProjectEntry {
            label: "my project".to_string(),
            owner: "8007342".to_string(),
            repo: "tillandsias".to_string(),
            default_branch: "main".to_string(),
        };
        let mapped = cloud_entry_to_menu(&entry);
        assert_eq!(mapped.name, "my project");
        assert_eq!(mapped.path, "8007342/tillandsias");
        assert!(!mapped.ready, "cloud projects have no in-VM forge yet");
    }

    /// The live status line distinguishes VM phases + podman readiness, so the
    /// shared `ids::STATUS` chip reflects real VM health (Ready vs podman-starting
    /// vs draining/failed) rather than a single static "Ready".
    #[test]
    fn vm_phase_status_text_reflects_phase_and_podman() {
        use tillandsias_control_wire::VmPhase;
        assert!(vm_phase_status_text(VmPhase::Ready, true).contains("Ready"));
        // Ready-with-podman is visibly distinct from Ready-without-podman.
        assert_ne!(
            vm_phase_status_text(VmPhase::Ready, true),
            vm_phase_status_text(VmPhase::Ready, false)
        );
        assert!(
            vm_phase_status_text(VmPhase::Draining, true)
                .to_lowercase()
                .contains("drain")
        );
        assert!(
            vm_phase_status_text(VmPhase::Failed, false)
                .to_lowercase()
                .contains("fail")
        );
    }

    /// The log file lives under `…\tillandsias\logs\tray.log` so "Open Log" and
    /// `init_tracing` agree on a single fixed path.
    #[test]
    fn log_file_path_is_under_tillandsias_logs() {
        let p = log_file_path();
        assert_eq!(p.file_name().unwrap(), "tray.log");
        let parent = p.parent().unwrap();
        assert_eq!(parent.file_name().unwrap(), "logs");
        assert_eq!(parent.parent().unwrap().file_name().unwrap(), "tillandsias");
    }

    /// The Open-Shell terminal argv runs the resolved in-VM argv verbatim under
    /// `wsl.exe -d <distro> --` in a titled tab — the forge-wrapped command (the
    /// part that converges with the macOS Terminal.app path) is preserved intact.
    #[test]
    fn wt_terminal_argv_wraps_in_vm_argv_under_wsl() {
        let in_vm = vec![
            "podman".to_string(),
            "exec".to_string(),
            "-it".to_string(),
            "tillandsias-foo-forge".to_string(),
            "bash".to_string(),
            "-l".to_string(),
        ];
        let argv = wt_terminal_argv("tillandsias", "Tillandsias \u{2014} foo", &in_vm);
        assert_eq!(
            argv,
            vec![
                "new-tab",
                "--title",
                "Tillandsias \u{2014} foo",
                "wsl.exe",
                "-d",
                "tillandsias",
                "--",
                "podman",
                "exec",
                "-it",
                "tillandsias-foo-forge",
                "bash",
                "-l",
            ]
        );
        // The `--` separator must precede the in-VM argv so wsl.exe runs it in
        // the guest rather than parsing it as wsl options.
        let sep = argv.iter().position(|a| a == "--").unwrap();
        assert_eq!(&argv[sep + 1..sep + 2], &["podman"]);
    }

    use std::path::PathBuf;

    fn added(p: &str) -> ProjectEvent {
        ProjectEvent::Added {
            path: PathBuf::from(p),
        }
    }

    #[test]
    fn project_added_inserts_sorted_and_deduped() {
        let mut state = fresh_menu_state();
        apply_project_event_to(&mut state, &added("C:\\Users\\u\\src\\zebra"));
        apply_project_event_to(&mut state, &added("C:\\Users\\u\\src\\apple"));
        // Duplicate basename is ignored.
        apply_project_event_to(&mut state, &added("C:\\Users\\u\\src\\apple"));

        let names: Vec<&str> = state
            .local_projects
            .iter()
            .map(|p| p.name.as_str())
            .collect();
        assert_eq!(names, vec!["apple", "zebra"], "name-sorted, deduped");
        assert!(state.local_projects.iter().all(|p| !p.ready));
    }

    #[test]
    fn select_agent_updates_state_idempotently() {
        use tillandsias_host_shell::menu_state::SelectedAgent;
        let mut state = fresh_menu_state();
        assert_eq!(state.selected_agent, SelectedAgent::Claude); // initial

        // Selecting a different agent mutates state.
        assert!(apply_menu_action_state(
            &mut state,
            &MenuAction::SelectAgent(SelectedAgent::Codex)
        ));
        assert_eq!(state.selected_agent, SelectedAgent::Codex);

        // Re-selecting the same agent is a no-op.
        assert!(!apply_menu_action_state(
            &mut state,
            &MenuAction::SelectAgent(SelectedAgent::Codex)
        ));

        // A non-state action never mutates state.
        assert!(!apply_menu_action_state(&mut state, &MenuAction::Quit));
        assert!(!apply_menu_action_state(&mut state, &MenuAction::OpenLog));
        assert_eq!(state.selected_agent, SelectedAgent::Codex);
    }

    #[test]
    fn project_removed_drops_entry() {
        let mut state = fresh_menu_state();
        apply_project_event_to(&mut state, &added("C:\\Users\\u\\src\\keep"));
        apply_project_event_to(&mut state, &added("C:\\Users\\u\\src\\drop"));
        apply_project_event_to(
            &mut state,
            &ProjectEvent::Removed {
                path: PathBuf::from("C:\\Users\\u\\src\\drop"),
            },
        );
        let names: Vec<&str> = state
            .local_projects
            .iter()
            .map(|p| p.name.as_str())
            .collect();
        assert_eq!(names, vec!["keep"]);
    }
}
