## Why

GitHub Login currently sits as a top-level tray menu item, cluttering the main menu alongside project actions. It's a one-time setup action that belongs under Settings. The Settings menu item already exists but is a stub — this change makes it a submenu and moves GitHub Login into it.

## What Changes

- **Settings becomes a submenu**: Instead of a single disabled-looking menu item, Settings becomes a submenu containing GitHub Login (and future settings items)
- **GitHub Login moves**: From top-level position to inside the Settings submenu, still conditionally shown only when credentials are missing
- **Menu layout simplified**: One less top-level item, cleaner separation between project actions and configuration

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `tray-app`: Settings becomes a submenu; GitHub Login moves from top-level into Settings submenu

## Impact

- **Modified files**: `src-tauri/src/menu.rs` (restructure menu building)
- **No handler changes**: GitHub Login handler and Settings dispatch remain the same — only the menu structure changes
