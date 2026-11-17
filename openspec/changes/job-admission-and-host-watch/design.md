# Design — jobs wait their turn, host sessions get the watchdog, and the judge runs where each host has room (2094-65yz)

Status: **proposed, design only.** Nothing is built. For operator review.

@trace order:2094-65yz, order:2081-z7sh, order:2093-gfak, order:2067-dwqd

Research, the host probe and the per-host hardware table are in
`plan/issues/local-babysitter-fleet-hardware-and-admission-research-2026-11-17.md`.
[unmeasured] marks a number nobody has measured yet. Every number in a table
below marked "proposed" is a starting value for the operator to change.

Read `openspec/changes/local-job-watchdog/design.md` first. Its three rungs
(rules, a tiny local judge, one escalation), its three verdicts, its restart
budget and its offline judge container are unchanged and are not restated.

## 1. Shape

| Part | Lives in | New here |
|---|---|---|
| Watch (2081) | The tray, `watchdog` module | Ends on a condition; declared retry policy; `watch.wait` |
| Queue | The tray, `job_queue` module | Tickets, admission, fairness, the pressure ladder |
| Host lane | The tray's MCP socket server | One listener per project for host sessions; a bridge subcommand |
| Judge placement | A data table in `images/inference/tiers/` | Per hardware capability; a memory ceiling |

The queue is deterministic Rust and asks no model anything. The judge stays
what 2081 made it: asked only when a watch's rules cannot tell, and able only
to pick one verdict from a set.

## 2. The queue

### 2.1 Submitting

`queue.submit` arguments:

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | A short label for messages |
| `command` | yes | An argv, under the same rules as `watch.register` |
| `class` | yes | `light`, `build` or `heavy` (table below) |
| `needs.memory_gib` | no | The job's own estimate. Raises the class's reserve; never lowers it |
| `needs.gpu` | no | The job takes a GPU turn through `wait_for_gpu` after admission. The queue does not arbitrate the GPU |
| `until`, `progress`, `retry`, `deadline_minutes` | no | Passed to the watch that attends the job |

It returns a ticket at once: an id, the state `queued`, and the position in
the lane's line. It never blocks until admission.

Refused at submission, each with a named reason: a `command` given as one
string; more than 16 queued jobs for one lane; `needs.memory_gib` above the
host's total memory; an unknown class.

### 2.2 Classes (proposed)

| Class | Meant for | Memory reserved at admission | Running at once on one host |
|---|---|---|---|
| `light` | A download, a render step, a script | 1 GiB | 8 |
| `build` | A compile or a test suite | the larger of 4 GiB and 10% of memory | `ForgeBudget::concurrent_forges_on_this_host()` |
| `heavy` | A release gate, an image build, a full test matrix | the larger of 8 GiB and 25% of memory | 1 |

The table is data read at start, and the per-host figure comes from
`forge_budget::ForgeBudget`, which already sizes forges by cores and memory.
No second sizing rule is introduced.

### 2.3 Admission

`admit(snapshot, waiting, running) -> decision` is a pure function, tested
with no host. The snapshot holds `MemAvailable`, free swap, the pressure
level (section 3) and the running jobs with their classes. A job is admitted
when all hold:

1. the pressure level is `calm`;
2. `MemAvailable` minus the reserves of jobs admitted in the last 2 minutes
   covers this job's reserve plus a floor of the larger of 4 GiB and 10% of
   memory (proposed);
3. its class is under its running limit;
4. it is its lane's turn.

Rule 2 counts recent admissions because a job that has just started has not
yet taken the memory it will take; without that, three builds admitted in
one second all see the same free memory.

Admission is re-evaluated on events only: a submission, a job's exit, a
pressure event, and the pressure level returning to `calm`. There is no
admission timer.

### 2.4 Fairness

- Lanes with a waiting job are served round-robin, one admission per lane per
  round. Within a lane, first in, first out.
- A host session's lane is a lane like any other.
- A lane's head job that does not fit is skipped, and the next lane is tried.
  After 3 skips it is `reserved`: nothing newer is admitted from any lane
  until it fits. Small jobs cannot starve a large one indefinitely.
- `queue.status` reports the position and the one rule that is holding the
  job (`pressure`, `memory`, `class-limit`, `turn`, `reserved-behind`), so an
  agent reads why it waits without asking a model.

### 2.5 What an admitted job is

The tray starts the argv exactly as 2081 starts a watched command: in the
submitting forge through the lane's exec path, or on the host in a scope
(section 4). From that moment it is a watch. The 2081 rules decide `ok`,
`restart` and `escalate`; the queue adds one outcome of its own, `requeued`.

## 3. Memory pressure

### 3.1 Signals, as events

| Signal | Source | Needs root |
|---|---|---|
| Stall on the forges' slice | A pressure-stall trigger on `memory.pressure` of `tillandsias.slice` | no (accepted from an unprivileged shell on macuahuitl, 2026-11-17) |
| Stall on the whole machine | A trigger on `/proc/pressure/memory` | no, with a window that is a multiple of 2 s (a 1 s window was refused) |
| A scope hits its throttle or limit | A change notification on that scope's `memory.events` | no |
| Swap nearly spent | Read from `/proc/meminfo` when one of the events above fires | no |

The tray holds the trigger file descriptors and sleeps in `poll`. The kernel
wakes it at most once per window, and only while the threshold is exceeded.
On a calm host the wakeup count is zero.

**The cadence, stated for approval** (the 2026-10-28 ruling): trigger windows
of 10 s; `tight` at 1.5 s of `some` stall in a window; `critical` at 1 s of
`full` stall in each of 3 consecutive windows, or free swap under 10%. So at
most 6 wakeups a minute while the host is actually stalling, and none
otherwise. This is question 1.

### 3.2 The ladder

| Level | Entered when | The queue does |
|---|---|---|
| `calm` | No trigger has fired for 60 s | Admits |
| `tight` | A `some` trigger fired | Stops admitting. Running jobs continue |
| `critical` | The `full` rule or the swap rule held | Stops one job (below), requeues it, tells its lane once |
| still `critical` after 2 minutes | — | Stops one more, at most one every 2 minutes. When no queue-started job remains: one desktop notification naming the scope using the most memory, through the notifier `memory_stall_watch.rs` already uses. Then nothing |

**Which job is stopped.** Among jobs the queue started, the one in the lane
whose scope holds the most memory (`memory.current`), and within that lane
the most recently admitted. Stopping is SIGTERM to the job's process tree, 30
seconds, then SIGKILL; for a host job, `cgroup.kill` on its own scope.

**Requeue.** The job returns to the head of its lane with a back-off of 2,
then 10, then 30 minutes (proposed), and is admitted only at `calm`. A third
requeue ends it as `escalated` with the reason `memory`, through the 2081
escalation channels.

### 3.3 What this is and is not

It is a bounded substitute for the kill that systemd-oomd is not delivering:
the tray stops a job it started, by a path it owns, and the job is put back
in line rather than lost.

It does not fix 2093-gfak. A job started outside the queue is not governed,
and a forge that runs away outside the queue still reaches the swap. The
queue never stops a forge, an agent harness, or any process it did not
start. Whether the tray may freeze a whole forge at `critical` when nothing
else is left is question 3, and is not designed here.

The tool description therefore has to earn its use (section 6): an agent
that starts a 20-thread build with a bare shell command has gained nothing.

## 4. Host sessions

### 4.1 The host lane

The tray opens one more listener per project it knows:
`$XDG_RUNTIME_DIR/tillandsias/mcp/<project>-host/mcp.sock`, directory mode
`0700`, socket mode `0600`, as `mcp-tool-socket` requires of every lane.
Attribution is by the accepting listener: `LaneIdentity { project, instance:
"host" }`. The directory is never mounted into any container.

The host lane carries `watch.*`, `queue.*` and `gpu.status` and nothing
else. Browser, publish, studio and cloud tools stay forge-only; a host
session has no use for them through this path and each is surface.

### 4.2 The bridge

A host session registers one stdio server in `.mcp.json`. The bridge is a
subcommand of the installed binary (the way `--msg-serve` is one in
`main.rs`), not a script: the host cannot assume `socat`, and the migration
away from shell adds none.

- It resolves the project from its working directory and connects to that
  project's host lane.
- When the tray is not running it still answers `initialize` and
  `tools/list`, and refuses each call with the named reason
  `tray-not-running` and the one command that starts the tray. It never
  hangs and never starts the tray itself.

### 4.3 Where a host job runs

In a transient systemd user scope under `tillandsias-hostjobs.slice`, a child
of `tillandsias.slice`, started with the equivalent of `systemd-run --user
--scope`. No root is involved; the user manager already delegates that
subtree.

| Property | Value |
|---|---|
| `MemoryHigh` | The class's reserve times 2 (proposed) |
| `MemoryMax` | The class's reserve times 3, never above 50% of memory (proposed) |
| `MemorySwapMax` | 0 for `light`; unset for the others |
| Working directory | The project checkout, or a directory inside it |
| Environment | The session's, as inherited by the bridge. The tray adds nothing and no credential |

The ceiling is the point. A host gate that runs away is stopped by the
kernel inside its own scope, and the desktop keeps its memory.

The job belongs to the tray's scope, not to the agent harness. It survives
the harness reaping its background tasks and the harness's 10-minute limit
on a foreground command.

### 4.4 Isolation, stated honestly

| Boundary | Holds |
|---|---|
| A forge cannot see or reach the host lane | yes: never mounted, and the socket is the attribution |
| A forge sees only its own lane's jobs and tickets | yes: as `mcp-tool-socket` and the forge log visibility ruling require |
| A forge can learn that others are waiting | only as a count: `queue.status` gives a position, never another lane's job name, command or project |
| One host session cannot read another's jobs | **no.** Processes of one user can open one another's sockets. The host lane is attribution, not a wall |

### 4.5 Waking the requester

In order, for a job's `done`, `requeued`, `escalated` and (once) `admitted`:

1. an MCP `notifications/message` on the requester's live connection, the
   path `lane_events.rs` uses;
2. the lane inbox, through fleet messaging, with a receipt;
3. the desktop, for `escalated` only.

No harness today wakes an ended turn on a notification (2012-kuw4 and
2014-slpw). Until one does, the working path is **`watch.wait`**: it takes a
watch or ticket id and `timeout_minutes` (default 9, maximum 9, under the
harness's 10-minute tool limit), blocks, and returns on the next event or at
the bound with the current status. It costs no tokens while it blocks and
asks the judge nothing. One call replaces a sleep loop; a job that outlives
it costs one more call per 9 minutes, about 7 cloud turns an hour at worst.
That figure is part of question 1.

## 5. Conditions and retry policy on a watch

Two additions to `watch.register`, and so to an admitted job.

**`until`** replaces `progress` when a job has no checklist:

| Kind | Finished when | Evaluated |
|---|---|---|
| `exit` | The command exits; `ok_codes` (default `[0]`) decides done or failed | On the exit event |
| `marker_line` | A line of the declared log equals, or starts with, a declared literal. An optional second literal means failed | On exit, and when the deadline timer fires |
| `file_exists` | A declared path inside the lane exists | On exit, and when the deadline timer fires |

Literals only: no regular expression, no shell, no command to run as a
probe. A log is still never watched; it is read, bounded, at the two moments
above. A marker that can only be seen by a model is not a condition: that is
what the judge is for.

**`retry`** declares the policy as data:

| Field | Default (2081) | Ceiling |
|---|---|---|
| `max` | 3 | 3 in 30 minutes |
| `backoff_seconds` | `[30, 120, 600]` | Each at least 30 |
| `on_exit_codes` | any not in `fatal_exit_codes` | — |
| `never_on_log_literals` | none | Up to 8 literals; a match in the last 40 log lines makes the episode `escalate` without a judge |

`never_on_log_literals` is where a caller writes what today's measurement
showed a small model gets wrong: `No space left on device` is not retried.
A built-in list of such literals (disk full, out of memory, permission
denied) ships as data and is always applied.

A policy can narrow the 2081 budget and cannot widen it.

## 6. Tool descriptions

As in 2081 section 7, the descriptions are part of the design.

A `queue.*` row in `host_tools.rs` `GROUPS`:

- does: "start a heavy job when this computer has room for it, and attend
  it: other projects' jobs and yours take turns, and a job is paused and
  retried instead of freezing the machine"
- starts: "queue.submit starts your declared command when memory allows; no
  model and no container is started by queueing"
- use_when: "any compile, test suite, image build or batch that uses many
  cores or several GiB. Prefer it over running the command yourself: a job
  started outside the queue is not protected and can stall every project on
  this computer"

`queue.submit`:

> Start a heavy command when this computer has room, instead of now. Cost:
> no cloud tokens; the wait is local. You declare the command (an argv, no
> shell) and its class: light, build or heavy. You get a ticket at once and
> one message when it is admitted, done, requeued or stuck. If memory runs
> short, a job started here may be stopped and started again later, so the
> command must be safe to run again. The queue cannot run any other command,
> and never stops your forge or you. Not for: a command that finishes in
> under a minute; a job that cannot be restarted. To wait, call watch.wait
> once; do not sleep and look.

`watch.wait`:

> Wait for a watched or queued job's next event (admitted, done, requeued,
> stuck) inside one call. Free while it waits: no tokens, no model. Returns
> at the event, or after timeout_minutes (9 at most) with the current
> status. Use it instead of a sleep loop or a scheduled wake.

## 7. Judge placement

### 7.1 The table

Keyed by what the capability probe reports (`accel_probe.rs`), never by a
host's name. First usable row wins; CPU is always last and always present.

| Capability | Runtime | Where | Taken when | Fleet example | State on 2026-11-17 |
|---|---|---|---|---|---|
| Intel NPU with a compiler | llama.cpp's OpenVINO backend or OpenVINO Model Server | The judge container, `/dev/accel/accel0` | 2081-4cpi passes | macuahuitl | Blocked: no graph compiler, licence unread |
| AMD XDNA2 NPU, Linux | FastFlowLM through Lemonade (order 543) | A container or the host, as 543 decides | 543 lands and the licence is accepted | yoga | Blocked: licence decision. Decode 51 to 53 tokens/s for Qwen3-0.6B was measured there on 2026-07-31 |
| Integrated GPU beside a discrete GPU | llama-server on Vulkan, the device named explicitly | The judge container, `/dev/dri` (SLOT-4) | The integrated device is idle. The discrete device is never used by this row | lenovinha, yoga | [unmeasured] |
| Discrete GPU | As 2081 section 6: only when free and uncontended | The judge container | — | macuahuitl | Seldom taken, by design |
| Apple Metal | llama-server or Ollama on the macOS host | Host process (7.3) | Question 4 is ruled yes | MacBook Air | [unmeasured] |
| XDNA2 NPU or integrated GPU, Windows side | FastFlowLM through Lemonade, or llama-server on Vulkan | Host process (7.3) | Question 4 is ruled yes; for the NPU, the 543 licence too | yolanda | [unmeasured] |
| CPU | llama-server, 4 threads at most, lowest priority | The judge container (in the guest on macOS and Windows) | Always | every host | 42.9 tokens/s decode for Qwen2.5-0.5B on macuahuitl |
| No engine | — | — | Rules only; ambiguous episodes escalate | esmeraldinha, MacBook Neo | As 2081 question 6 |

### 7.2 Memory

Every laptop in the fleet has 13 to 16 GiB. The judge's ceiling follows the
host, not the model's reputation:

| Host memory | Largest judge tier | Resident ceiling (proposed) |
|---|---|---|
| under 12 GiB | none: rules only | — |
| 12 to 24 GiB | J1 (Qwen3-0.6B) | 1 GiB |
| over 24 GiB | J2 (Qwen3-1.7B), or a 1B-class alternative that scores better on 2081-ngd8 | 3 GiB |

- The context window is set to 4,096 tokens. A bundle is at most 6 KB; the
  runtime's default of 32,768 held a 397 MB model at 936 MB on macuahuitl.
- The judge does not load unless the pressure level is `calm` and
  `MemAvailable` covers its ceiling plus 1 GiB. Otherwise the episode
  escalates, as "no judge means escalate" already requires.
- It unloads after 60 idle seconds (2081).

No model above about 2B parameters is proposed. A 7B model decoded at 5.3
tokens/s on macuahuitl's CPU and held 6.9 GB.

### 7.3 A judge outside a container

On macOS the Linux guest sees neither Metal nor the Neural Engine; on
Windows the NPU and the integrated GPU are invisible to WSL2. Using them
means a judge process on the host, where `--network none` does not exist.
What replaces it, if the operator allows it at all:

| Property | Container judge (2081) | Host judge |
|---|---|---|
| Network | `--network none` | The platform's process sandbox denies all network; the process listens on a UNIX socket or a named pipe and on no TCP port |
| Credentials | None in the container | Started with an empty environment and no access to the vault or keychain |
| Files | Read-only root, the model volume read-only | Read access to the pinned model file; write access to its socket directory only |
| Proof | 2081-bgh8's arm | The same arm, run on that platform: an outbound connection attempted from inside the judge process fails |
| Client | The tray | The tray only |

If the proof cannot be made on a platform, the row is not taken there and
the judge stays on CPU in the guest. This is question 4.

The Apple Neural Engine is not proposed: the only language-model path found
is beta, short-context and reported slower than Metal.

## 8. Platforms

Linux first, for all three capabilities.

| | Queue | Pressure events | Host lane and scopes |
|---|---|---|---|
| Linux, bare metal | yes | Pressure-stall triggers and `memory.events` | yes |
| macOS and Windows, forge jobs | yes, in the guest where the headless tray runs | The guest's own pressure files: the guest is the machine the forges share | — |
| macOS and Windows, host sessions | Later, with each platform's own job object and memory-pressure notification | Not designed here | Not designed here |

## 9. Tests (from the packets' exit criteria)

- Three lanes submit builds in one second on a fixture snapshot with room
  for one: one runs, and the other two are admitted in turn as each exits
  (2094-ay52).
- A lane that submits 10 jobs and a lane that submits 1 are served
  alternately (2094-ay52).
- A fixture pressure event at `tight` admits nothing; at `critical` exactly
  one queue-started job is stopped and requeued, and a control job the queue
  did not start is untouched (2094-mzap).
- On macuahuitl, a real job that allocates past its scope's `MemoryMax` is
  stopped inside its scope while the desktop's pressure stays under the
  `tight` threshold (2094-dyvk).
- A host session with the tray stopped gets `tray-not-running` from every
  call, within a second (2094-dyvk).
- A watch with `until.marker_line` finishes on the literal and not on a line
  that merely contains it; a log tail with `No space left on device`
  escalates with no judge request (2094-y2bb).
- Per hardware tier, the judge's decode rate and resident size are recorded
  on a real host of that tier, and the placement row is taken or refused by
  name (2094-s3ub, 2094-p3i3, 2094-zzg9, 2094-7t4f, 2094-3r2k).

## 10. Questions for the operator

These are in addition to the seven of 2081-z7sh, which still stand.

1. Is the pressure cadence approved: kernel pressure events in 10-second
   windows, so at most 6 wakeups a minute while the computer is actually
   stalling and none when it is calm; and `watch.wait` blocking up to 9
   minutes per call?
2. May the queue stop and requeue a job that it started itself when memory
   is critically short, without asking first?
3. When memory is critically short and no queued job is left to stop, should
   the tray freeze the forge using the most memory, or only notify you?
4. May the judge run as a host process on macOS and Windows, sandboxed with
   no network, to reach Metal and the Windows-side NPU; or does it stay on
   CPU inside the guest there?
5. Should heavy commands inside forges (builds, test suites, image builds)
   be required to go through the queue, or stay voluntary with the tool
   description as the only steer?
6. Are the three job classes and their memory reserves in section 2.2 the
   right starting values?
7. May the idle integrated GPU on a two-GPU laptop be used for the judge, as
   the one exception to the discrete-GPU-preferred policy?
8. For the two AMD NPUs: will you read and decide FastFlowLM's licence
   (order 543), or should those hosts stay on CPU and integrated GPU?
