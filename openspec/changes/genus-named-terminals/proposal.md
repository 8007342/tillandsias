## Why

Terminal (Maintenance) containers are the only container type that does not use the genus naming convention. They use a fixed name `tillandsias-{project}-terminal` instead of `tillandsias-{project}-{genus}`. This causes three bugs:

1. **Name collision**: Only one Maintenance terminal per project is possible. Launching a second one would collide with the first container name.
2. **Invisible to event loop**: `parse_container_name()` expects a genus slug as the final segment. The `-terminal` suffix does not match any genus, so podman events for terminal containers are silently dropped. Terminals never appear as running in `state.running` (via podman events), and never get auto-removed when they exit.
3. **Window title collision**: Terminal window titles can collide with forge window titles because neither carries a unique genus-derived flower.

All three bugs share the same root cause: terminal containers bypass the genus naming convention.

## What Changes

- `handle_terminal()` in `handlers.rs` allocates a genus from `GenusAllocator` and names the container `tillandsias-{project}-{genus}` (same as forge containers)
- `handle_terminal()` pre-registers the container in `state.running` (same as forge containers)
- The don't-relaunch guard for terminals is removed — multiple maintenance terminals per project are now allowed (each gets a unique genus)
- `ContainerInfo` gains a `container_type` field (`ContainerType` enum: `Forge` or `Maintenance`) to distinguish the two container kinds
- Menu logic switches from name-based terminal detection (`-terminal` suffix) to type-based detection (`container_type == Maintenance`)
- The event loop passes `&mut state` and `&mut allocator` to `handle_terminal()` so it can allocate genera and register containers
- `handle_terminal()` signature changes to accept mutable state and allocator

## Capabilities

### New Capabilities
- `multi-terminal`: Users can open multiple Maintenance terminals per project, each with a unique genus name and flower icon
- `container-type-tracking`: State tracks whether a container is a forge (Attach Here) or maintenance (terminal) environment

### Modified Capabilities
- `terminal-lifecycle`: Terminal containers now participate fully in the genus/lifecycle system — they appear in Running Environments, respond to podman events, and are cleaned up on exit
- `menu-display`: Maintenance detection in the project submenu uses `container_type` instead of name matching

## Impact

- Terminal containers now follow the same naming, allocation, and lifecycle patterns as forge containers
- `parse_container_name()` works for all container types (no parser changes needed)
- Podman events for terminal containers are processed correctly
- Multiple maintenance terminals per project are supported
- No changes to the forge (Attach Here) workflow — its don't-relaunch guard remains based on `assigned_genus`
