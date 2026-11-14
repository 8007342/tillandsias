## ADDED Requirements

### Requirement: the project repository holds the licence record of truth

A licence acknowledgement SHALL be a file `licences/acknowledgements/<slug>.yaml`
committed in the agreeing project's repository, and the restricted-fetch gate
SHALL read it from that repository's git and from nowhere else.

#### Scenario: a state wipe does not lose an acceptance

- **WHEN** the host state directory and the vault are wiped and rebuilt
- **AND** the project repository holds a valid committed record
- **THEN** a fetch covered by that record is admitted without asking the user again

### Requirement: the approved signers are committed beside the records

The public keys allowed to sign acknowledgements SHALL be committed at
`licences/allowed_signers`, and a signer line SHALL NOT be added in the same
commit as a record it signs.

#### Scenario: a key and a record in one commit

- **WHEN** one commit adds both a signer line and a record signed by it
- **THEN** the record is refused

### Requirement: a record verifies against the signers of the commit that added it

A record SHALL be valid only when its signature verifies against
`licences/allowed_signers` as it stood in the commit that added the record,
that commit is reachable from the integration branch, the record is unchanged
since, and it is within its expiry.

#### Scenario: a rotated key keeps old records valid

- **WHEN** a vault wipe makes a new approval key and its line is committed
- **THEN** records added under the old key still verify
- **AND** a record signed by a key never committed is refused

### Requirement: state-dir records are migrated, never dropped

Records that exist only under `<state dir>/licence-acknowledgements/` SHALL be
committed into their project repositories before that directory is removed,
and a record whose project cannot be found SHALL be reported.

#### Scenario: migration of two projects

- **WHEN** the state dir holds records for two projects
- **THEN** each project receives one commit with its records and the state copy is removed afterwards

### Requirement: every platform holds the obligation independently

Each requirement above SHALL be verified on Linux, macOS and Windows separately.

#### Scenario: per-platform evidence

- **WHEN** the change is closed
- **THEN** each platform has its own passing fixture run
