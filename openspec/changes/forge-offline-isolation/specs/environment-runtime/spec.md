## MODIFIED Requirements

### Requirement: Attach Here launches container and opens terminal
When the user triggers "Attach Here", the system SHALL ensure enclave, proxy, mirror, and git service are ready. The forge container SHALL clone from the git mirror. No project directory mount, no credential mounts.

@trace spec:environment-runtime, spec:forge-offline

#### Scenario: Attach Here launches isolated forge
- **WHEN** the user clicks "Attach Here"
- **THEN** the forge container SHALL be on enclave-only network
- **AND** code SHALL come from git mirror clone
- **AND** no credentials SHALL be mounted
- **AND** cache directory SHALL still be mounted for build performance

## MODIFIED Requirements

### Requirement: Ephemeral by design
Environments SHALL be ephemeral — uncommitted changes are lost on stop. Committed changes persist through the git mirror to the host filesystem and remote (if configured).

@trace spec:environment-runtime, spec:forge-offline

#### Scenario: Environment stopped
- **WHEN** a forge container stops
- **THEN** uncommitted changes SHALL be lost
- **AND** committed changes SHALL exist in the git mirror

#### Scenario: Restart after stop
- **WHEN** a forge container is restarted for the same project
- **THEN** it SHALL clone fresh from the mirror (which has all committed work)
