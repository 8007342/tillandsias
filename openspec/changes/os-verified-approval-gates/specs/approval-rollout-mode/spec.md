## ADDED Requirements

### Requirement: every host has one explicit, visible approval mode

Each host SHALL be in exactly one mode: `present` (enrolled approval hardware,
dialogs shown, a decline stops the action), `allow` (no approval hardware,
actions run and are journaled as "not enforced: no approval hardware") or
`enforced` (a missing grant refuses the action). The mode SHALL be shown in
the tray menu and in `--diagnose`, and only the operator's tray action SHALL
change it.

#### Scenario: macuahuitl stays in allow mode

- **WHEN** a gated action runs on a host with no approval hardware
- **THEN** it runs, and its journal entry says "not enforced: no approval
  hardware"

#### Scenario: a host with Touch ID presents approvals

- **WHEN** a Mac with an enrolled Secure Enclave key requests a gated action
- **THEN** the dialog appears and a decline stops the action

#### Scenario: enforced is never automatic

- **WHEN** a host enrols a FIDO2 key
- **THEN** its mode becomes `present`, not `enforced`
