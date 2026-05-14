# Specification: clean-app-exit-semantics

@trace spec:clean-app-exit-semantics

## ADDED Requirements

### Requirement: SIGTERM triggers graceful container shutdown
The tillandsias process SHALL register a SIGTERM handler that initiates graceful shutdown of all containers.

#### Scenario: SIGTERM received
- **WHEN** tillandsias receives SIGTERM
- **THEN** handler calls stop_all_containers() with 30-second timeout

#### Scenario: Containers stop within timeout
- **WHEN** containers finish stopping before timeout
- **THEN** process exits immediately with code 0

#### Scenario: Containers exceed timeout
- **WHEN** containers do not stop within 30 seconds
- **THEN** process sends SIGKILL to remaining containers and exits with code 143 (SIGTERM + 128)

### Requirement: No orphaned containers on exit
The tillandsias process SHALL ensure all containers are cleaned up on exit, regardless of shutdown path (signal, panic, normal exit).

#### Scenario: Normal exit
- **WHEN** tillandsias completes normally
- **THEN** all containers are stopped and removed

#### Scenario: Panic cleanup
- **WHEN** tillandsias panics
- **THEN** drop guard or finalizer ensures container cleanup before process termination

### Requirement: Secrets cleanup on exit
The tillandsias process SHALL delete all podman secrets on exit.

#### Scenario: Secrets deleted on clean exit
- **WHEN** tillandsias exits normally
- **THEN** podman secrets tillandsias-* are deleted

