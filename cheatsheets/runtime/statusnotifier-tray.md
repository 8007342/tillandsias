---
tags: [tray, dbus, statusnotifieritem, dbusmenu, linux, tillandsias]
languages: []
since: 2026-05-06
last_verified: 2026-05-06
sources:
  - https://specifications.freedesktop.org/status-notifier-item/latest/status-notifier-item.html
  - https://docs.rs/dbusmenu-zbus/latest/src/dbusmenu_zbus/dbusmenu.rs.html
  - https://extensions.gnome.org/extension/615/appindicator-support/
authority: high
status: current
tier: bundled
---

# StatusNotifier Tray

@trace spec:tray-app, spec:tray-icon-lifecycle, spec:tray-minimal-ux

**Use when**: Implementing or debugging the Linux tray icon/menu path for Tillandsias.

## Provenance

- Freedesktop StatusNotifierItem spec
- DBusMenu interface shape from `dbusmenu-zbus` docs
- GNOME AppIndicator support extension

## Implementation Contract

- Linux tray is a pure D-Bus StatusNotifierItem client.
- The tray item registers a well-known service name and exposes:
  - `org.kde.StatusNotifierItem`
  - `com.canonical.dbusmenu`
- GNOME displays the tray through the AppIndicator/KStatusNotifierItem Shell extension.
- KDE consumes the same protocol directly.

## StatusNotifierItem

Required object path and registration patterns:

- Service name: `org.freedesktop.StatusNotifierItem-<pid>-1`
- Item path: `/StatusNotifierItem`
- Menu path: `/Menu`
- Watcher registration: `RegisterStatusNotifierItem(service_name)`

Required item properties:

- `Category = "ApplicationStatus"`
- `Id = "tillandsias"`
- `Title = "Tillandsias"`
- `Status = "Active" | "NeedsAttention"`
- `Menu = /Menu`
- `ItemIsMenu = true`
- `IconPixmap` carries the active tray icon pixels

## DBusMenu

Menu layout contract:

- `GetLayout` returns the current revision and the root menu node
- `Event` handles clicks on menu items
- `AboutToShow` may always return true for this tray
- `LayoutUpdated` should fire when state changes

Menu item ids used by Tillandsias:

- `select-agent:opencode-web`
- `select-agent:opencode`
- `select-agent:claude`
- `project:<name>:attach-here`
- `project:<name>:maintenance`
- `project:<name>:stop`
- `init`
- `github-login`
- `root-terminal`
- `quit`

## Menu Shape

- Status chip first
- Seedlings submenu with the three agent choices
- Per-project submenu with Attach Here, Maintenance, and conditional Stop
- Initialize images
- Root Terminal
- GitHub Login
- Version
- Quit

## Notes

- Do not use GTK as the tray backend on Linux for this path.
- Keep menu labels free of container/runtime jargon.
- Treat the tray as a thin command dispatcher, not an application window.
