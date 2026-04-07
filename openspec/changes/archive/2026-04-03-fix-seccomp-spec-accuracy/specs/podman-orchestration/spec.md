## MODIFIED Requirements

### Requirement: Security-hardened container defaults
Every container launched by Tillandsias SHALL include non-negotiable security flags that MUST NOT be weakened by configuration. Additional restrictions MAY be added.

#### Scenario: Default container launch
- **WHEN** a container is launched with default settings
- **THEN** the container runs with `--rm`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--security-opt=label=disable`, and `--init` (for proper PID 1 signal handling and zombie reaping)

#### Scenario: Attempting to weaken security
- **WHEN** a per-project config attempts to disable cap-drop or no-new-privileges
- **THEN** the security flags remain enforced and the weakening configuration is ignored

#### Scenario: Strengthening security
- **WHEN** a per-project config adds `read_only = true` or `network = "none"`
- **THEN** the additional restrictions are applied on top of the non-negotiable defaults

### Requirement: FUSE file descriptor sanitization before container launch
All podman command constructors (`podman_cmd_sync()` and `podman_cmd()`) SHALL close inherited file descriptors >= 3 before exec'ing the podman binary, using a POSIX-standard `pre_exec` hook.

#### Scenario: AppImage FUSE FD inheritance
- **WHEN** tillandsias runs as an AppImage with squashfuse FUSE FDs open
- **THEN** podman/crun SHALL NOT receive those FDs AND container launch SHALL succeed without OCI permission errors

#### Scenario: Standard FD preservation
- **WHEN** podman is launched
- **THEN** stdin (0), stdout (1), and stderr (2) SHALL be preserved AND only FDs >= 3 SHALL be closed

#### Scenario: Non-AppImage environments
- **WHEN** tillandsias runs from a native binary (not AppImage)
- **THEN** FD sanitization SHALL still execute (defense in depth) AND SHALL NOT affect container operation

#### Scenario: Cross-platform safety
- **WHEN** building for macOS or Windows
- **THEN** the pre_exec FD cleanup SHALL be conditionally compiled (Linux only) AND SHALL NOT cause compilation errors on other platforms

#### Scenario: Seccomp close_range elimination
- **WHEN** podman/crun starts with a pre-sanitized FD table (only FDs 0-2 open)
- **THEN** crun SHALL NOT need to call `close_range()` for FD cleanup AND the default seccomp profile's syscall restrictions SHALL NOT cause container startup failures

## REMOVED Requirements

### Requirement: Seccomp profile compatibility
**Reason**: This scenario documented "awareness" of a seccomp/close_range conflict rather than a proper fix. The pre_exec FD sanitization (FUSE FD requirement) already eliminates the close_range dependency by pre-closing all FDs >= 3, making this awareness-only scenario misleading and unnecessary.
**Migration**: The new "Seccomp close_range elimination" scenario on the FUSE FD sanitization requirement documents the architectural property that prevents this class of failures.
