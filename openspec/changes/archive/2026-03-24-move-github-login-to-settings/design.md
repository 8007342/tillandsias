## Context

The current tray menu layout has GitHub Login as a conditional top-level item and Settings as a non-functional stub. The menu is built in `menu.rs` using Tauri's `MenuBuilder` with `MenuItem` and `Submenu` types.

## Goals / Non-Goals

**Goals:**
- Convert the Settings menu item into a `Submenu`
- Move GitHub Login inside that submenu
- Preserve conditional visibility (only show GitHub Login when creds are missing)

**Non-Goals:**
- Implementing actual settings UI or preferences
- Adding other items to Settings (future work)
- Changing any handler logic

## Decisions

### Decision 1: Tauri Submenu for Settings

**Choice**: Use `tauri::menu::SubmenuBuilder` to create a Settings submenu, add GitHub Login as a child item.

**Rationale**: Tauri's menu API supports nested submenus natively. The `Submenu` type renders as a flyout menu on all platforms. No custom UI needed.

### Decision 2: Settings submenu always visible, children conditional

**Choice**: The Settings submenu always appears in the menu. GitHub Login appears inside it only when `needs_github_login()` returns true. When no items need showing, Settings contains a disabled "All set" placeholder.

**Rationale**: A disappearing Settings menu is confusing. Always showing it provides a stable anchor point for future settings items. The placeholder prevents an empty submenu.

## Risks / Trade-offs

- **[Empty submenu]** → Mitigated by the "All set" placeholder when GitHub Login isn't needed.
