## MODIFIED Requirements

### Requirement: All enclave accountability windows emit real events
The `--log-proxy`, `--log-enclave`, and `--log-git` accountability windows SHALL emit structured events for all enclave operations. Events SHALL use the `accountability = true` field and include `@trace spec:<name>` links.

@trace spec:runtime-logging

#### Scenario: Enclave events emitted during attach
- **WHEN** the user clicks "Attach Here" with `--log-enclave` active
- **THEN** the output SHALL show network creation, proxy start, git service start, inference start, and forge launch events

#### Scenario: Git events emitted during push
- **WHEN** a forge container pushes to the mirror with `--log-git` active
- **THEN** the output SHALL show the push event and remote push result
