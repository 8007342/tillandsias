# job-admission-queue delta — job-admission-queue

@trace order:2094-65yz, order:2094-ay52, order:2094-mzap

## ADDED Requirements

### Requirement: An agent submits a declared job and receives a ticket at once

A lane's MCP socket MUST offer `queue.submit`, `queue.status`,
`queue.cancel` and `queue.list`. A submission MUST declare a `name`, a
`command` as an argv, whether it is `idempotent`, and a `class` from the closed set `light`, `build`,
`heavy`, and MAY declare a memory need, a GPU need and the fields a watch
accepts. `queue.submit` MUST return a ticket without waiting for admission.
The lane MUST be attributed from the accepting socket. A submission MUST be
refused with a named reason when the command is a single string, when `idempotent` is absent, when the
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

### Requirement: Every model on a host is admitted against one memory budget

Loading a model MUST be admitted like a job, against the same snapshot and the same host floor. This
applies to every model: one in a container slot, one in a host-native inference service, and the
watchdog's judge. A model's reserve MUST be its measured resident size for that engine and quantisation,
recorded as data. A resident model's reserve MUST stay subtracted until it unloads. On a host where a
guest VM and host processes share one physical memory pool (Apple unified memory), the guest's
allocation and the host service's residency MUST be counted against that one pool, never as two budgets.
A refused load MUST name the reason `memory`. The caller MUST fall to a smaller tier or to rules-only,
and MUST NOT wait unboundedly. Small models on the host and in containers are complements: the queue
MUST NOT let one tier's residency starve the jobs the others are watching.

> Delta: operator ruling 2381-778w, 2026-11-25, quoted verbatim: "our fleet leader ... is also planning on
> using small models to run babysitter jobs on the metal, and inside the containers, all of these need to
> be resource-aware and plan-aware, they all play together, and should compliment each other." Before it,
> a model load was outside admission, and on a Mac the guest and a host service could each believe the
> same memory was free.

@trace order:2381-zueb, order:2381-778w, spec:inference-engine-slots

#### Scenario: A host service model and a guest model share one budget on a Mac
- **WHEN** the guest holds 8 GiB on a 16 GiB Mac and a host-service model with a 3 GiB reserve is requested
- **THEN** admission counts the guest's 8 GiB and the host floor against the same 16 GiB
- **AND** the load is refused with reason `memory` when the remainder does not cover 3 GiB

#### Scenario: A refused judge falls to a smaller tier, not to waiting
- **WHEN** the judge's tier is refused for memory
- **THEN** the watchdog takes the next smaller tier, or rules only, at once

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
lane whose scope holds the most memory, MUST requeue that job (when it is idempotent) with a
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

### Requirement: The queue stops only what it started, and freezes a forge only as the last resort

The queue MUST NOT signal or kill a forge container, an agent harness, or
any process it did not start from a declared argv. When the level is
`critical` and no queue-started job remains, the tray MUST freeze the one
forge scope holding the most memory through the cgroup freezer, MUST NOT
kill it, and MUST send one desktop notification naming that forge and how to
thaw it. It MUST freeze at most one forge every 2 minutes. A frozen forge
MUST stay frozen until it is thawed from the tray, MUST be reported as
`frozen` to its own lane and in the tray, and MUST lose no process and no
file by being frozen or thawed.

> Delta: operator ruling 2026-11-17 (question 3). The proposal as first
> filed only notified.

#### Scenario: A job started outside the queue is not signalled
- **WHEN** the level is `critical` and the lane using the most memory runs a job its agent started from a shell
- **THEN** that job receives no signal from the tray

#### Scenario: The heaviest forge is frozen, not killed
- **WHEN** the level is `critical` and no queue-started job remains
- **THEN** the forge scope holding the most memory is frozen
- **AND** every process in it still exists
- **AND** one desktop notification names the forge and the thaw action

#### Scenario: A thawed forge resumes where it stopped
- **WHEN** a frozen forge is thawed from the tray
- **THEN** its processes continue with the same process ids
- **AND** its lane's status no longer reports `frozen`

#### Scenario: A queued job is always stopped before any forge is frozen
- **WHEN** the level is `critical` and one queue-started job is running
- **THEN** that job is stopped and requeued
- **AND** no forge is frozen in that step

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
queue never kills the caller's forge and freezes one only when memory is
critically short and no queued job is left to stop, and that the caller
waits with `watch.wait` and not a sleep loop.

#### Scenario: The index alone tells an agent when to queue
- **WHEN** an agent reads only the lane socket's initialize instructions
- **THEN** it finds a queue line naming heavy builds and tests and the risk of running them unqueued

### Requirement: A job that is not idempotent is run once and never rerun

A job submitted with `idempotent: false` MUST NOT be requeued and MUST NOT
be restarted by the watch rules. Under `critical` pressure it MUST be chosen
for stopping only when no idempotent queue-started job remains. When it is
stopped it MUST end as `failed` with the reason `stopped-memory`, reported
once to its lane with the evidence. A submission that omits `idempotent`
MUST be refused with the reason `idempotent-required`; the field MUST have
no default.

> Delta: operator requirement 2026-11-17. The proposal as first filed
> requeued every stopped job and only said in prose that a command must be
> safe to repeat.

#### Scenario: A non-idempotent job is not silently rerun
- **WHEN** a job submitted with `idempotent: false` is stopped at `critical`
- **THEN** its ticket ends as `failed` with the reason `stopped-memory`
- **AND** its command is not run again
- **AND** its lane receives exactly one message saying so

#### Scenario: Idempotent jobs are stopped first
- **WHEN** the level is `critical` and one idempotent and one non-idempotent queue-started job are running
- **THEN** the idempotent job is the one stopped and requeued

#### Scenario: The caller has to decide
- **WHEN** a submission carries no `idempotent` field
- **THEN** it is refused with `idempotent-required`
- **AND** no ticket exists

### Requirement: Every restriction is stated in the tool affordances

An agent MUST be able to learn every restriction of the queue and the watch
tools from their descriptions, schemas and responses alone. The descriptions
and schemas MUST state: that a queued job may be stopped and requeued and
that a forge may be frozen as the last resort; the three job classes with
each one's memory reserve, ceiling and running limit on this host; the retry
budget and the failures that are never retried, naming a full disk; that
`watch.wait` blocks at most 9 minutes; and that a lane sees only its own
jobs. The `queue.submit` description MUST tell the caller to submit work
that is safe to restart from its start, in bundles of a bounded size, and
MUST name the size. Every refusal and every `requeued` response MUST carry a
`reason` from a closed set and a one-sentence message, MUST carry
`retry_after_seconds` when waiting can help and omit it when it cannot, and
MUST carry the class limits when the reason concerns a class, memory or the
queue's length. Class figures in a description MUST be the figures in force
on the host that serves it.

> Delta: operator requirement 2026-11-17. The proposal as first filed put
> cost and preference in the descriptions and left ceilings, the wait bound
> and the response shape to the design text.

#### Scenario: An agent reading only the tool list splits a long suite into restartable bundles
- **WHEN** an agent that has read only the lane socket's `tools/list` and initialize instructions is asked to run a six-hour test suite
- **THEN** it submits several `queue.submit` jobs, each a bundle within the size the description names, each with `idempotent: true` and a class
- **AND** it submits no single job covering the whole suite
- **AND** it waits with `watch.wait` and starts no sleep loop

#### Scenario: A refusal carries what the caller needs to act
- **WHEN** a submission is refused because the lane already holds 16 queued jobs
- **THEN** the response carries a named `reason`, a message, `retry_after_seconds` and the class limits

#### Scenario: A refusal that waiting cannot fix says so
- **WHEN** a submission is refused because its command is a single string
- **THEN** the response carries a named `reason` and a message
- **AND** carries no `retry_after_seconds`

#### Scenario: A requeue says when and how many are left
- **WHEN** a job is stopped and requeued at `critical`
- **THEN** its lane's message carries the reason `memory`, `retry_after_seconds` and the requeues used of 3

#### Scenario: The wait bound is in the schema
- **WHEN** an agent reads the `watch.wait` input schema
- **THEN** `timeout_minutes` has a maximum of 9
- **AND** the description states that a return at the bound is not an event

#### Scenario: The class figures are this host's
- **WHEN** the `queue.submit` schema is served on a host with 16 GiB of memory
- **THEN** each `class` value's description states the reserve and running limit computed for 16 GiB

#### Scenario: Removing a restriction from a description fails a test
- **WHEN** any one of the stated restrictions is deleted from a description or schema
- **THEN** the affordance test fails and names the missing restriction
