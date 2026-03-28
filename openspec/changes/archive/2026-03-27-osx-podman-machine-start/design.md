# Design: Auto-start podman machine

## Approach

### PodmanClient::start_machine()

- Runs `podman machine start` via `crate::podman_cmd()`
- Returns `bool` -- true if the command exits successfully, false otherwise
- Logs stdout/stderr for diagnostics on failure
- No timeout override needed -- podman machine start has its own internal timeout

### Startup sequence change (main.rs)

The auto-start is inserted between `is_machine_running()` and `podman_usable` computation:

1. Check `has_podman` and `needs_podman_machine()`
2. If machine not running, log and call `client.start_machine().await`
3. If start succeeds, set `has_machine = true`
4. If start fails, log warning and leave `has_machine = false` (decay state)
5. Compute `podman_usable` as before

### Decisions

- **No user prompt**: The machine start happens silently. Users expect the app to manage its dependencies.
- **Blocking startup**: The machine start runs before the event loop. This is acceptable because the app cannot do anything useful without the VM anyway.
- **No retry**: If the first attempt fails, we don't retry. The user can restart the app or start the machine manually.
