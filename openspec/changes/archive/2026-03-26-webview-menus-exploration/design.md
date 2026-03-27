## Context

Tillandsias is a tray-only application (`"windows": []` in tauri.conf.json). All user interaction happens through native OS tray menus. The Settings submenu currently nests GitHub (login, remote projects), Seedlings (agent picker), and About (version, credit) inside cascading submenus. On Linux with libappindicator, these submenus are unreliable and unstyled. The 32 tillandsia SVG icons in `assets/icons/` are never visible to users.

The archived `terminal-in-tauri` design (2026-03-25) already researched `WebviewWindowBuilder` for creating windows from a tray-only app. That work confirmed: Tauri allows programmatic window creation even with `"windows": []` in config, and the `AppHandle` provides the builder API. This exploration applies the same pattern to a settings window instead of a terminal window.

## Goals / Non-Goals

**Goals:**
- Prove that a tray-only Tauri app can create webview windows on demand from menu clicks
- Show that inline SVG tillandsia icons render correctly in the webview
- Establish the visual layout for a settings window (tabs, sections, icons)
- Identify what Tauri capabilities/permissions are needed for window creation
- Document Wayland limitations for per-window icons on Linux
- Produce a working spike that compiles and can be tested

**Non-Goals:**
- Tauri IPC commands (reading/saving config) -- follow-up work
- Live agent selection or GitHub login from the webview -- follow-up work
- Production CSS/design polish -- this is an exploration
- Replacing the tray menu entirely -- tray keeps all action items

## Research Findings

### R1: Programmatic window creation from tray-only app

Tauri v2's `WebviewWindowBuilder` allows creating windows at runtime from any `AppHandle` reference. The `"windows": []` config simply means no windows open at launch -- it does not prevent creating them later.

```rust
use tauri::WebviewWindowBuilder;

// From any handler with access to AppHandle:
let window = WebviewWindowBuilder::new(
    app,
    "settings",                          // label (unique ID)
    tauri::WebviewUrl::App("settings.html".into()),
)
.title("Tillandsias Settings")
.inner_size(480.0, 600.0)
.min_inner_size(400.0, 500.0)
.resizable(true)
.build()?;
```

The `tauri::WebviewUrl::App(...)` resolves relative to `frontendDist` (configured as `../assets/frontend`). So `"settings.html"` loads `assets/frontend/settings.html`.

**Deduplication**: If the user clicks "Settings" while the window is already open, we check `app.get_webview_window("settings")` first. If it exists, call `window.set_focus()` instead of creating a duplicate.

### R2: Required capabilities and permissions

The default capabilities file currently has:
```json
{
  "permissions": ["core:default", "shell:allow-open", "updater:default"]
}
```

For window creation at runtime, `core:default` already includes `core:window:allow-create`. No additional permissions are needed for basic window creation.

However, for the settings window to use `window.__TAURI__` APIs (needed for future IPC), `withGlobalTauri` must be `true` in `tauri.conf.json`, OR the frontend must use `@tauri-apps/api` imports. Since this is a spike with no build step, setting `withGlobalTauri: true` is the simpler path. It injects the Tauri API globally into all webview windows.

For future IPC (Tauri commands), we would add permissions like:
```json
"core:window:allow-set-focus",
"core:window:allow-close"
```

But for this spike, no permission changes are strictly required beyond enabling `withGlobalTauri`.

### R3: Frontend options

**Plain HTML/CSS/JS** is the right choice for this exploration:

- No build step (no npm, no bundler, no node_modules)
- Files served directly from `assets/frontend/` via Tauri's `frontendDist`
- SVG icons can be inlined directly in HTML (no import/require)
- CSS custom properties for theming (dark mode via `prefers-color-scheme`)
- Future: if complexity grows, consider a lightweight framework (Svelte, Lit) with a build step

The current `assets/frontend/index.html` is an empty stub. The settings page will be a separate file (`settings.html`) so the two don't conflict.

### R4: Inline SVG icons

The tillandsia SVGs in `assets/icons/` are small (300-600 bytes each) and self-contained. They can be embedded directly in HTML:

```html
<div class="genus-icon">
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="32" height="32">
    <!-- ionantha bloom inline -->
  </svg>
</div>
```

This avoids any file-path resolution issues and guarantees the icons render regardless of Tauri's asset protocol configuration. For a production version, we might use `<img src="icons/ionantha/bloom.svg">` with Tauri's asset protocol, but inline is simpler and more reliable for the spike.

### R5: Per-window custom icons (Linux/Wayland limitations)

`WebviewWindowBuilder` has a `.icon()` method that accepts a `tauri::image::Image`. This sets the window icon (taskbar, Alt+Tab, window decorations).

**Platform behavior:**

| Platform | Window icon support | Notes |
|----------|-------------------|-------|
| Windows | Full support | `.icon()` sets taskbar and title bar icon |
| macOS | N/A | macOS uses the app icon for all windows (no per-window icon) |
| Linux/X11 | Full support | `_NET_WM_ICON` property, respected by all WMs |
| Linux/Wayland | Partial | Depends on compositor. GNOME ignores per-window icons (uses `.desktop` file icon). KDE/Sway may respect `xdg_toplevel.set_icon` if using the unstable protocol |

**Verdict**: Per-window icons work on Windows and Linux/X11. On Wayland (GNOME), the app icon from the `.desktop` file is used for all windows. This is a Wayland/GNOME policy decision, not a Tauri limitation. For the settings window this is fine -- the app icon is appropriate. For future terminal windows with genus-specific icons, this is a known limitation that cannot be worked around on GNOME/Wayland.

We will NOT set a custom icon in this spike. The default app icon is correct for a settings window.

### R6: What moves from tray to window

```
TRAY (actions only):                  WINDOW (settings/info):
+----------------------------------+  +----------------------------------+
| ~/src/ -- Attach Here            |  | [GitHub tab]                     |
| Root                             |  |   Login status                   |
| --------                         |  |   Remote repos list              |
| project-a  (active, inline)      |  |                                  |
| project-b  (active, inline)      |  | [Seedlings tab]                  |
| Projects >  (inactive only)      |  |   Agent picker (OpenCode/Claude) |
| --------                         |  |   Tillandsia icon per agent      |
| Settings  <- opens window        |  |                                  |
| Quit Tillandsias                 |  | [About tab]                      |
+----------------------------------+  |   Version, credit                |
                                      |   Tillandsia genus gallery        |
                                      +----------------------------------+
```

The tray becomes strictly actions: attach, terminal, quit. All configuration and informational content moves to the webview window. This reduces the tray menu from ~15 items (with submenus) to ~8 flat items.

### R7: Communication architecture (future, not in spike)

When IPC is added in a follow-up, the pattern will be:

**Tauri commands (JS -> Rust):**
- `get_settings()` -> returns current config (selected agent, github auth status)
- `set_agent(agent: String)` -> saves agent selection, triggers menu rebuild
- `github_login()` -> starts auth flow in a container
- `get_remote_repos()` -> returns cached repo list

**Events (Rust -> JS):**
- `settings:updated` -> config changed externally (e.g., from CLI)
- `github:auth-complete` -> login flow finished
- `repos:refreshed` -> remote repos list updated

This follows the same pattern as the terminal-in-tauri IPC design: commands for request/response, events for push notifications.

## Decisions

### D1: Settings is a single flat menu item, not a submenu

The current `build_settings_submenu()` creates a `SubmenuBuilder` containing GitHub, Seedlings, version, and credit. This exploration replaces it with a single `MenuItemBuilder` that dispatches `MenuCommand::OpenSettings`.

The existing `MenuCommand::Settings` variant is already defined but documented as "Submenu now -- this event won't fire." We add a new `MenuCommand::OpenSettings` variant to make the intent explicit and avoid confusion with the legacy `Settings` variant.

### D2: Window creation happens in main.rs, not event_loop.rs

The event loop runs in a `tauri::async_runtime::spawn` block. It does not have direct access to the `AppHandle`. Rather than threading the handle through the event loop (which would couple `tillandsias-core` to Tauri types), the `OpenSettings` command is handled in `main.rs`'s `handle_menu_click` function, which already has the `AppHandle`.

This mirrors decision D8 from the terminal-in-tauri design but is even simpler: no PTY, no container, just open a window.

### D3: withGlobalTauri enabled for spike simplicity

Setting `"withGlobalTauri": true` in `tauri.conf.json` injects `window.__TAURI__` into all webview windows. This avoids needing a JavaScript build step to import `@tauri-apps/api`. For the spike (static HTML), this is harmless. For production, we may revisit this decision if we add a build step.

### D4: settings.html is a separate file from index.html

The existing `index.html` stub serves as the default frontend for the terminal-in-tauri work. The settings window gets its own `settings.html` to keep concerns separate. Both are served from `assets/frontend/`.

## Spike Scope

The spike implements:

1. `MenuCommand::OpenSettings` variant in `event.rs`
2. "Settings" menu item (flat, not submenu) in `menu.rs`
3. Window creation in `main.rs` handle_menu_click
4. `OpenSettings` handler in `event_loop.rs` (no-op, window created in main.rs)
5. `assets/frontend/settings.html` with static HTML/CSS showing:
   - Three tab-like sections: GitHub, Seedlings, About
   - Inline ionantha bloom SVG icon
   - Genus gallery in About section showing multiple SVGs
   - Dark mode via `prefers-color-scheme`
   - Placeholder content (no live data)
6. `tauri.conf.json` updated: `withGlobalTauri: true`
7. `capabilities/default.json` updated if needed

The spike does NOT implement:
- Tauri IPC commands
- Live config reading/writing
- GitHub login from the window
- Agent selection from the window
- Removing the existing Settings submenu (kept for comparison)
