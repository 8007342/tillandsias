## 1. Genus flower mapping

- [ ] 1.1 Add `flower()` method to `TillandsiaGenus` in `crates/tillandsias-core/src/genus.rs`, returning the fixed emoji for each variant
- [ ] 1.2 Verify the 8-flower pool maps 1:1 to the 8 genera (no duplicates, no gaps)

## 2. Named terminal windows

- [ ] 2.1 Change `open_terminal(command: &str)` signature to `open_terminal(command: &str, title: &str)` in `src-tauri/src/handlers.rs`
- [ ] 2.2 Update ptyxis branch to prepend `-T <title>` before `-s --new-window -x`
- [ ] 2.3 Update gnome-terminal branch to prepend `--title=<title>`
- [ ] 2.4 Update konsole branch to prepend `-p tabtitle=<title>`
- [ ] 2.5 Update xterm branch to prepend `-T <title>`
- [ ] 2.6 Update macOS osascript branch — embed title in the `do script` call if Terminal.app supports it, otherwise no-op
- [ ] 2.7 Update Windows `cmd /c start` branch to pass the title as the first positional argument to `start`

## 3. Title construction at call sites

- [ ] 3.1 In `handle_attach_here()`: construct title as `"<flower> <project_name>"` using the allocated genus and call `open_terminal(&podman_cmd, &title)`
- [ ] 3.2 In `handle_terminal()`: construct title as `"<flower> <project_name>"` — allocate or derive genus consistently with the attach path, then call `open_terminal(&podman_cmd, &title)`

## 4. Don't-relaunch guard

- [ ] 4.1 In `handle_attach_here()`: before allocating a genus, check `state.running` for any container whose `project_name` matches; if found, fire a desktop notification "Already running — look for '<flower> <project_name>' in your windows" and return early
- [ ] 4.2 In `handle_terminal()`: apply the same guard for maintenance terminals (container name pattern `tillandsias-<project>-terminal`)
- [ ] 4.3 Use `tauri::notification::Notification` (or equivalent Tauri v2 API) for the desktop notification — no modal dialog

## 5. Menu label update

- [ ] 5.1 In `build_project_submenu()` in `src-tauri/src/menu.rs`: when a project has a running container (`project.assigned_genus.is_some()`), prefix the "Attach Here" label with the flower emoji of the assigned genus
- [ ] 5.2 Apply the same prefix to the "Maintenance" terminal label when a maintenance container is already running

## 6. Verification

- [ ] 6.1 `cargo check --workspace` passes with no errors
- [ ] 6.2 `cargo test --workspace` passes
- [ ] 6.3 Manual: launch Attach Here on a project — terminal window title shows `<flower> <project_name>`
- [ ] 6.4 Manual: tray menu "Attach Here" label shows matching flower while environment is running
- [ ] 6.5 Manual: click "Attach Here" a second time — desktop notification appears, no new terminal opens
- [ ] 6.6 Manual: repeat 6.3–6.5 for Maintenance terminal
- [ ] 6.7 Manual: stop the container — menu label reverts to plain "Attach Here" with no flower
