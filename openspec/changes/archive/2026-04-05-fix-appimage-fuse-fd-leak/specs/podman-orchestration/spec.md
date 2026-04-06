## ADDED Requirements

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
