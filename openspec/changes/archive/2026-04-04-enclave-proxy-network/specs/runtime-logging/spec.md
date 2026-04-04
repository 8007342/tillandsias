## ADDED Requirements

### Requirement: Proxy accountability window
The system SHALL provide a `--log-proxy` accountability flag that enables a curated view of proxy operations. Events SHALL include domain, request size, allow/deny status, and cache hit/miss. No request content, credentials, or context parameters SHALL appear in proxy logs. Each event SHALL include a clickable `@trace spec:proxy-container` link.

@trace spec:runtime-logging, spec:proxy-container

#### Scenario: Proxy log flag enables proxy events
- **WHEN** the application is launched with `--log-proxy`
- **THEN** proxy request events SHALL be visible in the accountability output
- **AND** each event SHALL include `@trace spec:proxy-container`

#### Scenario: Proxy log excludes secrets
- **WHEN** proxy events are logged
- **THEN** no request bodies, headers, cookies, or credentials SHALL appear in the output
- **AND** only domain, size, status (allow/deny), and cache status SHALL be included

### Requirement: Enclave accountability window
The system SHALL provide a `--log-enclave` accountability flag that enables a curated view of enclave lifecycle operations. Events SHALL include network creation/removal, container attachment/detachment, and health check results. Each event SHALL include a clickable `@trace spec:enclave-network` link.

@trace spec:runtime-logging, spec:enclave-network

#### Scenario: Enclave log flag enables lifecycle events
- **WHEN** the application is launched with `--log-enclave`
- **THEN** enclave lifecycle events SHALL be visible in the accountability output
- **AND** each event SHALL include `@trace spec:enclave-network`

#### Scenario: Enclave log shows network creation
- **WHEN** the enclave network is created
- **AND** `--log-enclave` is active
- **THEN** the output SHALL show `[enclave] Network created: tillandsias-enclave`
