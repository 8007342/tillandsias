## ADDED Requirements

### Requirement: A detached run leaves its group to the caller when the leader exits
<!-- req-id: 2294dtch -->

A grouped run SHALL reap its process group when the leader exits, unless the
caller sets `detach`. With `detach = true` (Lua `proc.run{}` / `proc.spawn{}`,
`tillandsias_exec::Command::detach`), the runtime SHALL NOT reap the group when
the leader exits, whether it exits by itself or by a signal from outside, so a
caller can observe what the leader left behind. The deadline, a cancel and the
script scope's close SHALL still kill the whole group. `detach` without a group
SHALL be refused. On Windows, where a job object owns the group, `detach`
SHALL change nothing.

#### Scenario: A leaked grandchild is visible after a detached run

- **WHEN** a script runs `bash leak.sh` with `detach = true`, and the script
  backgrounds `sleep 30` and exits 0
- **THEN** the run reports `exited` with code 0
- **AND** the grandchild is still alive when the call returns

#### Scenario: Without detach the same grandchild is reaped

- **WHEN** the same script runs without `detach`
- **THEN** the grandchild is gone within the reap's grace

#### Scenario: A detached run still dies whole at its deadline

- **WHEN** a detached run's leader outlives its `timeout_ms`
- **THEN** the run reports `timed_out` and its grandchild is killed with it

#### Scenario: detach without a group is refused

- **WHEN** a script passes `group = false, detach = true`
- **THEN** the call raises and nothing is spawned
