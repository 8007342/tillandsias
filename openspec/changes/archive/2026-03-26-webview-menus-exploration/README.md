# webview-menus-exploration — REJECTED

**Reason**: Webview popups don't behave like native tray menus. They lack proper placement near the tray icon, feel disconnected from the tray UX, and add complexity without matching the native menu feel. The native tray submenu approach works well enough.

**Spike findings preserved in design.md**: WebviewWindowBuilder works from tray-only apps, SVG icons render in webviews, but GNOME/Wayland ignores per-window icons.
