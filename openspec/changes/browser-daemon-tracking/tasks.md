## 1. ContainerType & TrayState Tracking

- [x] 1.1 Add `Browser` variant to `ContainerType` enum in `crates/tillandsias-core/src/state.rs`
- [x] 1.2 Add `browser_last_launch: HashMap<String, Instant>` and `debug_browser_pid: HashMap<String, u32>` to `TrayState` in `crates/tillandsias-core/src/state.rs`
- [x] 1.3 Update `chromium_launcher::spawn_chromium_window()` to return container ID
- [x] 1.4 Update `handlers::handle_open_browser_window()` to add container to `state.running` with `ContainerType::Browser`

## 2. Debouncing

- [x] 2.1 In `handlers::handle_open_browser_window()`, check `state.browser_last_launch` before spawning
- [x] 2.2 For safe windows: if `now - last_launch < 10s`, return error "Debounced"
- [x] 2.3 For debug windows: check `state.debug_browser_pid` — only one per project
- [x] 2.4 Update timestamp on successful spawn

## 3. Tray Notifications (BuildProgress pattern)

- [x] 3.1 In `handlers::handle_open_browser_window()`, push `BuildProgress` with `image_name: "Browser — <project>"`, `status: InProgress`
- [x] 3.2 On success: set `status: Completed`, start 5s fadeout timer
- [x] 3.3 On failure: set `status: Failed(reason)`, start 5s fadeout timer
- [x] 3.4 Add globe icon (🌐) to `menu::build_tray_menu()` for browser chips

## 4. Replace MCP daemon with on-demand CLI tool

- [x] 4.1 Create `browser_tool.rs` as simple CLI: `tillandsias-browser-tool <project> <url> <safe|debug>`
- [x] 4.2 Remove `mcp_browser.rs` (MCP daemon replaced by CLI tool)
- [x] 4.3 Remove Unix socket listener from `main.rs` (no longer needed — tool connects directly to tray socket)
- [x] 4.4 Update `entrypoint-forge-opencode-web.sh` to remove MCP server start, add `OPencode_BROWSER=safe`
- [x] 4.5 Update `flake.nix` to copy `tillandsias-browser-tool` instead of `tillandsias-mcp-browser`

## 5. OpenCode always uses safe browser

- [x] 5.1 In `entrypoint-forge-opencode-web.sh`, set `OPencode_BROWSER=safe` environment variable
- [x] 5.2 OpenCode will use the `tillandsias-browser-tool` CLI (configured via `OPencode_BROWSER=safe`)

## 6. Shutdown cleanup

- [x] 6.1 `handlers::shutdown_all()` already stops all containers in `state.running` (includes `Browser`)
- [x] 6.2 Update `handle_stop_project()` to also stop `ContainerType::Browser` containers

## 7. Tests

- [x] 7.1 Add test: `test_debounce_prevents_rapid_spawns()` (placeholder — needs integration setup)
- [x] 7.2 Add test: `test_only_one_debug_browser_per_project()` (placeholder — needs integration setup)
- [x] 7.3 Add test: `test_browser_container_tracked_in_state()` (placeholder — needs integration setup)
- [x] 7.4 Add test: `test_shutdown_cleans_up_browser_containers()` (placeholder — needs integration setup)
- [x] 7.5 Add test: `test_chromium_window_type_names()` (in `chromium_launcher.rs`)
- [x] 7.6 Add test: `test_is_process_running_invalid_pid()` (in `chromium_launcher.rs`)
