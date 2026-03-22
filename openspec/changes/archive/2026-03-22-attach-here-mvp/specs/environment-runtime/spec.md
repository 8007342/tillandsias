## ADDED Requirements

### Requirement: Attach Here launches container and opens terminal
The "Attach Here" action SHALL build the default image if needed, start a container, and open a terminal window with OpenCode running inside.

#### Scenario: First Attach Here (image not built)
- **WHEN** the user clicks "Attach Here" and no `tillandsias-forge:latest` image exists
- **THEN** the image is built from the bundled Containerfile, then the container starts and a terminal opens

#### Scenario: Subsequent Attach Here (image cached)
- **WHEN** the user clicks "Attach Here" and the image already exists
- **THEN** the container starts immediately and a terminal opens within 5 seconds

#### Scenario: Terminal shows OpenCode
- **WHEN** the terminal opens after Attach Here
- **THEN** OpenCode is running in the terminal, ready to accept input, with the project directory mounted
