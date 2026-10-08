## ADDED Requirements

### Requirement: denied destinations are listable

The system SHALL provide a command that lists each destination the egress
proxy refused, with a count and the requesting container, read from the
proxy's access log. Allowed requests SHALL NOT appear in the list.

#### Scenario: a request outside the allowlist is listed

- **WHEN** a forge requests a host that is not on the proxy allowlist
- **THEN** the denials listing names that host with a count of at least one and the forge container as the requester

#### Scenario: an allowed request is not listed

- **WHEN** a forge requests a host on the allowlist
- **THEN** that host does not appear in the denials listing
