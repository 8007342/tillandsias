## Why

After `Quit Tillandsias`, observed `tillandsias-*` containers occasionally remain running, kept alive by their `conmon` processes. `shutdown_all` calls `launcher.stop()` (graceful SIGTERM with 12s timeout, then SIGKILL via `podman kill`) followed by `client.remove_container()` (`podman rm -f`), and an orphan sweep with prefix `tillandsias-` — but it never **verifies** that the post-sweep state is actually empty. If any single stop returns success while the container survives (podman/conmon race, transient OCI-runtime fault), the failure is silent and `app_handle.exit(0)` fires while a container is still alive on the host.

## What Changes

- Add a post-sweep verification loop to `shutdown_all`: poll `podman ps --filter name=tillandsias- --format '{{.Names}}'` until it returns no rows or a 5-second budget elapses. Escalate any survivors with `podman kill --signal=KILL <name>` followed by `podman rm -f <name>`. Last-resort: send SIGTERM to `conmon` processes whose `--name` argument matches a `tillandsias-*` container, then re-run `podman rm -f`.
- Log every escalation step under the `accountability = true, category = "enclave"` rubric so the next session's first log lines report whether escalation was needed.
- Apply the same verification to the proxy / router / inference / git-service service containers (the orphan sweep already covers them by prefix, but the verification gives them a deterministic confirmation rather than relying on the `tillandsias-` prefix matching everything).
- The graceful-stop default (`launcher.stop` → 10s SIGTERM grace then SIGKILL) is unchanged. The verification loop kicks in only AFTER the entire existing shutdown path has completed.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `app-lifecycle`: adds a verification phase to the shutdown path. The shutdown contract now guarantees that after `shutdown_all` returns, no `tillandsias-*` container is left running on the host — escalating from graceful stop to SIGKILL to `conmon` SIGTERM as needed.
- `podman-orchestration`: documents that container teardown uses `podman kill --signal=KILL` (not `podman stop`) when the post-sweep verification finds a survivor, and that orphan-conmon `pkill` is the last-resort wipe before the tray exits.

## Impact

- `src-tauri/src/handlers.rs` — extend `shutdown_all` (`handlers.rs:3916`) with a `verify_shutdown_clean()` step after the existing orphan sweep. New helper functions: `list_running_tillandsias_containers()`, `kill_and_remove(name)`, `pkill_orphan_conmon()`.
- `crates/tillandsias-podman/src/client.rs` — extend the existing `kill_container` to accept an optional signal (currently sends default SIGTERM) so the verification loop can escalate to `--signal=KILL`.
- No spec/state changes for the tray menu.
- No changes to the forge image or container profile (the existing `--init` flag at `src-tauri/src/launch.rs:49` already gives PID 1 a proper signal-propagating init).
- Cargo: no new dependencies.
- Risk: pkill on conmon could in theory match a non-tillandsias container if a user has named a custom container `tillandsias-*` outside our flow; the existing prefix sweep already has this property, so the conmon escalation inherits it without widening the blast radius.
