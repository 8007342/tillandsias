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
use objc2::{class, msg_send_id, sel, ClassType};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSMenu, NSMenuItem, NSStatusBar, NSStatusItem,
    NSVariableStatusItemLength,
};
use objc2_foundation::{MainThreadMarker, NSString};

use crate::action_host::TrayActionHost;
use crate::menu_disabled_v2::{MacMenuItemSpec, render};
use tillandsias_host_shell::menu_state::MenuStructure;

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
    let action_host = TrayActionHost::new(mtm, tokio_runtime.clone());

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

    let menu = build_menu(mtm, structure, action_host);
    unsafe { status_item.setMenu(Some(&menu)) };
    status_item
}

/// Build an `NSMenu` from a host-shell `MenuStructure`. Walks the tree once
/// and produces `NSMenuItem` instances per the `MacMenuItemSpec` adapter,
/// then appends the standard footer (separator + version disabled header +
/// separator + Quit).
///
/// The Quit item uses the standard AppKit `terminate:` action with a nil
/// target — AppKit walks the responder chain and `NSApplication` handles
/// it. Cmd-Q keyboard shortcut is wired so power users don't even need to
/// open the menu. Without this item the binary is unkillable from the UI
/// (the v0.0.1 / iter-12 "stuck" issue the user hit on first launch).
///
/// Per spec invariant `menu-renders-in-50ms`, the construction is purely
/// allocation + per-item method calls; no I/O or sleeps.
///
/// @trace spec:macos-native-tray.ui.menu-parity@v1
pub fn build_menu(
    mtm: MainThreadMarker,
    structure: &MenuStructure,
    action_host: &TrayActionHost,
) -> Retained<NSMenu> {
    let menu = NSMenu::new(mtm);
    for spec in render(structure) {
        let item = build_menu_item(mtm, &spec);
        menu.addItem(&item);
    }
    append_actions(mtm, &menu, action_host);
    append_footer(mtm, &menu);
    menu
}

/// Append the four interactive items that drive the VM lifecycle and
/// shell-attach UX. Sandwiched between the rendered portable menu items
/// and the footer (separator + version header + Quit).
///
/// Each item's `target` is the shared `TrayActionHost` and its `action`
/// is the matching ObjC selector declared in `action_host.rs`. AppKit
/// dispatches on click; the Rust method runs on the main thread.
///
/// Slice 1 wires the selectors as eprintln stubs; subsequent slices
/// (m4 sub-task B 2/3/4/5) replace each stub with real Tokio-task
/// dispatch + main-thread UI feedback.
///
/// @trace plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 1)
fn append_actions(mtm: MainThreadMarker, menu: &NSMenu, action_host: &TrayActionHost) {
    // Separator above the action block so it's visually grouped distinct
    // from the portable menu items above.
    menu.addItem(&NSMenuItem::separatorItem(mtm));

    // Coerce `&TrayActionHost` to `&AnyObject` for `setTarget:`. The
    // declared class is `MainThreadOnly: NSObject` so the chain is
    // TrayActionHost → NSObject → AnyObject; we walk it via `as_super`.
    let host_any: &AnyObject = <TrayActionHost as ClassType>::as_super(action_host).as_ref();

    add_action_item(mtm, menu, "Start VM", sel!(startVm:), host_any);
    add_action_item(mtm, menu, "Stop VM", sel!(stopVm:), host_any);
    add_action_item(mtm, menu, "Open Shell", sel!(openShell:), host_any);
    add_action_item(mtm, menu, "GitHub login", sel!(githubLogin:), host_any);
}

/// Helper: construct an NSMenuItem with title + action + target wired
/// up. Pulled out so `append_actions` reads as a table.
fn add_action_item(
    mtm: MainThreadMarker,
    menu: &NSMenu,
    title: &str,
    action: Sel,
    target: &AnyObject,
) {
    let item = NSMenuItem::new(mtm);
    unsafe {
        item.setTitle(&NSString::from_str(title));
        item.setAction(Some(action));
        item.setTarget(Some(target));
    }
    menu.addItem(&item);
}

/// Append the standard tray footer to the bottom of any menu:
///
///   ───────────────
///   Tillandsias v<…>  (disabled header for identity)
///   ───────────────
///   Quit Tillandsias  ⌘Q
///
/// Idempotent: appended ONCE per menu construction (callers rebuild the
/// menu from scratch when state changes). The Quit item is what stops the
/// `NSApplication::run` loop in `super::run()`.
fn append_footer(mtm: MainThreadMarker, menu: &NSMenu) {
    let sep1 = NSMenuItem::separatorItem(mtm);
    menu.addItem(&sep1);

    // Identity header — disabled so it can't be selected; carries the
    // package version so the user knows what they're running. Reads VERSION
    // baked in at build time via CARGO_PKG_VERSION (= the 3-component crate
    // version derived from the 4-component VERSION file via bump-version.sh).
    let version_label = format!(
        "Tillandsias v{} (alpha)",
        env!("CARGO_PKG_VERSION")
    );
    let header = NSMenuItem::new(mtm);
    unsafe {
        header.setTitle(&NSString::from_str(&version_label));
        header.setEnabled(false);
    }
    menu.addItem(&header);

    let sep2 = NSMenuItem::separatorItem(mtm);
    menu.addItem(&sep2);

    // Quit — AppKit's standard responder-chain pattern. Target = nil so
    // [NSApp terminate:] gets dispatched via the chain. Cmd-Q for the
    // keyboard shortcut.
    let quit = NSMenuItem::new(mtm);
    unsafe {
        quit.setTitle(&NSString::from_str("Quit Tillandsias"));
        quit.setKeyEquivalent(&NSString::from_str("q"));
        quit.setAction(Some(sel!(terminate:)));
        // Explicit nil target → responder chain → NSApplication handles it.
        quit.setTarget(None);
    }
    menu.addItem(&quit);
}

fn build_menu_item(mtm: MainThreadMarker, spec: &MacMenuItemSpec) -> Retained<NSMenuItem> {
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
    if !spec.children.is_empty() {
        let submenu = NSMenu::new(mtm);
        for child in &spec.children {
            let child_item = build_menu_item(mtm, child);
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
