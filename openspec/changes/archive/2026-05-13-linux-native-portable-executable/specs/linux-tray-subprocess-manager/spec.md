# Specification: linux-tray-subprocess-manager

@trace spec:linux-tray-subprocess-manager

## ADDED Requirements

### Requirement: Tray as subprocess manager
The tillandsias tray application (or `--tray` mode) SHALL spawn a headless tillandsias subprocess and manage its lifecycle.

#### Scenario: Tray spawns headless subprocess
- **WHEN** tillandsias is run in tray mode
- **THEN** tray process spawns `tillandsias --headless <project-path>` as a child process

#### Scenario: Tray exit cascades to headless
- **WHEN** tray receives SIGTERM or user closes tray window
- **THEN** tray sends SIGTERM to headless subprocess, waits for graceful shutdown, then exits

### Requirement: Signal forwarding
The tray application SHALL forward signals from the user to the headless subprocess.

#### Scenario: SIGTERM forwarded
- **WHEN** tray receives SIGTERM (e.g., `kill -TERM <tray-pid>`)
- **THEN** tray forwards SIGTERM to headless child, waits for shutdown

#### Scenario: SIGINT forwarded
- **WHEN** user presses CTRL-C in tray terminal
- **THEN** tray forwards SIGINT to headless child

