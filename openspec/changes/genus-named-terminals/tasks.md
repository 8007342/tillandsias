## 1. Add ContainerType to tillandsias-core state

- [ ] 1.1 Add `ContainerType` enum (`Forge`, `Maintenance`) to `state.rs` with `Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize` derives
- [ ] 1.2 Add `container_type: ContainerType` field to `ContainerInfo` struct
- [ ] 1.3 Default to `ContainerType::Forge` in all existing code paths that construct `ContainerInfo` (event loop discovery, handle_attach_here pre-registration)
- [ ] 1.4 Update the postcard roundtrip test to include `container_type`

## 2. Refactor handle_terminal() to use genus naming

- [ ] 2.1 Change `handle_terminal()` signature to accept `&mut TrayState` and `&mut GenusAllocator` instead of `&TrayState`
- [ ] 2.2 Allocate a genus via `allocator.allocate()` at the start of the handler
- [ ] 2.3 Build container name using `ContainerInfo::container_name()` instead of hardcoded `-terminal` suffix
- [ ] 2.4 Pre-register the container in `state.running` with `ContainerType::Maintenance` and `ContainerState::Creating`
- [ ] 2.5 Remove the don't-relaunch guard (the `terminal_container_name` / `state.running.find` block)
- [ ] 2.6 Use the allocated genus flower for the terminal window title
- [ ] 2.7 On failure (image missing, terminal spawn error), clean up: remove from `state.running`, release genus

## 3. Update event loop for new handle_terminal() signature

- [ ] 3.1 Change `MenuCommand::Terminal` arm to pass `&mut state` and `&mut allocator` to `handle_terminal()`
- [ ] 3.2 Call `on_state_change(&state)` after successful terminal launch (menu rebuild)
- [ ] 3.3 Call `prune_completed_builds(&mut state)` before state change callback

## 4. Update menu to use ContainerType for maintenance detection

- [ ] 4.1 Replace `terminal_container_name` / name-based matching in `build_project_submenu()` with `container_type == ContainerType::Maintenance` check
- [ ] 4.2 Handle the case where multiple maintenance containers exist for one project (any match means maintenance is running)
- [ ] 4.3 Derive maintenance flower from the first matching maintenance container's genus

## 5. Verify

- [ ] 5.1 `cargo check --workspace` passes
- [ ] 5.2 `cargo test --workspace` passes
- [ ] 5.3 Existing container_name and parse_container_name tests still pass
