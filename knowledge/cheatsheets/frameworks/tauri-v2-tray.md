---
id: tauri-v2-tray
title: Tauri v2 System Tray Applications
category: frameworks/tauri
tags: [tauri, tray, system-tray, menu, no-window, cross-platform]
upstream: https://v2.tauri.app/learn/system-tray/
version_pinned: "2.x"
last_verified: "2026-03-30"
authority: official
---

# Tauri v2 System Tray Applications

## Cargo Features

Enable tray support in `Cargo.toml`:

```toml
[dependencies]
tauri = { version = "2", features = ["tray-icon", "image-png"] }
```

- `tray-icon` — required for all tray functionality
- `image-png` / `image-ico` — needed if loading icons from PNG/ICO bytes

## TrayIconBuilder

Build tray icons inside `Builder::setup`. Do **not** use the removed `Builder::system_tray`.

```rust
use tauri::{
    menu::{MenuBuilder, MenuItemBuilder, CheckMenuItemBuilder, PredefinedMenuItem, SubmenuBuilder},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager,
};

tauri::Builder::default()
    .setup(|app| {
        let status = MenuItemBuilder::with_id("status", "Idle").enabled(false).build(app)?;
        let toggle = CheckMenuItemBuilder::new("Autostart").id("autostart").build(app)?;
        let sep = PredefinedMenuItem::separator(app)?;
        let quit = MenuItemBuilder::with_id("quit", "Quit").build(app)?;

        let menu = MenuBuilder::new(app)
            .items(&[&status, &toggle, &sep, &quit])
            .build()?;

        let _tray = TrayIconBuilder::new()
            .icon(app.default_window_icon().unwrap().clone())
            .tooltip("My App")
            .menu(&menu)
            .menu_on_left_click(false)
            .on_menu_event(|app, event| match event.id.as_ref() {
                "quit" => app.exit(0),
                "autostart" => { /* handle toggle */ }
                _ => {}
            })
            .on_tray_icon_event(|tray, event| match event {
                TrayIconEvent::Click {
                    button: MouseButton::Left,
                    button_state: MouseButtonState::Up,
                    ..
                } => {
                    // left-click: toggle window, open panel, etc.
                    let app = tray.app_handle();
                    if let Some(win) = app.get_webview_window("main") {
                        let _ = win.show();
                        let _ = win.set_focus();
                    }
                }
                _ => {}
            })
            .build(app)?;

        Ok(())
    })
```

### Key Builder Methods

| Method | Purpose |
|---|---|
| `.icon(Image)` | Set the tray icon |
| `.tooltip(&str)` | Hover tooltip text |
| `.menu(&Menu)` | Attach a context menu |
| `.menu_on_left_click(bool)` | Show menu on left click (default `true`) |
| `.title(&str)` | Text next to icon (macOS menu bar only) |
| `.icon_as_template(bool)` | macOS template image (auto-adapts to light/dark) |
| `.id(&str)` | Unique ID (required for multi-tray) |
| `.on_menu_event(Fn)` | Handle menu item clicks |
| `.on_tray_icon_event(Fn)` | Handle mouse events on the icon |

## No-Window (Tray-Only) App

Set an empty windows array in `tauri.conf.json`:

```json
{
  "app": {
    "windows": []
  }
}
```

Prevent exit when the last window closes:

```rust
app.on_window_event(|_window, event| {
    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
        api.prevent_close();
    }
});
```

## TrayIconEvent Variants

```rust
TrayIconEvent::Click { id, position, rect, button, button_state }
TrayIconEvent::DoubleClick { id, position, rect, button }
TrayIconEvent::Enter { id, position, rect }
TrayIconEvent::Move { id, position, rect }
TrayIconEvent::Leave { id, position, rect }
```

`button`: `MouseButton::Left | Right | Middle`
`button_state`: `MouseButtonState::Up | Down`

## Dynamic Updates at Runtime

Use `TrayIcon` and menu item handles stored in `AppHandle` managed state:

```rust
// Change icon
tray.set_icon(Some(new_icon))?;

// Change tooltip
tray.set_tooltip(Some("New status"))?;

// Replace entire menu
let new_menu = MenuBuilder::new(app).items(&[&item]).build()?;
tray.set_menu(Some(new_menu))?;

// Update single menu item text
status_item.set_text("Running")?;

// Toggle check item
check_item.set_checked(true)?;
```

**macOS caveat:** calling `set_icon` resets `icon_as_template`. Call `set_icon_as_template(true)` immediately after to avoid a visual blink.

## Multi-Tray Support

Create multiple tray icons with distinct IDs:

```rust
TrayIconBuilder::new().id("main-tray").icon(icon_a).build(app)?;
TrayIconBuilder::new().id("status-tray").icon(icon_b).build(app)?;
```

**Known issue:** some Tauri v2 versions may show a ghost transparent icon alongside the real one. Pin to a stable release and test.

## Platform-Specific Notes

### Linux

Requires `libayatana-appindicator` (preferred) or `libappindicator3`:

| Distro | Package |
|---|---|
| Debian/Ubuntu | `libayatana-appindicator3-dev` |
| Fedora | `libappindicator-gtk3-devel` |
| Arch | `libappindicator-gtk3` |
| Alpine | `libayatana-appindicator-dev` |

Debian bundles auto-add `libappindicator3-1` as a dependency when tray is used. The tray uses DBus `StatusNotifierItem` protocol under the hood -- no X11 system tray embed.

### macOS

- Use `.icon_as_template(true)` for menu bar icons that adapt to light/dark mode. Icons should be single-color PNGs with transparency.
- `.title(&str)` renders text in the menu bar next to the icon.
- Right-click and left-click both trigger menu by default.

### Windows

- Tray icons appear in the notification area (system tray). Users may need to pin the icon from the overflow.
- `.tooltip()` shows on hover. Limited to 127 characters.
- Left-click and right-click are distinct events; menu shows on right-click by default.

## Icon Formats

```rust
// From embedded bytes (compile-time)
let icon = Image::from_bytes(include_bytes!("../icons/tray.png"))?;

// From file path (runtime)
let icon = Image::from_path("path/to/icon.png")?;

// From app's default window icon
let icon = app.default_window_icon().unwrap().clone();
```

Recommended sizes: 32x32 (Windows/Linux), 22x22 or 44x44 @2x (macOS template). Supply multiple sizes or a single 32x32 PNG for cross-platform.

## Async Commands from Tray

Tray event handlers run on the main thread. For async work, spawn onto the async runtime:

```rust
.on_menu_event(|app, event| {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        match event.id.as_ref() {
            "refresh" => do_async_work(&app).await,
            _ => {}
        }
    });
})
```

## IPC: Tray to Frontend

Emit events from tray handlers to any listening webview:

```rust
.on_menu_event(|app, event| {
    app.emit("tray-action", event.id.0.clone()).unwrap();
})
```

Frontend listens with `listen("tray-action", callback)` from `@tauri-apps/api/event`.
