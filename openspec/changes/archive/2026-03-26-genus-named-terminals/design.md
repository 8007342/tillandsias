## Context

Tillandsias manages two kinds of containers per project: forge environments (via "Attach Here", running OpenCode) and maintenance terminals (via "Maintenance", running fish/bash). Forge containers follow the genus naming convention (`tillandsias-{project}-{genus}`) and are fully tracked by the event loop. Terminal containers use a fixed name (`tillandsias-{project}-terminal`) and are not tracked — they exist outside the genus system entirely.

This asymmetry means terminal containers are invisible to podman event processing, cannot be stopped from the tray, and collide when a user tries to open a second terminal for the same project.

## Goals / Non-Goals

**Goals:**
- Terminal containers use genus-based naming identical to forge containers
- Terminal containers are pre-registered in `state.running` and tracked through their full lifecycle
- Multiple maintenance terminals per project are supported
- The menu can distinguish forge from maintenance containers without relying on name suffixes
- Forge don't-relaunch guard remains unchanged (based on `assigned_genus`)

**Non-Goals:**
- Changing the forge (Attach Here) workflow
- Modifying `parse_container_name()` (it already handles `tillandsias-{project}-{genus}` format)
- Changing the podman event handler (it already handles genus-named containers)
- Adding a limit on how many maintenance terminals can run simultaneously

## Decisions

### D1: ContainerType enum distinguishes forge from maintenance

A `ContainerType` enum (`Forge`, `Maintenance`) is added to `ContainerInfo`. This is the authoritative way to know what kind of container a tracked entry represents. The menu checks this field instead of matching against a `-terminal` name suffix.

### D2: handle_terminal() mirrors handle_attach_here() for allocation

`handle_terminal()` takes `&mut TrayState` and `&mut GenusAllocator`, allocates a genus, pre-registers the container in `state.running` with `ContainerType::Maintenance`, and builds the container name using `ContainerInfo::container_name()`. This is the same pattern used by `handle_attach_here()`.

### D3: No don't-relaunch guard for maintenance terminals

Each maintenance terminal gets a unique genus name, so there is no collision risk. The fixed-name guard (`tillandsias-{project}-terminal`) is removed entirely. Users can open as many maintenance terminals as genera remain in the pool (currently 8).

### D4: Event loop passes mutable state and allocator to handle_terminal()

The `MenuCommand::Terminal` arm in the event loop changes to pass `&mut state` and `&mut allocator` to `handle_terminal()`, matching the pattern of `AttachHere`. After the handler returns, `on_state_change` is called to rebuild the menu.

### D5: Menu maintenance detection uses container_type

`build_project_submenu()` switches from checking `c.name == format!("tillandsias-{}-terminal", project.name)` to checking `c.container_type == ContainerType::Maintenance && c.project_name == project.name`. Multiple maintenance containers may match — the menu reflects all of them.
