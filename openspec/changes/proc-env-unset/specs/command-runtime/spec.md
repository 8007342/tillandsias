## ADDED Requirements

### Requirement: A call can drop inherited names from its child
<!-- req-id: 2305zm8j -->

`proc.run{}`, `proc.spawn{}` and each `proc.chain` stage SHALL accept
`env_unset`, a list of variable names or of name prefixes ending in one `*`. A
name it matches SHALL be absent from what the child inherits. The runtime's fixed
values and the call's own `env` literals SHALL be applied after it. A bare `*`, an
empty name or a value that is not a list of strings SHALL raise before anything is
spawned. A call without `env_unset` SHALL start its child from the same
environment as before.

#### Scenario: A gate variable does not reach the subject

- **WHEN** the runner's environment carries `TILLANDSIAS_BIN` and
  `CARGO_TARGET_DIR`, and a script calls `proc.run` with
  `env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" }`
- **THEN** neither name is in the child's environment

#### Scenario: The call's own literal wins

- **WHEN** the same call also passes `env = { TILLANDSIAS_BIN = "/mine" }`
- **THEN** the child sees `TILLANDSIAS_BIN=/mine`
