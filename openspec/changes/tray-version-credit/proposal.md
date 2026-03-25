## Why

Users have no way to tell which version of Tillandsias is running from the tray menu. Adding version and credit lines makes the app feel polished and helps with troubleshooting ("which version are you on?"). Also serves as a visual trigger to test the Tauri auto-update system — bumping the minor version will let installed instances detect the update.

## What Changes

- **Version line**: Non-clickable "Tillandsias v0.1.36" displayed just before Quit
- **Credit line**: Non-clickable "by Tlatoāni" displayed between version and Quit
- **Version bump**: 0.1.35 → 0.1.36 to trigger auto-update detection on other hosts

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `tray-app`: Add version and credit display to tray menu

## Impact

- **Modified files**: `src-tauri/src/menu.rs` (two disabled menu items)
- **Version bump**: triggers auto-update on hosts running v0.1.35
