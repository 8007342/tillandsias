# local-job-watchdog delta — local-job-watchdog

@trace order:2094-65yz, order:2094-y2bb, order:2081-z7sh

These requirements are added to the capability that
`openspec/changes/local-job-watchdog` introduces. They are synced after that
change, never before it.

## ADDED Requirements

### Requirement: A watch may end on a declared condition

A registration MAY declare `until` in place of `progress`, with a kind from
the closed set `exit`, `marker_line`, `file_exists`. `marker_line` MUST
match a declared literal against a whole line or the start of a line of a
declared log inside the lane, and MAY declare a second literal meaning
failed. A condition MUST NOT be a regular expression, a shell fragment or a
command to run. `marker_line` and `file_exists` MUST be evaluated only when
the job exits and when the watch's deadline timer fires; the log MUST NOT be
watched for changes.

> Delta: on 2026-11-13 a watch ended on a progress file of kind checklist,
> lines or marker. A host gate that prints a verdict line had no fit.

#### Scenario: A verdict line finishes the watch
- **WHEN** a watch declares `until: {kind: marker_line, done: "ok:gate"}` and the log gains the line `ok:gate` before the job exits 0
- **THEN** the watch reports `done` at the exit

#### Scenario: A line that merely contains the literal does not match
- **WHEN** the log's only matching text is `echo would print ok:gate later`
- **THEN** the condition is unmet

#### Scenario: A regular expression is refused
- **WHEN** a registration declares a `marker_line` kind with a `pattern` field
- **THEN** the call is refused with a reason naming literals

### Requirement: A retry policy is declared data inside the fixed budget

A registration MAY declare `retry` with a maximum, back-off seconds, the
exit codes to retry on, and up to 8 log literals that must never be retried.
A declared policy MUST NOT exceed the capability's restart budget or go
under its smallest back-off. A built-in list of never-retried literals,
shipped as data and including a full disk, exhausted memory and a refused
permission, MUST always apply. A match of a never-retried literal in the
bounded log tail MUST make the episode `escalate` without a judge request.

> Delta: on 2026-11-13 the budget was fixed at 3 restarts in 30 minutes with
> only `fatal_exit_codes` declared. On 2026-11-17 two local models at
> temperature 0 judged a `No space left on device` build failure retryable.

#### Scenario: A full disk is never retried
- **WHEN** a job exits non-zero and its log tail contains `No space left on device`
- **THEN** the episode escalates with the reason naming the literal
- **AND** no judge request is made and the command is not run again

#### Scenario: A policy cannot widen the budget
- **WHEN** a registration declares `retry.max` of 10
- **THEN** the call is refused with a reason naming the ceiling
