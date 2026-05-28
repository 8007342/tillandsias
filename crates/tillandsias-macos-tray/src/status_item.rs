//! AppKit `NSStatusItem` plumbing for the macOS tray.
//!
//! Owns the AppKit run loop, the `NSMenu` instance, and the bridge between
//! `tillandsias-host-shell` events and `NSStatusItem.button.title`. The
//! menu is built from the `MacMenuItemSpec` tree produced by the portable
//! `menu_disabled_v2::render` function; the v2-deferred items (Observatorium,
//! OpenCode Web) come in pre-tagged with `enabled = false` so we just wire
//! them up with `setEnabled(false)` and a tooltip carrying the reason.
//!
//! The status text is surfaced via `setToolTip:` on the status item's
//! button — hovering the menu bar icon reveals the current condensed
//! provisioning/ready status without having to expand the popup.
//!
//! macOS-only. The Linux dev box never compiles this module.
//!
//! @trace spec:macos-native-tray.ui.nsstatusitem-only@v1,
//!        spec:macos-native-tray.ui.menu-parity@v1
//!
//! ## Manual repro (macOS host required)
//!
//! ```bash
//! cargo run -p tillandsias-macos-tray --target aarch64-apple-darwin
//! # menu-bar icon appears within 500ms; click reveals the parity menu
//! # with Observatorium + OpenCode Web greyed out + tooltip "v2 — terminal-only in v1"
//! ```

#![allow(dead_code)]
#![allow(unused)]

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, Sel};
use objc2::{ClassType, class, msg_send_id, sel};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSMenu, NSMenuItem, NSStatusBar, NSStatusItem,
    NSVariableStatusItemLength,
};
use objc2_foundation::{MainThreadMarker, NSString};

use crate::action_host::TrayActionHost;
use crate::menu_disabled_v2::{MacMenuItemSpec, render};
use tillandsias_host_shell::menu_state::{MenuStructure, ids};

/// Entry point invoked from `main`. Blocks until the user picks "Quit" on
/// the menu; returns never (`!`) because the AppKit run loop owns the
/// thread until then.
///
/// @trace spec:macos-native-tray.ui.nsstatusitem-only@v1
pub fn run() -> ! {
    // SAFETY: We MUST be on the main thread for any AppKit object. AppKit
    // panics with a clear message if `MainThreadMarker::new()` is called
    // off-thread.
    let mtm =
        MainThreadMarker::new().expect("tillandsias-tray must be invoked from the main OS thread");
    let app = NSApplication::sharedApplication(mtm);

    // LSUIElement (accessory app, no Dock icon) — matches Info.plist.
    // setActivationPolicy returns bool indicating acceptance.
    let _ = app.setActivationPolicy(NSApplicationActivationPolicy::Accessory);

    // Per-process Tokio runtime, shared with the TrayActionHost so it
    // can spawn worker tasks for VM lifecycle calls without blocking
    // the AppKit main thread. Stays alive for the lifetime of the
    // process via the Arc clones the action-host retains.
    let tokio_runtime = std::sync::Arc::new(
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("tillandsias-tray-worker")
            .enable_all()
            .build()
            .expect("Tokio runtime build failed (tillandsias-tray slice 2)"),
    );

    // Build the action-host responder ONCE per process. Lives on the
    // AppKit thread's stack for the duration of `NSApplication::run`;
    // menu items target it via `setTarget:` so AppKit dispatches their
    // selectors here. See `action_host.rs` for the declared class.
    let image_root = default_image_root();
    let action_host = TrayActionHost::new(mtm, tokio_runtime.clone(), image_root);

    // Stash a Retained handle back to the action-host so the cloud-
    // projects + VmStatus pollers can dispatch menu rebuilds that
    // re-wire `trayAction:` targets via the live action-host instance.
    // Safe to call here — we're on the AppKit main thread.
    action_host.set_self_handle(action_host.clone());

    // Auto-start the VM as soon as the tray comes up. The user never
    // manually drives VM lifecycle — that's an implementation detail
    // surfaced via the menu's status chip (slice 2). The boot path is
    // identical to the legacy Start VM click (which still works as a
    // no-op retry), but fires immediately on launch so the user sees
    // Provisioning → Booting → Ready without intervention.
    action_host.boot_vm_async("Auto-boot");

    // Build the initial provisioning menu so the user sees the condensed
    // status line right away, even before the VM thread reports anything.
    let initial = MenuStructure::initial_provisioning();
    let status_item = install_status_item(mtm, &initial, &action_host);

    // Spawn the VM lifecycle on a background thread — see vz_lifecycle.
    // Skipped here pending the macOS-host integration in the follow-up
    // wave; the bin still produces a working menu bar UI for manual probe.
    let _ = &status_item;
    let _ = &action_host;

    // SAFETY: NSApplication.run is the standard AppKit main loop. It only
    // returns when [NSApp terminate:] is called from a menu handler, which
    // walks back out through this function as `unreachable`.
    unsafe { app.run() };

    // Apple's API contract is that .run only returns after terminate:.
    // We mark this as unreachable to satisfy the `-> !` return type.
    unreachable!("NSApplication.run returned without terminate:")
}

/// Construct the `NSStatusItem` + initial menu and bind them to the system
/// status bar. Returns the retained handle so the caller can keep the
/// status item alive for the process lifetime.
///
/// @trace spec:macos-native-tray.ui.nsstatusitem-only@v1
pub fn install_status_item(
    mtm: MainThreadMarker,
    structure: &MenuStructure,
    action_host: &TrayActionHost,
) -> Retained<NSStatusItem> {
    // SAFETY: AppKit class methods that touch shared singletons must run
    // on the main thread; the marker proves we are.
    let status_bar = unsafe { NSStatusBar::systemStatusBar() };
    let status_item = unsafe { status_bar.statusItemWithLength(NSVariableStatusItemLength) };

    // Set initial tooltip from the provisioning status text so the user
    // sees the condensed phase string on hover.
    if let Some(button) = unsafe { status_item.button(mtm) } {
        // Default title (image will replace once assets/icon.pdf is loaded
        // at packaging time).
        let title = NSString::from_str("T");
        unsafe { button.setTitle(&title) };

        // Tooltip mirrors the status text of the current MenuStructure.
        let tooltip_str = status_tooltip(structure);
        let tooltip = NSString::from_str(&tooltip_str);
        unsafe { button.setToolTip(Some(&tooltip)) };
    }

    let (menu, status_row) = build_menu_with_status_row(mtm, structure, action_host);
    unsafe { status_item.setMenu(Some(&menu)) };

    // Hand the action-host the live handles so its lifecycle
    // updates (`set_status_text`) can patch the title + tooltip
    // in-place instead of rebuilding the menu. We hold our own
    // +1 retain via the returned Retained — give the action-host
    // its own retain by cloning the smart pointer.
    if let Some(row) = status_row {
        action_host.attach_status_handles(status_item.clone(), row);
    }
    status_item
}

/// Build the menu and return the first-row `NSMenuItem` (the one
/// keyed `ids::STATUS`) so the action-host can patch its title as
/// the VM lifecycle advances. The status row is `None` only if the
/// shared `MenuStructure` produced an empty top-level list — which
/// `initial_provisioning()` never does, but we don't want to panic
/// here.
pub(crate) fn build_menu_with_status_row(
    mtm: MainThreadMarker,
    structure: &MenuStructure,
    action_host: &TrayActionHost,
) -> (Retained<NSMenu>, Option<Retained<NSMenuItem>>) {
    let menu = NSMenu::new(mtm);
    let mut status_row: Option<Retained<NSMenuItem>> = None;
    for spec in render(structure) {
        let item = build_menu_item(mtm, &spec, action_host);
        if spec.id == ids::STATUS && status_row.is_none() {
            status_row = Some(item.clone());
        }
        menu.addItem(&item);
    }
    (menu, status_row)
}

/// Build an `NSMenu` from a host-shell `MenuStructure`. Walks the tree
/// 1:1 — the macOS tray renders the SAME menu shape as Linux + Windows,
/// with no macOS-specific extras. Per-item action wiring happens inside
/// `build_menu_item` keyed on `MacMenuItemSpec::id`:
///   - `ids::QUIT` → AppKit `terminate:` with nil target (responder chain).
///   - other ids → not yet wired (follow-up slice).
///
/// The "VM spin-up" that's unique to macOS (and Windows) is NOT a
/// menu item — it's surfaced via the `ids::STATUS` first row whose
/// label/tooltip reflect the lifecycle phase. The actual spin-up
/// happens automatically on app launch (`status_item::run` calls
/// `action_host.boot_vm_async("Auto-boot")` before NSApplication.run).
///
/// Per spec invariant `menu-renders-in-50ms`, construction is purely
/// allocation + per-item method calls; no I/O.
///
/// @trace spec:macos-native-tray.ui.menu-parity@v1
pub fn build_menu(
    mtm: MainThreadMarker,
    structure: &MenuStructure,
    action_host: &TrayActionHost,
) -> Retained<NSMenu> {
    let menu = NSMenu::new(mtm);
    for spec in render(structure) {
        let item = build_menu_item(mtm, &spec, action_host);
        menu.addItem(&item);
    }
    menu
}

fn build_menu_item(
    mtm: MainThreadMarker,
    spec: &MacMenuItemSpec,
    action_host: &TrayActionHost,
) -> Retained<NSMenuItem> {
    // Separator items have no title; the shared menu_disabled_v2 spec
    // doesn't currently produce separators, but if it does in future
    // the empty label is the convention.
    let title = NSString::from_str(&spec.label);
    let item = NSMenuItem::new(mtm);
    unsafe { item.setTitle(&title) };
    unsafe { item.setEnabled(spec.enabled) };
    if !spec.tooltip.is_empty() {
        let tooltip = NSString::from_str(&spec.tooltip);
        unsafe { item.setToolTip(Some(&tooltip)) };
    }
    if spec.checked {
        // NSControlStateValueOn = 1
        unsafe { item.setState(objc2_app_kit::NSControlStateValueOn) };
    }
    // ID-keyed action wiring.
    // - Quit uses our custom `quitWithDrain:` selector on the
    //   TrayActionHost so we can drain the in-VM headless (60s
    //   timeout) before exiting. AppKit's `terminate:` would skip
    //   the drain and leave the VM in a half-stopped state. We
    //   keep ⌘Q as the key equivalent — the user-visible binding
    //   is identical, only the implementation gains a graceful
    //   shutdown step.
    // - Every other enabled, leaf-ish item gets the generic
    //   `trayAction:` selector targeting the shared TrayActionHost.
    //   The id string is stashed on the NSMenuItem via
    //   `setRepresentedObject:`; the action_host reads it back +
    //   resolves to `MenuAction` via the shared `menu_action::resolve`
    //   table (same dispatch surface windows-tray uses).
    if spec.id == ids::QUIT {
        let host_any: &AnyObject = <TrayActionHost as ClassType>::as_super(action_host).as_ref();
        unsafe {
            item.setKeyEquivalent(&NSString::from_str("q"));
            item.setAction(Some(sel!(quitWithDrain:)));
            item.setTarget(Some(host_any));
        }
    } else if spec.enabled {
        let id_str = NSString::from_str(&spec.id);
        // Coerce `&TrayActionHost` to `&AnyObject` for `setTarget:` via
        // the declared class's super chain (NSObject → AnyObject).
        let host_any: &AnyObject = <TrayActionHost as ClassType>::as_super(action_host).as_ref();
        unsafe {
            item.setAction(Some(sel!(trayAction:)));
            item.setTarget(Some(host_any));
            item.setRepresentedObject(Some(&id_str));
        }
    }
    if !spec.children.is_empty() {
        let submenu = NSMenu::new(mtm);
        for child in &spec.children {
            let child_item = build_menu_item(mtm, child, action_host);
            submenu.addItem(&child_item);
        }
        item.setSubmenu(Some(&submenu));
    }
    item
}

/// Extract a tooltip-friendly status string from the menu structure. Looks
/// for the conventional `status` item and falls back to a generic label.
fn status_tooltip(structure: &MenuStructure) -> String {
    use tillandsias_host_shell::menu_state::ids;
    for item in structure.top_items() {
        if item.id == ids::STATUS {
            return item.label.clone();
        }
    }
    "Tillandsias".to_string()
}

// AppKit constant for NSMenuItem checkmark state. The objc2-app-kit crate
// expects this exact symbol when calling setState — re-exported here for
// clarity at the call site above.
use objc2_app_kit::NSControlStateValueOn as _;

/// Where the recipe materializer publishes the per-arch boot artifacts
/// (rootfs.img / kernel / initrd) on a macOS host. Follows Apple's
/// Application Support convention; the inner `tillandsias/` is the
/// canonical Tillandsias app-data subdirectory shared with
/// `installation_uuid.rs`.
///
/// VzRuntime joins `<image_root>/rootfs.img` etc., so this is one
/// level above the file basenames.
fn default_image_root() -> std::path::PathBuf {
    let home = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("/tmp"));
    home.join("Library/Application Support/tillandsias")
}
