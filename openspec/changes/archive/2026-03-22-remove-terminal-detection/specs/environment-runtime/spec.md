## REMOVED Requirements

### Requirement: Terminal emulator detection
**Reason**: Terminal detection is brittle, platform-specific, and a non-goal. The container provides bash via podman's TTY.
**Migration**: Use `podman run -it` directly — no host terminal dependency.

## ADDED Requirements

### Requirement: Direct podman execution
The "Attach Here" handler SHALL spawn `podman run -it --rm` directly as a child process without depending on any host terminal emulator.

#### Scenario: Attach Here from tray
- **WHEN** the user clicks "Attach Here"
- **THEN** podman is spawned directly with `-it` flags and the container's bash/opencode provides the interactive interface
