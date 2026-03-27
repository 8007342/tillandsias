## MODIFIED Requirements

### Requirement: Entrypoint at system path
The forge container's entrypoint script SHALL be installed at `/usr/local/bin/tillandsias-entrypoint.sh`, not inside `/home/forge/`.

#### Scenario: Clean home directory
- **WHEN** a user runs `ls ~` inside a running forge container
- **THEN** no `entrypoint.sh` file appears in the listing

#### Scenario: Entrypoint is executable and functional
- **WHEN** the forge container starts
- **THEN** `/usr/local/bin/tillandsias-entrypoint.sh` is executed as the container entrypoint
- **AND** all shell setup (skel deployment, umask, welcome script) runs as before
