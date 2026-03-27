## Why

The Settings submenu is currently three levels deep: Settings > GitHub > Remote Projects, and Settings > Seedlings > agent selection. Native tray menus are OS widgets with zero styling capability -- no custom icons, no color, no layout control. Each platform renders them differently. Navigating nested submenus on Linux (libappindicator) is particularly clunky: submenus flicker, hover timing is inconsistent, and users lose their place.

Meanwhile, we have 32 hand-crafted tillandsia SVG icons (8 genera x 4 lifecycle states) that users never see because tray menus cannot render inline SVGs. The plant metaphor -- the core of the Tillandsias identity -- is invisible in the very UI surface where users spend the most time.

A webview window solves both problems: rich HTML/CSS layout for settings, and a canvas where the tillandsia visual identity can actually appear.

## What Changes

- **Settings webview window** -- clicking "Settings" in the tray opens a proper HTML/CSS window (480x600) with tabs for GitHub, Seedlings (agent picker), and About. The window is created programmatically via `WebviewWindowBuilder` from a tray menu click.
- **Tray menu stays lean** -- only actions remain in the tray (Attach Here, Root, Projects, Quit). Settings becomes a single menu item that opens the window.
- **Custom tillandsia icons inline** -- the settings window embeds SVG icons directly, proving that the webview approach enables the visual identity that tray menus cannot.
- **No Tauri IPC yet** -- this is an exploration spike. The window is static HTML showing the intended layout. Backend communication (reading config, saving selections) is a follow-up.

## Capabilities

### New Capabilities
- `settings-webview`: Programmatic Tauri webview window created from tray menu click
- `settings-frontend`: HTML/CSS settings page with inline SVG tillandsia icons

### Modified Capabilities
- `tray-menu`: Settings changes from a submenu to a single "Settings" menu item
- `event-loop`: `MenuCommand::OpenSettings` dispatches window creation instead of being a no-op
- `tauri-config`: Capabilities updated to allow window creation at runtime

## Impact

- **New files**: `assets/frontend/settings.html`, `openspec/changes/webview-menus-exploration/`
- **Modified files**: `src-tauri/src/menu.rs` (Settings item), `src-tauri/src/main.rs` (dispatch), `src-tauri/src/event_loop.rs` (handler), `crates/tillandsias-core/src/event.rs` (MenuCommand variant), `src-tauri/tauri.conf.json` (withGlobalTauri), `src-tauri/capabilities/default.json` (window permissions)
- **Exploration scope**: This is a spike -- proving the approach works. The webview window is static HTML. Tauri command IPC and live config editing are follow-up work.
