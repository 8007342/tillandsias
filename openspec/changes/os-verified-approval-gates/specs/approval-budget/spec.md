## ADDED Requirements

### Requirement: budgeted routine releases need no approval

The daily build, a configured number of optional extra builds per day, and the
daily promotion to stable SHALL run without approval while within budget. Only
out-of-band actions, meaning over-budget releases and cloud actions outside
the policy, SHALL be gated.

#### Scenario: the daily build runs unattended

- **WHEN** the scheduled daily build dispatches its workflow
- **THEN** no dialog appears and the budget counter increments

#### Scenario: an over-budget build asks

- **WHEN** the extra-build count for the day is exhausted and another build is
  requested
- **THEN** the request is gated

### Requirement: budget policy and counters are out of agents' reach

The budget policy and its counters SHALL live in Vault, writable only by the
approval broker and release tooling.

#### Scenario: an agent cannot reset its budget

- **WHEN** an agent-held credential writes the budget path
- **THEN** Vault denies it
