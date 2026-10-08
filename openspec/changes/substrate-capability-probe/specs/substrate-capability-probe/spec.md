## ADDED Requirements

### Requirement: one probe answers what this host can run

The system SHALL provide one substrate capability probe that prints a single
machine-readable answer naming the host's runtime substrate (rootless Podman,
macOS Virtualization.framework guest, or WSL2 distro), the capabilities that
substrate provides, and a `warnings` list. Each warning SHALL name exactly one
missing or degraded capability and carry a `why` and a `remedy`. A missing
capability SHALL appear in `warnings` exactly once, however many consumers
depend on it. The probe SHALL ask the substrate itself rather than infer
capability from an operating-system version.

#### Scenario: a capability hidden from the host is reported once

- **WHEN** the probe runs on a host where `setsid` is not on PATH
- **THEN** `warnings` contains exactly one entry naming `setsid`, with a why and a remedy

#### Scenario: a fully provisioned host reports no warnings

- **WHEN** the probe runs on a host with every capability present
- **THEN** `warnings` is empty and the substrate and capability list are present

### Requirement: preflight consumes the probe instead of refusing per guard

Preflight SHALL consult the substrate capability probe before running its
guards. A guard whose required capability appears in the probe's `warnings`
SHALL report a skip that names that warning, and SHALL NOT report its own
refusal for the same cause.

#### Scenario: one missing capability does not produce N refusals

- **WHEN** preflight runs on a host whose probe warns that `setsid` is missing
- **THEN** every guard that requires `setsid` reports a skip naming the probe warning, and no guard reports a refusal whose cause is the missing `setsid`
