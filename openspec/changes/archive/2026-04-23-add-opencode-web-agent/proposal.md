## Why

Terminal-based session launch is brittle across platforms: the recent Windows fix that suppressed stray console windows also disabled the Linux terminal path, leaving users without a working default. Rather than chase terminal emulator quirks across Linux, macOS, and Windows, we pivot to OpenCode's built-in web server and display it in an embedded Tauri webview — one code path for every platform, with a richer UI (OpenCode Web ships its own terminal emulator) and natural multi-session support against a single long-lived project container.

## What Changes

- Add `SelectedAgent::OpenCodeWeb` variant (env str `opencode-web`, display "OpenCode Web"). **BREAKING** in config: becomes the new default; existing installs without an explicit `agent.selected` setting will switch to web mode on next launch.
- New entrypoint `entrypoint-forge-opencode-web.sh` that runs `opencode serve --hostname 0.0.0.0 --port 4096` instead of the TUI. Installed via `Containerfile`.
- Per-project persistent container named `tillandsias-<project>-forge` (no genus) launched detached (`-d`) rather than `-it --rm`. Lifetime spans tray app, not a single session. The `-forge` suffix disambiguates from the existing `-web` containers used by the static "Serve Here" httpd feature.
- Host-side port mapping binds strictly to `127.0.0.1:<host_port>:4096`. Binding to `0.0.0.0` is forbidden. Host port allocated per project, tracked in `ContainerInfo`.
- `WebviewWindowBuilder` spawns a Tauri window per "Attach Here" click, pointing at `http://127.0.0.1:<host_port>/`. Closing the webview does **not** stop the container; the same or another webview can reattach.
- Tray menu gains "OpenCode Web" as first / default Seedlings option and a per-project "Stop" item that tears down the web container.
- `shutdown_all()` stops all web containers and closes any open webview windows.
- Existing OpenCode and Claude terminal options remain as opt-in escape hatches — no code removal.

## Capabilities

### New Capabilities
- `opencode-web-session`: how Tillandsias runs a persistent OpenCode web server per project, maps it to a local-only host port, and renders it in an embedded Tauri webview with multi-session reattach semantics.

### Modified Capabilities
- `tray-app`: Seedlings submenu adds OpenCode Web (default) and a per-project Stop item; attach-here dispatch branches on agent.
- `podman-orchestration`: detached container lifecycle and 127.0.0.1-only host port publishing are added to the existing launcher contract.
- `environment-runtime`: new `TILLANDSIAS_AGENT=opencode-web` branch in entrypoint dispatcher.
- `default-image`: adds the `entrypoint-forge-opencode-web.sh` shipped inside the forge image.
- `app-lifecycle`: `shutdown_all()` gains web-container and webview-window cleanup.

## Impact

- **Rust crates**: `tillandsias-core` (SelectedAgent enum, ContainerInfo fields), `tillandsias-podman` (detached launch, single-port publish, 127.0.0.1 bind), `src-tauri` (menu, handlers, new webview module, shutdown).
- **Forge image**: new `entrypoint-forge-opencode-web.sh`, Containerfile COPY/chmod, dispatcher in `entrypoint.sh`.
- **Config**: `AgentConfig::selected` default flips to `OpenCodeWeb`. No schema break (serde handles unknown variants gracefully via `from_str_opt`).
- **Tauri config**: no changes to `tauri.conf.json` (windows still `[]` at start; created at runtime via `WebviewWindowBuilder`).
- **Security**: host bind hardened to 127.0.0.1; enclave network isolation preserved; `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id` unchanged.
- **Linux regression**: sidestepped — default path no longer spawns a terminal emulator.
- **Docs**: new cheatsheet `docs/cheatsheets/opencode-web.md` summarizing ports, lifecycle, and multi-session.
- **i18n**: new menu strings for "OpenCode Web" and "Stop".
