---
status: implementation
owner_host: linux-guest
capability_tags: [ux, podman, events]
---
# Implementation Plan: Push Podman Events to Tray

**Filed 2026-07-07**

## Problem
The previous agent did not actually implement streaming Podman events to the tray, and instead just hardcoded the `last_event` property in `VmStatusPush` to `"tillandsias-in-vm"`. As a result, the tray is stuck saying "Ready · tillandsias-in-vm" and doesn't cycle through dynamic status updates like "Building Forge" or "Polishing Chromium" as the user requested.

## Solution
We will implement an event monitor inside `tillandsias-headless` to parse `podman events --format json` continuously, and update the `last_event` on the `VmStateHandle`, which is then pushed to the macOS tray.

### Steps
1. **Update `VmStateHandle`**: We've already added the `last_event` field and `set_last_event()` method in `crates/tillandsias-headless/src/vsock_server.rs` to allow dynamically modifying the `last_event` and pushing updates to connected clients.
2. **Spawn Event Monitor**: We need to spawn a background `tokio::task` in `main.rs` (near where `advancer` and `watcher` tasks are spawned) that executes `podman events --format json` as an asynchronous stream.
3. **Parse and Curate**: 
    - The task will read line by line from `podman events`.
    - It will parse the JSON, examine `Action` (e.g. `start`, `create`, `build`) and `Actor.Attributes.name`.
    - Depending on the container/image name, it will set `last_event` using clever, curated names (e.g. `"Building Forge"`, `"Thinkering Chromium Dev"`, `"Loading Inference"`, `"Polishing Chromium"`).
4. **Cleanup**: When `vsock_server::run_vsock_listener` finishes, the new `podman_events_monitor` task should also be aborted so that `tillandsias-headless` shuts down cleanly.

This implementation guarantees that the user receives interactive feedback in the macOS tray as the guest environment bootstraps and processes its tasks.
