## Why

After GitHub authentication, Tillandsias knows who the user is but offers no way to pull down their remote repositories. Users must manually `gh repo clone` from a terminal. Adding a "Remote Projects" submenu that lists GitHub repos not already cloned locally turns Tillandsias into a one-click project bootstrapper — discover, clone, and start developing.

## What Changes

- **GitHub Login → Refresh**: When valid GitHub credentials exist, change the Settings submenu label from "GitHub Login" to "GitHub Login Refresh" (re-auth still works the same way)
- **Remote Projects submenu**: New submenu under Settings that lists the authenticated user's GitHub repositories not already present under `~/src/<project>/`. Hovering expands the list.
- **One-click clone**: Clicking a remote project runs `gh repo clone <repo> ~/src/<name>` inside a forge container, then triggers a scanner rescan so the project appears in the tray menu immediately.
- **Loading state**: While fetching the repo list from GitHub, show a disabled "Loading..." item. On error, show "Could not fetch repos".

## Capabilities

### New Capabilities
- `remote-projects`: GitHub remote project listing, filtering against local projects, and clone-to-local via forge container

### Modified Capabilities
- `tray-app`: Settings submenu gains "GitHub Login Refresh" label swap and "Remote Projects" submenu

## Impact

- **Modified files**: `src-tauri/src/menu.rs` (new submenu, label swap), `src-tauri/src/handlers.rs` (clone handler), `src-tauri/src/event_loop.rs` (new menu command dispatch)
- **New file**: `src-tauri/src/github.rs` (repo list fetching via `gh` CLI in forge container)
- **Modified types**: `crates/tillandsias-core/src/event.rs` (new `MenuCommand::CloneProject` variant)
- **State addition**: `TrayState` needs a cached list of remote repos (refreshed on menu open or periodically)
