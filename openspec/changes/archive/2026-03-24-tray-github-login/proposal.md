## Why
No git credentials means no pushing, cloning, or committing. Users need a one-click "GitHub Login" that runs gh auth login in a container with secrets mounted.

## What Changes
- Tray menu shows "GitHub Login" when no gh credentials exist
- Clicking it opens terminal running gh auth login + git identity setup in forge container
- Also: "Terminal" menu item on each project opens bash in forge container
- GitHubLogin and Terminal as new MenuCommand variants

## Capabilities
### New Capabilities
- `tray-auth`: GitHub Login menu item with containerized auth flow
### Modified Capabilities
- `tray-app`: Terminal menu item per project

## Impact
- Modified: menu.rs, event.rs, event_loop.rs, handlers.rs, main.rs
