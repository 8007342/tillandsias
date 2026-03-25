## Why

Terminal windows launched by "Attach Here" and "Maintenance" show meaningless titles like "ptyxis" or a raw `podman run ...` command string. When a user has multiple projects running simultaneously, there is no way to tell which terminal window belongs to which project. Additionally, clicking "Attach Here" on a project that already has a running container silently spawns a duplicate container, wasting resources and confusing the user.

## What Changes

- **Named terminal windows** — `open_terminal()` gains a `title` parameter; each emulator receives the appropriate title flag so the window title matches the tray menu item that launched it
- **Flower emoji per genus** — Each `TillandsiaGenus` maps to a unique flower emoji from a fixed pool; the same emoji appears in both the menu item label and the terminal window title
- **Menu item labels show flower** — "Attach Here" becomes "🌸 Attach Here" (or whichever flower is assigned) when an environment is already running, creating a 1:1 visual link between tray and window
- **Don't-relaunch guard** — `handle_attach_here()` and `handle_terminal()` check `state.running` before spawning; if a container for the project already exists, a desktop notification points the user to the existing window instead of opening another

## Capabilities

### New Capabilities

- `named-terminals`: Terminal windows have human-readable titles derived from project name and assigned flower emoji

### Modified Capabilities

- `named-terminals`: Don't-relaunch guard prevents duplicate containers and surfaces a findability notification
- `tray-app`: Menu item labels surface the assigned flower emoji when an environment is running

## Impact

- **Modified files**: `src-tauri/src/handlers.rs` (open_terminal signature, guard logic in handle_attach_here and handle_terminal), `src-tauri/src/menu.rs` (flower emoji in attach/terminal labels), `crates/tillandsias-core/src/genus.rs` (flower() method on TillandsiaGenus)
- **No new files** required
