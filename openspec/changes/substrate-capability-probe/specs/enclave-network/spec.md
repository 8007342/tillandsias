## ADDED Requirements

### Requirement: the enclave topology is validated before any container starts

Before starting any enclave container, the launcher SHALL validate that the
topology this specification requires can be built on this host: the
internal `tillandsias-enclave` network exists or can be created, and the
egress network the proxy is dual-homed onto exists or can be created. A
topology that cannot be built SHALL be refused by name, and no container
SHALL be started; the launcher SHALL NOT fall back to a topology that
weakens isolation, such as attaching a container to the host network.

#### Scenario: a missing egress network refuses before the proxy starts

- **WHEN** the launcher runs and the egress network cannot be created or attached
- **THEN** it exits non-zero naming the egress network, and no proxy or forge container is running
