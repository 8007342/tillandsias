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

        // Spawn the WSL provisioning + lifecycle task. Progress is reported
        // via the TrayProgress sink which updates the tooltip and menu.
        let progress = std::sync::Arc::new(TrayProgress::new(hwnd));
        let lifecycle = WslLifecycle::new();
        tokio::task::spawn_local(async move {
            if let Err(err) = lifecycle.bootstrap(progress).await {
                eprintln!("WSL lifecycle bootstrap failed: {err}");
            }
        });

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
            // Cooperative tokio drain.
            tokio::task::yield_now().await;
        }

        // Clean up.
        unsafe {
            let mut nid: NOTIFYICONDATAW = std::mem::zeroed();
            nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
            nid.hWnd = hwnd;
            nid.uID = TRAY_ICON_ID;
            let _ = Shell_NotifyIconW(NIM_DELETE, &nid);
        }
        msg.wParam.0 as i32
    });
    std::process::exit(exit_code);
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
            tracing::info!(
                "retry requested: provisioning-retry hook wires with the lifecycle iteration"
            );
        }
        MenuAction::OpenLog => {
            tracing::info!("open log requested: host-side log-file path not wired yet");
        }
        // Attach / Maintain / GitHub-login all open an in-VM PTY. The click is
        // resolved end-to-end on the host side here — `intent_for_action` picks
        // the `PtyIntent`, `launch_spec` produces the exact in-VM argv — leaving
        // only the vsock `PtyOpen` send for the VM-E2E iteration.
        MenuAction::Attach { .. } | MenuAction::Maintain { .. } | MenuAction::GithubLogin => {
            resolve_and_log_pty_launch(&action);
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

/// Resolve a PTY-opening menu action to its in-VM launch spec and log it. The
/// resolution (`MenuAction` → [`intent_for_action`] → [`launch_spec`]) is the
/// full host-side path; the remaining step — sending the `PtyOpen` frame over
/// vsock and pumping the ConPTY — lands with the VM-E2E iteration (w4f).
fn resolve_and_log_pty_launch(action: &MenuAction) {
    let Some(intent) = intent_for_action(action, selected_agent()) else {
        tracing::warn!(?action, "no PTY intent for action (unexpected in this arm)");
        return;
    };
    // Default geometry until the tray owns a real terminal surface to size from.
    let spec = launch_spec(&intent, 24, 80);
    tracing::info!(
        ?intent,
        argv = ?spec.argv,
        "resolved tray click to in-VM PTY launch; vsock attach pending VM-E2E (w4f)"
    );
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
        assert!(WM_TRAYICON >= WM_APP);
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
