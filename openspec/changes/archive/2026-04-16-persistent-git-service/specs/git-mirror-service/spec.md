# Delta: git-mirror-service (tray-session-scoped lifetime)

## MODIFIED Requirements

### Requirement: Git-service container is tray-session-scoped

The system SHALL keep the per-project git-service container (`tillandsias-git-<project>`) running for the lifetime of the tray process, not just for the lifetime of any forge container for that project. The container SHALL be started lazily on first "Attach Here" for a project and SHALL persist across forge launches and forge exits. The container SHALL be stopped only at app exit (`shutdown_all`).

CLI mode (`tillandsias <project>`) is unchanged: the existing `EnclaveCleanupGuard` continues to stop the git-service when the CLI invocation exits.

@trace spec:git-mirror-service, spec:persistent-git-service

#### Scenario: User reattaches to a project after closing the previous forge
- **WHEN** the user closes their forge terminal for project P
- **AND** later clicks "Attach Here" on project P again
- **THEN** the next launch SHALL find the git-service for P still running
- **AND** `ensure_git_service_running` SHALL early-return without rebuilding the git-service image or starting a new container
- **AND** the warm-launch latency SHALL NOT include the ~3 s git-service rebuild that the previous (per-forge) lifetime model imposed

#### Scenario: App exits with multiple project git-services running
- **WHEN** the user exits the tray
- **AND** the in-process state has git-service rows for projects A, B, and C
- **THEN** `shutdown_all` SHALL stop all three git-service containers (in addition to proxy + inference + any forges)
- **AND** SHALL NOT leave any orphaned `tillandsias-git-*` containers

#### Scenario: Forge for a project exits, but git-service stays
- **WHEN** the last forge for project P exits
- **AND** the user is not currently exiting the tray
- **THEN** the event-loop SHALL NOT spawn a `stop_git_service(P)` task
- **AND** the git-service container for P SHALL remain in state.running ready for the next attach
