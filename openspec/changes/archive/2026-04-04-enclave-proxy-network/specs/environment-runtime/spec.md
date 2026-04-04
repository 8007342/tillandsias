## MODIFIED Requirements

### Requirement: Attach Here launches container and opens terminal
When the user triggers "Attach Here" for a project, the system SHALL ensure the proxy container is running, ensure the enclave network exists, then launch the forge container attached to the enclave network with `HTTP_PROXY` and `HTTPS_PROXY` environment variables pointing to the proxy. The terminal SHALL open with the selected agent (OpenCode or Claude Code).

@trace spec:environment-runtime, spec:enclave-network, spec:proxy-container

#### Scenario: First Attach Here (proxy not running)
- **WHEN** the user clicks "Attach Here" and the proxy container is not running
- **THEN** the system SHALL start the proxy container first
- **AND** then launch the forge container with `HTTP_PROXY=http://proxy:3128` and `HTTPS_PROXY=http://proxy:3128`
- **AND** open the terminal with the selected agent

#### Scenario: Subsequent Attach Here (proxy already running)
- **WHEN** the user clicks "Attach Here" and the proxy container is already running
- **THEN** the system SHALL launch the forge container directly with proxy env vars
- **AND** open the terminal with the selected agent

#### Scenario: Terminal shows OpenCode
- **WHEN** the forge-opencode profile is selected
- **THEN** the OpenCode agent SHALL start inside the container
- **AND** `HTTP_PROXY` and `HTTPS_PROXY` SHALL be set for package installations

## ADDED Requirements

### Requirement: Proxy environment variables in forge containers
All forge containers SHALL have `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` environment variables set. `NO_PROXY` SHALL include `localhost,127.0.0.1,git-service` to allow local and git-daemon traffic to bypass the proxy.

@trace spec:environment-runtime, spec:proxy-container

#### Scenario: Proxy env vars present in forge
- **WHEN** a forge container is launched
- **THEN** the environment SHALL include `HTTP_PROXY=http://proxy:3128`
- **AND** `HTTPS_PROXY=http://proxy:3128`
- **AND** `NO_PROXY=localhost,127.0.0.1,git-service`

#### Scenario: Proxy env vars absent in proxy container
- **WHEN** the proxy container is launched
- **THEN** it SHALL NOT have `HTTP_PROXY` or `HTTPS_PROXY` set (it IS the proxy)
