## ADDED Requirements

### Requirement: Port range allocation
The port allocator SHALL assign 20-port ranges and check actual podman container port usage before allocating.

#### Scenario: Default port range
- **WHEN** the first environment is created with default config
- **THEN** it receives port range 3000-3019

#### Scenario: Second environment
- **WHEN** a second environment is created while the first holds 3000-3019
- **THEN** it receives port range 3020-3039

#### Scenario: Orphaned container detected
- **WHEN** a tillandsias container exists in podman but not in app state, holding ports 3000-3019
- **THEN** the allocator detects the conflict via `podman ps` and shifts to the next available range

### Requirement: Stale container cleanup before allocation
The system SHALL attempt to remove orphaned tillandsias containers before allocating ports.

#### Scenario: Stale container removed
- **WHEN** a tillandsias container exists in podman but not in app state
- **THEN** `podman rm -f` is called on it before port allocation proceeds

#### Scenario: Non-tillandsias containers unaffected
- **WHEN** other containers (toolboxes, etc.) hold ports
- **THEN** they are not touched by the cleanup

### Requirement: Terminal uses allocated ports
The Terminal (Ground) handler SHALL use the port allocator instead of hardcoded port ranges.

#### Scenario: Terminal port allocation
- **WHEN** the user opens a Terminal for a project
- **THEN** ports are allocated via the same allocator as Attach Here, avoiding conflicts with other running environments
