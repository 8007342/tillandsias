# job-admission-queue delta — job-admission-queue

@trace order:2094-65yz, order:2094-ay52, order:2094-mzap

## ADDED Requirements

### Requirement: An agent submits a declared job and receives a ticket at once

A lane's MCP socket MUST offer `queue.submit`, `queue.status`,
`queue.cancel` and `queue.list`. A submission MUST declare a `name`, a
`command` as an argv and a `class` from the closed set `light`, `build`,
`heavy`, and MAY declare a memory need, a GPU need and the fields a watch
accepts. `queue.submit` MUST return a ticket without waiting for admission.
The lane MUST be attributed from the accepting socket. A submission MUST be
refused with a named reason when the command is a single string, when the
class is unknown, when the lane already holds 16 queued jobs, or when the
declared memory need exceeds the host's total memory.

> Delta: on 2026-11-17 no tool decided whether a job may start.
> `studio.queue_workflow` gave one tool's batch a ticket with no admission,
> and `gpu_queue.rs` arbitrated the GPU only.

#### Scenario: A submission returns before the job starts
- **WHEN** an agent calls `queue.submit` while the host has no room for the job's class
- **THEN** the call returns a ticket in state `queued` with a position
- **AND** nothing is started

#### Scenario: A command given as a string is refused
- **WHEN** `command` is `"cargo test && notify"` rather than an argv
- **THEN** the call is refused with a reason naming the argv form
- **AND** no ticket exists

### Requirement: A job is admitted only when the host has room for its class

Admission MUST be decided by a pure function of a snapshot: available
memory, free swap, the pressure level and the running jobs. A job MUST NOT
be admitted unless the pressure level is `calm`, available memory less the
reserves of recently admitted jobs covers the job's reserve and the host's
floor, and the job's class is under its running limit. Class reserves and
limits MUST be data, and the per-host limit MUST derive from the existing
forge budget. Admission MUST be re-evaluated on a submission, an exit and a
pressure event, and MUST NOT be re-evaluated on a periodic timer.

> Delta: on 2026-11-17 nothing stood between three simultaneous builds and
> the swap. On 2026-11-15 a forge's tests froze the desktop (2093-gfak).

#### Scenario: Simultaneous builds are admitted one at a time when memory covers one
- **WHEN** three lanes each submit a `build` job within one second and the snapshot has room for one
- **THEN** exactly one job is running
- **AND** the next is admitted when the first exits

#### Scenario: A job that has just started still counts
- **WHEN** a `build` job was admitted 10 seconds ago and has not yet allocated its memory
- **THEN** its reserve is subtracted from available memory for the next decision

#### Scenario: A calm host with an empty queue causes no wakeups
- **WHEN** no job is queued or running for 30 minutes of fixture time
- **THEN** the queue records no admission evaluation

### Requirement: Lanes take turns and a large job is not starved

Lanes with a waiting job MUST be served round-robin, one admission per lane
per round, first in first out within a lane. A host session's lane MUST be
treated as any other lane. A lane's head job that does not fit MAY be
skipped at most 3 times; after that no newer job from any lane MUST be
admitted until it fits. `queue.status` MUST name the single rule holding a
queued job from the closed set `pressure`, `memory`, `class-limit`, `turn`,
`reserved-behind`.

#### Scenario: A lane cannot starve another by submitting more
- **WHEN** lane A has 10 queued jobs and lane B submits 1
- **THEN** lane B's job is admitted no later than second

#### Scenario: Small jobs do not starve a heavy one
- **WHEN** a `heavy` job has been skipped 3 times in favour of `light` jobs
- **THEN** no further `light` job is admitted until the `heavy` job has been

### Requirement: Memory pressure arrives as an event and the queue backs off

The queue MUST learn of memory pressure from kernel pressure-stall triggers
and cgroup memory events, held open without root, and MUST NOT sample
pressure on a timer. It MUST keep one of three levels: `calm`, `tight`,
`critical`. At `tight` it MUST admit nothing. At `critical` it MUST stop one
job that it started itself, chosen as the most recently admitted job of the
lane whose scope holds the most memory, MUST requeue that job with a
back-off, and MUST tell its lane once. It MUST NOT stop more than one job
every 2 minutes. A job requeued 3 times MUST end as `escalated` with the
reason `memory`.

> Delta: on 2026-11-17 `memory_stall_watch.rs` warned and never acted, and
> systemd-oomd marked a forge scope without killing it (2093-gfak).

#### Scenario: Pressure stops admission
- **WHEN** a `tight` event arrives while two jobs wait
- **THEN** neither is admitted until the level returns to `calm`
- **AND** running jobs continue

#### Scenario: Sustained pressure stops exactly one queued job
- **WHEN** the level is `critical` and two queue-started jobs are running
- **THEN** exactly one is stopped and returned to the head of its lane
- **AND** its lane receives one `requeued` message naming the reason `memory`

### Requirement: The queue stops only what it started

The queue MUST NOT signal, freeze or stop a forge container, an agent
harness, or any process it did not start from a declared argv. When the
level is `critical` and no queue-started job remains, it MUST send one
desktop notification naming the scope using the most memory and MUST take no
further action.

#### Scenario: A job started outside the queue is untouched
- **WHEN** the level is `critical` and the lane using the most memory runs a job its agent started from a shell
- **THEN** that job receives no signal from the tray
- **AND** one desktop notification names the lane's scope

### Requirement: A lane sees only its own tickets

`queue.status`, `queue.list` and `queue.cancel` MUST answer only for the
calling lane's tickets. A lane MUST learn of other lanes only as a position
count. No answer MUST carry another lane's job name, command, project or
ticket id.

#### Scenario: Another lane's ticket is unknown
- **WHEN** lane B calls `queue.status` with a ticket id that lane A holds
- **THEN** the call answers as for an unknown id

#### Scenario: A position reveals a count and nothing else
- **WHEN** lane B's job waits behind two jobs of lane A
- **THEN** `queue.status` reports position 3 and the holding rule
- **AND** the answer contains no string from lane A's submissions

### Requirement: An admitted job is attended as a watch

An admitted job MUST be registered as a watch of the `local-job-watchdog`
capability, with the same rules, restart budget and escalation channels. The
queue MUST add only the outcome `requeued`. A job declaring a GPU need MUST
take its turn through the existing GPU queue after admission; the admission
queue MUST NOT arbitrate the GPU.

#### Scenario: A queued job that dies is restarted by its declared argv
- **WHEN** an admitted job exits 0 with its condition unmet
- **THEN** it is run again by its declared argv within the watch's budget
- **AND** it does not go back through admission for that restart

### Requirement: The queue's descriptions state cost, preference and limits

The host tool index MUST carry a `queue.*` row stating that queueing costs
no cloud tokens, that a job started outside the queue is unprotected, and
the kinds of job it is for. The `queue.submit` description MUST state that a
job may be stopped and started again and so must be safe to repeat, that the
queue never stops the caller's forge, and that the caller waits with
`watch.wait` and not a sleep loop.

#### Scenario: The index alone tells an agent when to queue
- **WHEN** an agent reads only the lane socket's initialize instructions
- **THEN** it finds a queue line naming heavy builds and tests and the risk of running them unqueued
