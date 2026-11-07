## ADDED Requirements

### Requirement: heavy startup steps run one at a time and wait for pressure to settle

The enclave SHALL run image builds, image pulls and copies, volume seeding and
model fetches one at a time across all projects in one runtime. Before
starting the next heavy step it SHALL wait, using a pressure-stall trigger and
not a polling loop, until I/O and memory pressure are below the configured
thresholds. Each step SHALL have its own deadline. Each step SHALL emit
`bringup: step=<name> ms=<n> settle_ms=<n>`.

#### Scenario: two projects open at once

- **WHEN** two projects start their enclaves at the same time and both need image builds
- **THEN** the builds run one after the other, never concurrently

#### Scenario: pressure is already low

- **WHEN** the previous heavy step finishes and I/O pressure is below threshold
- **THEN** the next step starts without waiting and records `settle_ms=0`

#### Scenario: pressure never settles

- **WHEN** pressure stays above threshold until the settle deadline
- **THEN** the step proceeds and logs `bringup: settle-timeout step=<name>`

### Requirement: a service is started only after its dependencies pass a readiness check

The enclave SHALL gate each dependent start on a readiness check of its
dependencies (a health check, a socket connect, or a reported Ready state).
It SHALL NOT use a fixed sleep for this. Each check SHALL have its own deadline
and its own status line.

#### Scenario: the proxy is slow to listen

- **WHEN** the proxy container is running but not yet accepting on its port
- **THEN** vault and the services after it wait for the proxy's readiness check, not for a fixed delay

#### Scenario: the router fails to start

- **WHEN** the router container exits during start
- **THEN** bringup reports the router step as failed, naming it, rather than continuing to the next service

### Requirement: optional services do not compete with or block the forge

Local inference and its model fetch SHALL start only after the forge reports
Ready. They SHALL run in the same heavy-step lane. Their failure SHALL be
reported without failing the forge.

#### Scenario: the inference image is missing on a cold start

- **WHEN** a forge is launched on a host without the inference image
- **THEN** the forge reaches Ready first, and the inference build starts afterwards

### Requirement: image layer copies are bounded

The containers.conf that Tillandsias provisions SHALL set `image_parallel_copies`
to a small bound (2 by default).

#### Scenario: a provisioned guest

- **WHEN** a macOS or Windows guest, or the Linux user runtime, is provisioned
- **THEN** its effective containers.conf reports `image_parallel_copies = 2`

### Requirement: shutdown reverses start order and failed starts back off

The enclave SHALL stop services in the reverse of their start order. A
service that fails to start SHALL be retried with an increasing delay, not
immediately.

#### Scenario: enclave shutdown

- **WHEN** the enclave stops
- **THEN** the forge stops before git, git before the router, and vault and the proxy last
