## Why

The tray menu has grown incrementally and now has too many top-level items separated by dividers. With multiple projects, running environments, build chips, settings, and version info all laid out inline, the menu is long, hard to scan, and requires scrolling on small screens. Every new feature adds yet another divider and item to an already crowded top level.

The fix is a fanout structure: the top level stays short (5–7 items maximum) and all detail fans out into submenus. Projects already have individual submenus; they just need to be collected under a single "Projects" parent. Running environments already have a submenu container; it just needs to be promoted to a proper top-level slot only when active. Build chips, version, credit, and Quit get their own "About" submenu. The result is a menu that is fast to navigate regardless of how many projects or running environments exist.

## What Changes

- **Projects submenu**: All per-project submenus are nested under a single "Projects ▸" top-level entry instead of being listed individually at the top level
- **Running submenu**: "Running Environments" is shown at the top level only when containers are active (unchanged semantics, better placement — directly below Projects)
- **Activity section removed from inline**: Build chips move inside the "Running" submenu when environments are active, or into a standalone "Activity" submenu when there are chips but no running containers
- **About submenu**: Version, credit, and Quit are grouped under "Tillandsias v{version} ▸" at the bottom, eliminating the final separator-and-disabled-items block
- **Settings submenu**: Moves to its existing submenu but without the separator above it — only a single separator between the dynamic section (Projects/Running) and the static section (Settings/About) remains
- **Decay menu**: Inherits the About submenu structure for consistency

## Capabilities

### Modified Capabilities
- `tray-app`: Top-level menu structure shortened to ≤7 items; Projects, Running, Settings, and About all live behind submenus

## Impact

- Modified: `src-tauri/src/menu.rs` — `build_tray_menu()` restructured; new `build_projects_submenu()` helper; build chips moved inside Running/Activity; `build_about_submenu()` replaces inline version/credit/quit; `build_decay_menu()` updated
- No changes to handlers, state, or other crates — this is a pure menu layout change
- No new IDs introduced; all existing item IDs (`attach:`, `terminal:`, `stop:`, `destroy:`, `clone:`, `github-login`, `quit`, etc.) are unchanged
