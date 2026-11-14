# Design — a forge hands a long job to a local watchdog (2081-z7sh)

Status: **proposed, design only.** Nothing is built. For operator review.

@trace order:2081-z7sh, order:2014-slpw, order:2002-stjb, order:1957-emar

Research, the host probe and the prior-art survey are in
`plan/issues/local-job-watchdog-design-2026-11-13.md`. [unmeasured] marks a
number nobody has measured yet.

## 1. Shape

Three rungs, cheapest first:

| Rung | Who decides | Cost | When |
|---|---|---|---|
| 0 | Rules in the tray | No inference, no tokens | Always, first |
| 1 | A tiny local model (the judge) | Seconds of local compute | Only when the rules cannot tell |
| 2 | The cloud agent that registered the job | Cloud tokens | Only on `escalate` |

Three parts:

| Part | Lives in | Holds | Can reach |
|---|---|---|---|
| Hands | The tray (a `watchdog` module beside `studio_jobs.rs`) | The watch registry, observations, rules, the one action | What the tray already reaches: it starts every sibling container for a lane |
| Judge | A container | A model and a fixed prompt | A UNIX socket. Nothing else |
| Tools | The lane's MCP socket | `watch.register`, `watch.status`, `watch.cancel`, `watch.list` | The calling lane's own watches |

The split follows what each part may be trusted with. The hands are
deterministic Rust, testable with no model. The judge is the only part that
reads untrusted text with a model, so it is the part with no network, no
credential and no way to act.

## 2. Registering a job

`watch.register` arguments:

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | A short label for messages |
| `command` | yes | An argv. It starts the job and is the only thing a restart runs. It must be safe to run again: it resumes from its own ledger |
| `progress` | yes | `{file, kind}` where kind is `checklist` (`- [x]` and `- [ ]` lines), `lines` (one line per finished item, with `total`) or `marker` (the file exists when the job is finished) |
| `cwd` | no | A directory inside the project. Default: the project root |
| `adopt_pid_file` | no | The job is already running; this file holds its pid. Without it the watchdog starts `command` now |
| `heartbeat_file` | no | A file the job touches while it works |
| `log_file` | no | Read only when a verdict is needed, never watched |
| `stall_after_minutes` | no | Default 10, minimum 2, maximum 240 |
| `deadline_minutes` | no | Wall-clock limit. Passing it always escalates |
| `fatal_exit_codes` | no | Exit codes that must never be restarted |

Refused at registration, with a named reason: a `command` given as one
string; a path outside the project workspace or the lane's scratch
directory; a path that leaves them through a symlink; more than 8 live
watches for one lane; a `stall_after_minutes` under 2.

The command runs in the registering forge, as the forge's user, through the
exec path the product already uses for a lane. The lane is attributed from
the accepting socket, as `mcp-tool-socket` requires, never from an argument.
An agent already has a shell in its own forge, so a declared argv in that
same forge grants it nothing new. What matters is the other direction: no
part of the watchdog can run anything the agent did not declare.

## 3. Watching: events and one timer

There is no periodic poll.

| Signal | How it arrives | Wakeups |
|---|---|---|
| The job exits | The tray started it and waits on it; an adopted pid is held by a pidfd | One per exit |
| Progress or heartbeat | Read when the deadline timer fires; the timer is re-armed if either moved | See below |
| Stall | The deadline timer fires and neither moved | At most 6 an hour at the default |
| Wall-clock deadline | One timer | One |

**The cadence, stated for approval:** one deadline timer per watched job,
`stall_after_minutes` long (default 10, never under 2). At the default that
is at most 6 wakeups an hour per job. Each wakeup is a `stat` of at most
three files and no inference. Judge calls are capped at 6 an hour per job.
Nothing in the watchdog wakes more often than every 2 minutes. This is a new
cadence under the 2026-10-28 ruling and is question 1 for the operator.

The log is never watched. A chatty log would turn a file watch into a tight
poll by another name. It is read once, bounded, when a verdict needs it.

For comparison, the wake loop this replaces was 2 to 3 cloud turns an hour.

## 4. Verdicts

The closed set: `ok`, `restart`, `escalate`.

Rules first. `allowed` is the set of verdicts the rules permit for the
episode; when it has one member no model is asked.

| Observation | Rules say | Judge asked |
|---|---|---|
| Progress complete and the job exited 0 | `done`: one message, the watch ends | no |
| Progress or heartbeat moved since the last timer | `ok`, re-arm | no |
| Wall-clock deadline passed | `escalate` | no |
| Exit code in `fatal_exit_codes` | `escalate` | no |
| Restart budget spent | `escalate` | no |
| The forge is gone | `escalate` (state `orphaned`) | no |
| Exited 0, progress incomplete | `restart` | no |
| Exited non-zero or by a signal, budget remains | `{restart, escalate}` | yes: is the log tail transient or fatal |
| Alive, nothing moved for `stall_after_minutes` | `{ok, restart, escalate}` | yes: a long step, or stuck |

The judge chooses only inside `allowed`. The response schema sent with each
request lists exactly those verdicts, so the grammar cannot produce another.
When no judge is available (a floor-tier host, a failed start, a 60 second
timeout, a malformed answer) the episode escalates. The failure direction is
always toward a human or a cloud agent, never toward a silent `ok`.

A judge's `ok` on a stall doubles that job's timer, up to 60 minutes, and
two `ok` verdicts in a row with no progress between them escalate. A model
cannot keep a dead job "fine" indefinitely.

**Restart** means: stop the job's own process tree (SIGTERM, 30 seconds,
SIGKILL), then run the declared `command`. Budget: 3 restarts in 30 minutes,
after back-offs of 30 seconds, 2 minutes and 10 minutes. The numbers follow
1913-q2z4's harness supervisor. The watchdog signals only the process it
started or the pid it was handed, and only inside the registering forge.

**Escalate** happens once per episode and carries: the watch id and name,
the reason code, progress as done of total, restarts used, and up to 10
quoted log lines marked as untrusted job output. It goes, in this order, to:

1. the registering session's live lane connection, as an MCP
   `notifications/message` (the path `lane_events.rs` uses for pushes);
2. the lane's inbox through fleet messaging (`msg_send`'s store), so a
   session that is woken later finds it, with a delivery receipt;
3. the desktop, through the tray's notifier, as one curated sentence.

Waking a session that has ended its turn is 2012-kuw4 and 2014-slpw's work:
an escalation is a `wake_on` message for them. Until they land, an
escalation reaches a live session and the user, and cannot wake an idle one.
The tool description says so.

After an escalation the watch takes no further action. Its status stays
readable. The agent registers again or cancels.

## 5. The judge

**Input.** One bundle, at most 6 KB: the job's name, the facts the rules
computed (exit code or signal, seconds since progress, done of total,
restarts used), the `allowed` set, and the last 40 log lines, each cut to
200 characters and numbered. Following the July NPU proof, the model is
handed narrowed facts and asked to classify them. It is never asked to find
anything.

**Output.** One JSON object under a schema:
`{"verdict": <one of allowed>, "reason": <one of transient_error,
fatal_error, still_working, stuck, unknown>, "line": <a log line number or
0>}`. `unknown` is treated as `escalate`. No field is free text. Sentences
shown to a person are assembled by the tray from the reason code and the
quoted line.

**What a hostile log line can do.** It can push the judge toward a different
member of `allowed`. It cannot add a verdict, a command, a path or a
message. A wrong `restart` re-runs the agent's own idempotent command within
the budget. A wrong `ok` is bounded by the doubling rule and the deadline. A
wrong `escalate` costs one cloud turn.

**The container.** A lane of the existing inference image, in the way
`llama-server-lane.sh` is one: no second image and no new binary. Started on
demand at the first episode that needs it, one per host, stopped when idle.

| Property | Value |
|---|---|
| Network | `--network none`. llama-server binds a UNIX socket (`--host` ending in `.sock`) in a host runtime directory mounted into the container |
| Credentials | None. No vault token, no git remote, no proxy variables, no CA bundle |
| Filesystem | Read-only root; the model volume read-only; the socket directory is the only writable mount. No project is mounted: a bundle arrives over the socket |
| Privilege | Non-root user, all capabilities dropped, no-new-privileges, small pids and memory limits |
| State | None between requests: one slot, prompt cache off, the model unloaded after 60 idle seconds |
| Model files | Only a row pinned by sha256 in `tiers/gguf-pins.tsv`, fetched and verified by the existing host-side path. The container cannot download |
| CPU courtesy | At most 4 threads, lowest scheduling priority, so it does not compete with a render's CPU work |

**Models.** Smallest first, promoted only by measurement (2081-ngd8), as the
delegation ladder and the small-model-first ruling require.

| Tier | Model | Licence | Size on disk | Status |
|---|---|---|---|---|
| J0 | Qwen2.5-0.5B-Instruct Q4_K_M | Apache-2.0 | 0.49 GB | Already pinned (T0). No download |
| J1 | Qwen3-0.6B Q8_0 | Apache-2.0 | 0.64 GB | Official GGUF; to be pinned if J0 fails the bar |
| J2 | Qwen3-1.7B Q8_0 | Apache-2.0 | 1.83 GB | Official GGUF; to be pinned if J1 fails the bar |

The judge is off until one tier passes the labelled set. Until then the
watchdog runs rules-only and escalates every ambiguous episode. That is
already most of the saving: the common cases (finished, progressing, exited
clean with work left) need no model.

## 6. Accelerators: NPU, then GPU, then CPU

Each step is taken only when it is honestly available. Placement is chosen
when the judge container starts.

| Step | Runtime | Taken when | This host today |
|---|---|---|---|
| NPU, Intel | llama-server built with the OpenVINO backend, `GGML_OPENVINO_DEVICE=NPU`, one slot, a small fixed context; `--device /dev/accel/accel0` | The capability probe reports the NPU usable, which needs an engine that compiles for it | **Not taken.** The device is reachable from a rootless container, but there is no graph compiler in user space (measured 2026-11-13). 2081-4cpi |
| NPU, AMD XDNA2 | FastFlowLM through Lemonade (order 543's lane) | 543 has landed and the operator has accepted the licence | No such device here |
| GPU | The image's llama-server on CUDA or Vulkan | Free VRAM covers the model plus 2 GiB, and no ticket waits in the GPU queue. Checked without waiting | **Not taken.** 22.9 of 24.5 GiB was held at the probe, 21.0 GiB by a resident LLM |
| CPU | The image's llama-server, CPU backend | Always | **Taken** |

An NPU that is listed but cannot compile is a refusal that falls to the next
step, in the manner of the lane's `engine-integrity-refused` reasons. It is
never a hang and never a silent CPU run reported as NPU: `watch.status`
names the tier used for each verdict.

**GPU sharing.** One GPU job at a time stays true, and renders come first:

- The judge never calls `Arbiter::admit`. It evicts nothing.
- It never waits in `wait_for_gpu`'s queue. It asks once whether the device
  is free and uncontended; if not, the verdict runs on CPU.
- When it does take the device it holds the turn for one verdict, bounded by
  the 60 second timeout, and unloads afterwards. That bound is the most a
  render arriving in that window can wait.
- `gpu.status` lists the judge as a holder while it is loaded.

On a card shared with a studio and a resident LLM the GPU step will seldom be
taken. That is intended. A verdict is an estimated 1,500 prompt tokens and
30 output tokens [unmeasured]; the CPU is expected to carry it.

## 7. Tools and their descriptions

The descriptions are part of the design: an agent picks a tool from its
description, so each must say what it costs and when it wins.

A `watch.*` row in `host_tools.rs` `GROUPS`:

- does: "attend a long-running job in this forge so you do not have to:
  restart it from its own ledger when it dies, tell you once when it is done
  or stuck"
- starts: "watch.register starts your declared command (or adopts a running
  pid); a small offline model container starts on this computer only when a
  failure is ambiguous"
- use_when: "a job will outlive about 10 minutes and its progress shows in a
  file: a render or encode batch, a long build or test matrix, a download, a
  training run. Prefer it over waking yourself on a timer to look: a watch
  costs no cloud tokens while the job is healthy"

`watch.register`:

> Hand a long-running job in this forge to the local watchdog and stop
> attending it. Cost: no cloud tokens and no cloud minutes while the job is
> healthy; checks run on this computer (rules first, a tiny local model only
> when a failure is ambiguous). Prefer this over a wake loop (a scheduled
> wake, sleep-and-check, a cron) for any job that will outlive about 10
> minutes and shows progress in a file. You declare the command (an argv,
> no shell) that starts the job and is safe to run again because it resumes
> from its own ledger, and the progress file. The watchdog can do three
> things only: nothing, re-run your declared command (at most 3 times in 30
> minutes), or escalate to you with the evidence. It cannot run any other
> command, edit files, use credentials or reach the network. Not for: a job
> under about 10 minutes (just wait for it); a job whose restart is not safe
> to repeat; deciding what to do next (it escalates that to you). You get one
> message when the job is done or stuck. An escalation reaches a live
> session and the user's desktop; it cannot yet wake a session that has
> ended its turn.

`watch.status`:

> Read a watched job without waking anything: state, progress as done of
> total, the last verdict and its reason, restarts used, and which rung and
> accelerator decided (rules, npu, gpu or cpu). Free. Call it when you or the
> user want to know, not on a timer: the watchdog tells you when the job is
> done or stuck.

`watch.cancel` stops watching and leaves the job running. `watch.list` lists
this lane's watches.

## 8. What the watchdog can and cannot do

| It can | It cannot |
|---|---|
| Read the declared progress, heartbeat and log files of the registering lane | Read any other path, another lane or another project |
| Start the declared command in the registering forge | Run any other command, or a shell |
| Signal the process it started or the pid it was handed | Signal anything else |
| Send one escalation per episode on three fixed channels | Compose free text, push to git, open a pull request, start a build |
| Start the judge container | Give that container a network, a credential or a project mount |
| Use the GPU when it is free and uncontended | Evict a model, queue ahead of a render, or hold the device past one verdict |

Other properties:

- **Tray restart.** The registry is persisted. On start the tray re-arms
  each watch; a job it had started is re-attached by pid and process start
  time, as `dead_run.rs` identifies a run.
- **Idle reaper.** A lane with a live watch is active (one sentence added to
  the idle definition of `idle-container-reaper`).
- **Sleep and wake.** A forge that exits (2014-slpw) ends its jobs with it;
  its watches end as `orphaned` with one message. A job that must outlive
  its forge is out of scope.
- **Platforms.** Linux first. On macOS and Windows the hands run where the
  guest headless runs and the judge is CPU-only: an NPU is unreachable from
  WSL2, and a Linux VM on macOS sees neither Metal nor the Neural Engine.

## 9. Tests (from the packets' exit criteria)

- A fixture job that dies halfway through its checklist is restarted by its
  declared argv and finishes; a control whose restart is refused after the
  budget escalates exactly once (2081-v7qx).
- The tool index names cost and the wake-loop alternative, and every
  `watch.*` description states what it cannot do (2081-ic4j).
- The judge container has no network and no credential, and a log tail
  carrying an instruction still yields a member of `allowed` (2081-bgh8).
- Each model tier is scored on a labelled set of bundles; the judge stays
  off until one passes (2081-ngd8).
- With a render queued, a verdict runs on CPU and the render's wait does not
  grow (2081-fqw3).
- The Intel NPU compiles and runs a model from a rootless container, or the
  record says what blocks it (2081-4cpi).
- A stuck job produces exactly one escalation on each channel (2081-bdss).

## 10. Questions for the operator

1. Is the cadence in section 3 approved: one re-armed deadline timer per job
   at 10 minutes (floor 2), at most 6 wakeups an hour per job?
2. Is the restart budget right: 3 in 30 minutes, back-offs 30 s, 2 min, 10 min?
3. Until deterministic wake lands, is a desktop notification enough for a
   session that has ended its turn, or should the agent keep one wake at the
   job's deadline as a backstop?
4. Start the judge at the already-pinned Qwen2.5-0.5B and promote only on
   measurement?
5. May the judge image carry Intel's NPU graph compiler, once its licence
   has been read? Without it this host's NPU stays unused.
6. On a host with no local inference, escalate every ambiguous episode (the
   proposed default), or refuse `watch.register` there?
7. The gated zeroclaw row is untouched by this design. Should it now depend
   on the judge's offline lane?
