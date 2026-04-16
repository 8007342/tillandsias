# Change: persistent-git-service

## Why

The per-project git-service container (`tillandsias-git-<project>`) is currently torn down by the event-loop trigger in `src-tauri/src/event_loop.rs:608-616` whenever the last forge or maintenance container for a project exits. The next "Attach Here" for the same project then has to rebuild the git-service from scratch — image staleness check (~3 s on Windows) plus container start (~1 s) plus health check.

This is the single biggest item left on the warm-launch path on Windows. Measured as ~3-4 s of every "Attach Here" after the user closes their previous forge terminal.

The git-service is otherwise architecturally similar to the proxy and inference services: it is enclave infrastructure, project-scoped, and stateless apart from the on-disk mirror cache (which already persists). There is no correctness reason to tie its lifetime to forge lifetime; doing so was a defensive choice to bound resource usage. The actual cost of leaving a git-service running is ~10 MB RAM per project — negligible compared to the latency win on every relaunch.

## What Changes

- Remove the "stop git-service when last forge dies" trigger in `event_loop.rs:608-616`. The git-service container is now tray-session-scoped: started lazily on first "Attach Here" for a project (unchanged), kept alive across forge launches (new), stopped only on app exit.
- Update `handlers::shutdown_all` (`handlers.rs:2823`) to collect git-service project names from `state.running` rows where `container_type == GitService`, instead of deriving them from "projects with active forges". The latter would miss any git-service whose forge already exited earlier in the session.
- The `EnclaveCleanupGuard` in `runner.rs:35` (CLI mode) is unchanged — CLI mode is one-shot and has no tray to host the persistent service.

## Capabilities

### Modified Capabilities
- `git-mirror-service`: container is tray-session-scoped (was: stopped when last forge for project dies). Mirrors on disk continue to persist either way; only the daemon process lifetime changes.

### New Capabilities
None — pure lifetime change to existing capability.
