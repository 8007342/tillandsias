## Why

The `tillandsias-web` image was designed and built (see archived `2026-03-22-web-image` change) but is not yet wired into the tray app or CLI. A user cannot launch a web container from the tray menu or via `tillandsias --web <path>`. The image exists in `flake.nix`, the entrypoint exists at `images/web/entrypoint.sh`, but there is no UI surface to use it.

With the modular entrypoints and config-driven launch changes, web container support becomes a natural extension: define a `[web]` container profile, add a "Serve Here" menu item, and wire the launch path. The web container:

- Mounts `<project>/public/` or `<project>/dist/` (or the project root) at `/var/www`
- Serves on `localhost:<port>` only (no external access)
- Uses the `tillandsias-web` image (tiny, no dev tools)
- No secrets, no agents, no git — just a file server
- Shows the URL in the terminal and optionally opens the browser

This completes the "forge + serve" workflow: the user develops in a forge container, then previews in a web container.

## What Changes

- **Tray menu**: Add "Serve Here" action to project submenus (alongside "Attach Here" and "Maintenance")
- **CLI mode**: Add `tillandsias --web <path>` to launch a web container from the terminal
- **Container profile**: Define `[web]` profile with minimal mounts (project dir only), no secrets, port 8080
- **Image build**: Ensure `build-image.sh` supports `web` image type (already works — just needs wiring from tray)
- **Browser open**: Optionally open `http://localhost:<port>` after the container starts

## Capabilities

### New Capabilities
- `web-runtime`: Launch a minimal httpd container from the tray or CLI to serve static files locally

### Modified Capabilities
- `tray-app`: "Serve Here" menu item for each project
- `podman-orchestration`: Web container lifecycle management (start, stop, detect running)

## Impact

- **New files**: None (web image and entrypoint already exist)
- **Modified files**: `src-tauri/src/handlers.rs` (add `handle_serve_here`), `src-tauri/src/runner.rs` (add `--web` flag), `src-tauri/src/menu.rs` or equivalent (add menu item)
- **Image**: Uses existing `tillandsias-web` image from `flake.nix`
- **Ports**: Default 8080, configurable via project config
- **Privacy**: Web container sees ZERO secrets — only the static files mount
