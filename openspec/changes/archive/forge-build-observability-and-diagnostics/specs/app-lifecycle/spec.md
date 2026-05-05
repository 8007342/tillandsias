## ADDED Requirements

### Requirement: Diagnostics flag for real-time multi-container log streaming

The application launcher (both tray app and CLI mode) SHALL accept a `--diagnostics` flag that streams logs from all running containers in parallel to stdout, prefixed with container names for disambiguation.

#### Scenario: Diagnostics flag spawns log tails
- **WHEN** user runs `tillandsias tetris --opencode --diagnostics`
- **THEN** system discovers all running containers tagged `tillandsias-<project>-*`
- **AND** for each container, spawns: `podman exec <container_id> tail -f /strategic/service.log`
- **AND** prefixes each line with `[<service_name>] ` to disambiguate in garbled output

#### Scenario: Offline containers handled gracefully
- **WHEN** a container does not have `/strategic/service.log` or exits before tail starts
- **THEN** system emits `[<service_name>] [offline]` message and continues tailing other containers
- **AND** periodically re-discovers containers to detect new ones joining the stack

#### Scenario: Diagnostics mode termination
- **WHEN** user presses Ctrl+C during diagnostics mode
- **THEN** system cleanly terminates all tail processes
- **AND** exits with code 0
- **AND** does NOT trigger stack shutdown (diagnostics is observation-only)

#### Scenario: New containers during diagnostics
- **WHEN** user launches an additional container while diagnostics is running
- **THEN** system automatically discovers the new container within 5 seconds
- **AND** begins tailing its `/strategic/service.log` without user intervention

#### Scenario: Diagnostics without stack
- **WHEN** user runs `--diagnostics` but no containers are running
- **THEN** system prints "No running containers found" and exits with code 1
- **AND** does NOT start the project (diagnostics is observation-only, not startup)
