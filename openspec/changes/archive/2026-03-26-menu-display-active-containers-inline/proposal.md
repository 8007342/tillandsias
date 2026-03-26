## Why

The tray menu currently segregates running projects into a "Running Environments" submenu. This is tech jargon — users don't think in terms of "environments". More importantly, it buries active projects one click deeper behind an abstraction layer. When a project is running, users want to act on it immediately without hunting through submenus.

The fix: active projects rise to the top level of the menu, inline, with their emoji indicators visible at a glance. Inactive projects stay in the "Projects" submenu as before. There is no "Running Environments" submenu — the concept disappears entirely.

## What Changes

- **Active projects inline** — Projects with running containers are promoted to the top level of the menu, between the separator and the Projects submenu. Each active project uses the same submenu built by `build_project_submenu()` — the same Attach Here / Maintenance actions, same emoji labels.
- **Projects submenu contains only inactive projects** — When some projects are active, the Projects submenu shows only the remaining idle projects. If all projects are active, the Projects submenu is omitted entirely. If no projects are known, it shows "No projects detected" as before.
- **Remove "Running Environments" submenu** — `build_running_submenu()` is deleted. The information it conveyed (which containers are running, with Stop/Destroy actions) is superseded by the active project submenus.
- **Build chips move inline** — Active build chips (⏳/✅/❌) appear as disabled inline menu items below the active project entries, or below the Projects submenu when nothing is active. The Activity submenu is also removed; chips are always inline.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `tray-app`: Active projects promoted inline in tray menu; Running Environments and Activity submenus removed

## Impact

- Modified files: `src-tauri/src/menu.rs`
- Deleted: `build_running_submenu()`, `build_activity_submenu()` functions
- No new dependencies, no data model changes
