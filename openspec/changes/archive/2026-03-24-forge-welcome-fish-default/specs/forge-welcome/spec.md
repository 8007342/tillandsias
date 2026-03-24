## ADDED Requirements

### Requirement: Welcome message on terminal launch
The forge container SHALL display a colorful welcome message when an interactive terminal session starts.

#### Scenario: Welcome message content
- **WHEN** a user opens a terminal via the tray menu or `--bash` CLI flag
- **THEN** the welcome message displays: project name (bold cyan), forge OS + host OS versions (human-readable), mount points with access colors, project path, and a rotating tip

#### Scenario: Mount point color coding
- **WHEN** the welcome message lists mount points
- **THEN** read-write mounts are shown in green, read-only mounts in red, and encrypted-source mounts in blue

#### Scenario: Rotating tips
- **WHEN** the welcome message is displayed
- **THEN** a randomly selected tip from a pool of ~20 beginner-friendly one-liners is shown as the final line, with command keywords highlighted in bold

#### Scenario: Human-readable OS versions
- **WHEN** the welcome message shows OS information
- **THEN** it displays friendly names like "Fedora 43 (Minimal)" and "Fedora Silverblue 43", not raw kernel version strings

### Requirement: Fish as default interactive shell
The Terminal menu item and `--bash` CLI flag SHALL launch the fish shell instead of bash.

#### Scenario: Terminal from tray
- **WHEN** the user clicks a project's Terminal (Ground) menu item
- **THEN** the container starts with fish as the entrypoint, landing in the project directory

#### Scenario: CLI --bash flag
- **WHEN** the user runs `tillandsias ../project/ --bash`
- **THEN** the container starts with fish as the entrypoint, landing in the project directory

#### Scenario: Switch to bash
- **WHEN** the user types `bash` inside the fish shell
- **THEN** bash starts normally (fish is not mandatory)
