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
    NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NIM_MODIFY, NOTIFYICONDATAW,
    Shell_NotifyIconW,
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
    fn report_message(&self, _message: &str) {
        // Sub-messages are not surfaced in the menu per the condensed-
        // status contract; we drop them silently. The provisioning log
        // captures the full detail.
    }
}

fn update_status_text(text: &str, hwnd: HWND) {
    if let Ok(mut guard) = MENU_STATE.lock() {
        if let Some(state) = guard.as_mut() {
            state.status_text = text.to_string();
        } else {
            let mut state = MenuState::initial();
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
            *guard = Some(MenuState::initial());
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

/// Headless diagnostic entry point (`tillandsias-tray --status-once`): connect to
/// an already-provisioned VM's HvSocket control wire, request `VmStatus`, and
/// print the phase / podman_ready / last_event. Exit code: 0 = Ready, 2 =
/// reachable but not Ready, 1 = control wire unreachable. Pairs with
/// `--provision-once` for scriptable installed-tray health checks (the GUI tray
/// has no console). Reuses the same handshake + `VmStatusRequest` path the
/// provisioning Connecting loop uses.
pub fn status_once() -> i32 {
    use tillandsias_control_wire::{ControlMessage, VmPhase};

    init_tracing();
    let port = tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(err) => {
            eprintln!("[status] failed to build tokio runtime: {err}");
            return 1;
        }
    };
    runtime.block_on(async {
        use tillandsias_control_wire::transport::Transport;
        use tillandsias_control_wire::{ControlEnvelope, WIRE_VERSION};
        use tillandsias_host_shell::vsock_client::Client;

        let stream = match crate::hvsocket::open_hvsocket_stream(port).await {
            Ok(stream) => stream,
            Err(err) => {
                eprintln!("[status] control wire unreachable on vsock {port}: {err}");
                eprintln!("[status] (is the VM provisioned + running? try --provision-once)");
                return 1;
            }
        };
        let mut client = Client::from_stream(Box::new(stream), Transport::Vsock { cid: 0, port });
        let wire_version = match client.handshake().await {
            Ok(v) => v,
            Err(err) => {
                eprintln!("[status] handshake failed: {err}");
                return 1;
            }
        };
        println!("[status] control wire up (wire_version {wire_version})");
        let seq = client.allocate_seq();
        let envelope = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
            body: ControlMessage::VmStatusRequest { seq },
        };
        let reply = match client.request(&envelope).await {
            Ok(reply) => reply,
            Err(err) => {
                eprintln!("[status] VmStatusRequest failed: {err}");
                return 1;
            }
        };
        match reply.body {
            ControlMessage::VmStatusReply {
                phase,
                podman_ready,
                last_event,
                ..
            } => {
                println!("[status] phase:        {phase:?}");
                println!("[status] podman_ready: {podman_ready}");
                println!(
                    "[status] last_event:   {}",
                    last_event.as_deref().unwrap_or("(none)")
                );
                if matches!(phase, VmPhase::Ready) {
                    0
                } else {
                    2
                }
            }
            other => {
                eprintln!("[status] unexpected reply to VmStatusRequest: {other:?}");
                1
            }
        }
    })
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
            return;
        }
    };
    if let ControlMessage::VmStatusReply {
        phase,
        podman_ready,
        ..
    } = reply.body
    {
        if let Ok(mut guard) = MENU_STATE.lock() {
            guard.get_or_insert_with(MenuState::initial).podman_ready = podman_ready;
        }
        // status_text + tooltip (own MENU_STATE lock inside).
        update_status_text(&vm_phase_status_text(phase, podman_ready), hwnd);
        tracing::debug!(?phase, podman_ready, "vm status polled");
    }
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
                        // Live status: poll VmStatus so the menu reflects real VM
                        // health — podman_ready gates per-project actions, and the
                        // status line tracks phase (Ready/Draining/Stopping).
                        // This loop holds `_keepalive` for the tray's lifetime; on
                        // Quit the LocalSet drops the task → kill_on_drop.
                        loop {
                            refresh_vm_status(hwnd).await;
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
        let state = guard.get_or_insert_with(MenuState::initial);
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
                let state = guard.get_or_insert_with(MenuState::initial);
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
        .unwrap_or_else(|| MenuState::initial().selected_agent)
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
        let mut state = MenuState::initial();
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
        let mut state = MenuState::initial();
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
        let mut state = MenuState::initial();
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
