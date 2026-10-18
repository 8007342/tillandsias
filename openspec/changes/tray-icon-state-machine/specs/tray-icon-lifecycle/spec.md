## ADDED Requirements

### Requirement: The tray icon blushes while containers are created and shows pups when the work completes

Every tray (Linux, macOS, Windows) SHALL draw its icon from one shared reducer whose phases are Plain, Blushing (levels 1 to 4) and Pups (operator ruling, 2026-10-17). While containers are being created, the icon SHALL blush, and the level SHALL never decrease within one run. When the work completes, the icon SHALL show pups. The first time the tray menu opens after that, the icon SHALL return to Plain. Opening the menu while the icon blushes SHALL NOT change it. A failure SHALL return the icon to Plain and SHALL NOT show pups. Health states (Dried, Stopping) SHALL override the phase. Each platform SHALL have its own icon set, and the macOS Blushing and Pups images SHALL NOT be template images.

#### Scenario: a forge launch creates its containers

- **WHEN** a launch creates three containers
- **THEN** the icon blushes as each one is created, deepening and never fading
- **AND** when the launch completes the icon shows pups

#### Scenario: the operator opens the menu after the work completed

- **WHEN** the icon shows pups and the operator opens the tray menu
- **THEN** the icon returns to Plain
- **AND** opening the menu again leaves it Plain

#### Scenario: a launch fails

- **WHEN** container creation fails mid-launch
- **THEN** the icon returns to Plain, not Pups, and the status line names the failure

## MODIFIED Requirements

### Requirement: Initial tray state is Pup

The tray SHALL start Plain. "Pup = initializing" is retired (operator ruling, 2026-10-17): pups mean finished work, and they are shown only after work completes.
