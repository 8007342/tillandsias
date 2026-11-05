## ADDED Requirements

### Requirement: every held credential has a named owner for refresh, storage and propagation

The project SHALL keep one inventory of each credential Tillandsias holds, naming its lifetime, what refreshes it, where the refreshed copy is stored and which consumers read it.

#### Scenario: a credential with no refresh owner

- **WHEN** a credential is added that nothing refreshes
- **THEN** the inventory says so and states what the operator will see when it expires

### Requirement: a failed refresh reaches the operator before the credential lapses

The tray SHALL show one plain line, with the remedy for that failure class, when refreshing a credential fails repeatedly, and SHALL NOT repeat it on every attempt.

#### Scenario: refresh cannot read the store

- **WHEN** repeated refresh attempts return `read:vault-unavailable`
- **THEN** the operator sees one line naming the credential, the time it lapses if known and the next step
- **AND** no forge log is the only record

### Requirement: a refreshed credential reaches running consumers

A consumer SHALL use a refreshed or re-seeded credential without being restarted.

#### Scenario: re-seeding while a forge runs

- **WHEN** the operator signs in again while a mirror and a forge are running
- **THEN** the next push and the next provider call use the new credential, with no restart

### Requirement: a single-use refresh token is never spent twice

Rotation SHALL store the new token before anything can depend on it, and concurrent holders SHALL NOT spend one refresh token twice.

#### Scenario: two forges share an account

- **WHEN** two consumers need the same credential refreshed at the same moment
- **THEN** one rotates and the other reads the result, and neither is logged out
