## Why

The GitHub Login menu items in the Settings submenu are plain text with no visual differentiation. Adding emoji icons gives users an immediate visual cue about the action's nature — the key emoji signals "entering/unlocking" for initial login, and the closed lock signals "re-authenticating" for a refresh when already logged in. This matches the emoji-first visual language used throughout the rest of the tray menu.

## What Changes

- **GitHub Login** — Prefix with key emoji (`🔑 GitHub Login`, U+1F511) when not authenticated
- **GitHub Login Refresh** — Prefix with closed lock emoji (`🔒 GitHub Login Refresh`, U+1F512) when already authenticated

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `tray-menu`: GitHub Login items in the Settings submenu now carry emoji prefixes for visual clarity

## Impact

- **New files**: none
- **Modified files**: `src-tauri/src/menu.rs` (`build_settings_submenu` — two string literals updated)
