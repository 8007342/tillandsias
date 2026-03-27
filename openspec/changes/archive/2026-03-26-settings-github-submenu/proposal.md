## Why

The Settings submenu mixes GitHub authentication and Remote Projects at the same level as version/credit metadata. As more GitHub-related items are added, this flat structure will become cluttered. Grouping them under a single "GitHub" submenu improves discoverability and provides a clear home for future GitHub features.

## What Changes

- **Settings submenu restructure** — GitHub Login/Refresh and Remote Projects are collapsed under a single "GitHub" submenu inside Settings
- **No handler changes** — event IDs and dispatch logic are unchanged; only the visual hierarchy changes

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `settings-github-submenu`: Settings submenu groups all GitHub-related items under a "GitHub" child submenu

## Impact

- **Modified files**: `src-tauri/src/menu.rs` — `build_settings_submenu()` wraps GitHub items in a `SubmenuBuilder`
- **New structure**:
  ```
  Settings ▸
    ├── GitHub ▸
    │   ├── 🔑 GitHub Login  (or 🔒 GitHub Login Refresh)
    │   ├── ─────────          (only when authenticated)
    │   └── Remote Projects ▸  (only when authenticated)
    ├── ─────────
    ├── Tillandsias v0.1.x
    └── by Tlatoāni
  ```
