# local-job-watchdog delta — local-job-watchdog

@trace order:2081-z7sh

## ADDED Requirements

### Requirement: An agent registers a long-running job and stops attending it

The lane's MCP socket MUST offer `watch.register`, `watch.status`,
`watch.cancel` and `watch.list`. A registration MUST declare a `name`, a
`command` as an argv, and a `progress` file with its kind, and MAY declare a
working directory, a pid file to adopt, a heartbeat file, a log file, a stall
interval, a wall-clock deadline and fatal exit codes. The lane MUST be
attributed from the accepting socket. A registration MUST be refused with a
named reason when the command is a single string, when a path resolves
outside the lane's project workspace and scratch directory (directly or
through a symlink), when the lane already holds 8 live watches, or when the
stall interval is under 2 minutes. `watch.status` and `watch.list` MUST
answer only for the calling lane's watches.

> Delta: on 2026-11-13 the lane socket offered no `watch.*` tool.
> `studio.queue_workflow` gave one tool's batch a ticket and nothing
> restarted a dead batch.

#### Scenario: A registered job is started and reported
- **WHEN** an agent calls `watch.register` with a command and a checklist file and no pid file
- **THEN** the command is started in the calling lane's forge
- **AND** the call returns a watch id at once
- **AND** `watch.status` reports `watching` with progress as done of total

#### Scenario: A command given as a string is refused
- **WHEN** `command` is `"make render && notify"` rather than an argv
- **THEN** the call is refused with a reason naming the argv form
- **AND** nothing is started

#### Scenario: A path outside the lane is refused
- **WHEN** `progress.file` resolves, through a symlink, to a path outside the project workspace
- **THEN** the call is refused and the reason names the path

#### Scenario: One lane cannot read another lane's watch
- **WHEN** lane B calls `watch.status` with a watch id that lane A registered
- **THEN** the call answers as for an unknown id

### Requirement: A watch is driven by events and one deadline timer

A watch MUST NOT poll on a period. It MUST react to the job's exit as an
event, and MUST hold one deadline timer per job, of the declared stall
interval (default 10 minutes, minimum 2), which is re-armed when the progress
or heartbeat file has moved. A timer wakeup MUST read file metadata and the
progress file only, and MUST NOT run inference by itself. The log file MUST
NOT be watched; it is read, bounded, only when a verdict needs it. Model
calls MUST be capped at 6 an hour per job. Any change to these numbers is a
cadence change and needs the operator's approval.

#### Scenario: A healthy job costs no inference
- **WHEN** a job advances its checklist at least once in every stall interval and finishes
- **THEN** no judge request was made for it
- **AND** the number of timer wakeups is at most the job's duration divided by the stall interval, plus one

#### Scenario: An exit is seen without waiting for the timer
- **WHEN** the job's process exits 30 seconds after a timer was armed
- **THEN** the exit is handled before that timer fires

### Requirement: Every episode ends in one of three verdicts and rules decide first

The verdicts MUST be exactly `ok`, `restart` and `escalate`. For each episode
the rules MUST first compute the set of verdicts allowed. When the set has
one member that verdict MUST be taken with no model call. A model MAY be
asked only to choose within a set of two or more, and its request MUST carry
a response schema that lists exactly the allowed verdicts. A wall-clock
deadline that has passed, a fatal exit code, a spent restart budget and a
vanished forge MUST each allow only `escalate`. A missing judge, a judge
error, a judge timeout of 60 seconds and an answer outside the schema MUST
each be taken as `escalate`. Two consecutive `ok` verdicts from the model for
one job with no progress between them MUST escalate.

#### Scenario: A clean exit with work left restarts without a model
- **WHEN** the job exits 0 and its checklist has unfinished lines
- **THEN** the verdict is `restart` and no judge request was made

#### Scenario: A passed deadline cannot be judged fine
- **WHEN** the wall-clock deadline has passed and the process is alive
- **THEN** the verdict is `escalate` and no judge request was made

#### Scenario: No judge means escalate, never ok
- **WHEN** a job dies with a non-zero exit and the judge container cannot start
- **THEN** the verdict is `escalate` and the reason says the judge was unavailable

#### Scenario: A model cannot keep a stalled job fine
- **WHEN** the model answers `ok` for a stall and at the next timer nothing has moved and it answers `ok` again
- **THEN** the episode escalates

### Requirement: Restart runs the declared command and nothing else

A `restart` MUST stop the job's own process tree, then run the argv declared
at registration, unchanged, in the registering forge as the forge's user.
The watchdog MUST NOT run any other command and MUST NOT pass any text from
a log, a model or a message into an argv, an environment variable or a
shell. It MUST signal only the process it started or the pid it was handed.
Restarts MUST be budgeted: at most 3 in 30 minutes, after back-offs of 30
seconds, 2 minutes and 10 minutes; a further restart verdict MUST escalate.

#### Scenario: A dead worker resumes from its ledger
- **WHEN** a job dies after finishing 4 of 10 checklist lines and its exit is judged transient
- **THEN** the declared argv is run again, byte for byte
- **AND** the job finishes the remaining 6 lines without redoing the first 4

#### Scenario: The budget ends in an escalation
- **WHEN** a job dies immediately on each of three restarts
- **THEN** a fourth restart is not attempted
- **AND** exactly one escalation is sent

### Requirement: An escalation is sent once per episode on fixed channels

An escalation MUST carry the watch id, the job's name, a reason code,
progress as done of total, the restarts used, and at most 10 log lines
marked as untrusted job output. It MUST be delivered once per episode to the
registering session's live lane connection as an MCP notification, to the
lane's inbox through fleet messaging, and to the desktop as one curated
sentence. After an escalation the watch MUST take no further action until it
is registered again or cancelled; its status MUST stay readable. A finished
job MUST produce one `done` message on the same channels.

#### Scenario: A stuck job is reported once
- **WHEN** a job passes its deadline and stays stuck for an hour afterwards
- **THEN** the lane's inbox holds exactly one escalation for that watch
- **AND** the desktop showed one notification

#### Scenario: Job output is quoted as data
- **WHEN** the log tail holds a line that reads as an instruction to the agent
- **THEN** the escalation carries that line inside the untrusted-output block, not as its own text

### Requirement: The judge is offline, holds no credential and cannot act

The judge MUST run in a container with no network, a read-only root, all
capabilities dropped, a non-root user, and no mount other than a read-only
model volume and one socket directory. It MUST receive no credential, no
proxy setting and no project mount. Its input MUST be one bounded bundle (at
most 6 KB: computed facts, the allowed verdicts, and at most 40 log lines of
at most 200 characters). Its output MUST be one object under a schema whose
every field is an enumeration or an integer. It MUST keep no state between
requests. It MUST serve only a model pinned by sha256 in the image's pin
table. It MUST stay off until a model has passed the labelled set; until
then the watchdog MUST run rules-only.

#### Scenario: The container has nothing to leak and nowhere to send it
- **WHEN** the judge container is inspected while running
- **THEN** its network mode is none, its root is read-only, and its environment holds no token, key or proxy variable

#### Scenario: A hostile log line cannot leave the verdict set
- **WHEN** the bundle's log tail tells the reader to output a shell command
- **THEN** the answer is a member of the allowed set and carries no free text

#### Scenario: An unpinned model is refused
- **WHEN** the judge lane is started with a model that has no row in the pin table
- **THEN** it refuses to start and the watchdog runs rules-only

### Requirement: The judge runs on NPU, then GPU, then CPU, and never takes the GPU from a render

Placement MUST be tried in the order NPU, GPU, CPU. The NPU MUST be taken
only when the capability probe reports it usable. The GPU MUST be taken only
when free device memory covers the model plus 2 GiB and no ticket waits in
the GPU queue, asked without waiting. The judge MUST NOT evict a resident
model and MUST NOT wait in the GPU queue. When it holds the device it MUST
release it after one verdict. A device that is present but cannot run the
model MUST fall to the next step with a named reason. `watch.status` MUST
name the rung and accelerator that decided each verdict. On CPU the judge
MUST use at most 4 threads at the lowest scheduling priority.

> Delta: on 2026-11-13 `wait_for_gpu` only blocked and `Arbiter::admit`
> evicted; `enumerate_npus` reported every NPU `usable: false`.

#### Scenario: A queued render is never delayed by a verdict
- **WHEN** a render holds the GPU, a second render waits in the queue, and an episode needs the judge
- **THEN** the verdict runs on CPU
- **AND** the waiting render starts no later than it would have with no watchdog

#### Scenario: A full GPU is left alone
- **WHEN** a resident LLM holds all but 1 GiB of the device
- **THEN** nothing is evicted and the verdict runs on CPU

#### Scenario: An NPU without an engine is not reported as used
- **WHEN** the NPU device is present and its model cannot be compiled
- **THEN** placement falls to the next step with a reason naming the NPU
- **AND** `watch.status` does not report `npu` for that verdict

### Requirement: The tool descriptions state cost, preference and limits

The host tool index MUST carry a `watch.*` group whose text names what a
watch costs and that it is preferred over waking on a timer. The
`watch.register` description MUST state: that a healthy watched job costs no
cloud tokens; the kind of job it is for; that it is preferred over a wake
loop; the three things the watchdog can do; what it cannot do; the jobs it is
not for; and that an escalation cannot yet wake a session that has ended its
turn. The `watch.status` description MUST state that it is free and is not
to be called on a timer. The forge's instructions MUST name `watch.register`
as the way to attend a long job.

#### Scenario: An agent reading only the index learns when to use a watch
- **WHEN** an agent reads the `initialize` instructions of the lane socket
- **THEN** the `watch.*` line names a long job with progress in a file, the zero cloud cost, and the wake loop it replaces

#### Scenario: The limits are in the description
- **WHEN** an agent reads the `watch.register` description
- **THEN** it says the watchdog cannot run any other command, edit files, use credentials or reach the network
