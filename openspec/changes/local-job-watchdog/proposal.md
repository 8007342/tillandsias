# Proposal — a forge hands a long job to a local watchdog (2081-z7sh)

Status: **proposed, design only.** Nothing is built. For operator review.

@trace order:2081-z7sh

## Why

Operator direction, 2026-11-13: containers should have NPU and GPU access,
and a watchdog for local agents should run tiny models locally, with MCP
tools whose descriptions state cost, when to use and when to prefer them,
"so you wouldn't have to use cloud minutes to babysit long running jobs,
instead merely delegate to a local model with a timer or queue". It should
be "the minimalist super safe zero-credentials offline container to run on
NPU/GPU/CPU (fallback in that order)".

The same day a forge ran a multi-hour render batch. A cloud agent attended
it with a scheduled wake every 20 to 30 minutes. Each wake re-read the
session's context to look at a checklist and restart dead workers. The work
done on each wake was mechanical; the cost was a frontier model's.

Forges have no supported way to leave a job attended. `studio.queue_workflow`
(2002-stjb) gives one tool's batch a ticket, but nothing restarts a dead
batch and nothing covers a job the agent started itself. Sleep and wake
(2014-slpw) lets a forge exit and be woken, but says nothing about a job
that keeps running meanwhile.

## What Changes

- **ADDED** capability `local-job-watchdog`:
  - A forge agent registers a long-running job with `watch.register` and
    stops attending it. The registration declares the job's command (an
    argv that is safe to run again), its progress file, and optionally a
    heartbeat file, a log and a deadline.
  - The host watches by events and one re-armed deadline timer per job.
    There is no periodic poll.
  - Each episode ends in one of three verdicts: `ok`, `restart`, `escalate`.
    Rules decide first. A tiny local model is asked only when the rules
    cannot tell, and may only pick among the verdicts the rules allow.
  - `restart` runs the declared command and nothing else, within a budget.
  - `escalate` reaches the registering agent once per episode with the
    evidence, by a lane notification, the lane inbox and a desktop
    notification.
  - The model runs in a container with no network, no credential and no
    project mount, on NPU, then GPU, then CPU, taking each only when it is
    honestly available. It never takes the GPU from a render.
  - The tool descriptions state what a watch costs, when to prefer it over
    a wake loop, what it is for and what it cannot do.

## Impact

- `crates/tillandsias-headless/src/` — a new `watchdog` module beside
  `studio_jobs.rs` (registry, observations, rules, the one action); a
  `watch.*` row in `host_tools.rs` `GROUPS`; dispatch on the lane socket; a
  non-evicting, non-waiting GPU admission in `gpu_queue.rs`; a tray notifier
  beside `notify_memory_stall`.
- `images/inference/` — a judge lane of the existing image (no second image,
  following `llama-server-lane.sh`), started with no network; one pinned
  model row in `tiers/gguf-pins.tsv` once the measurement names it.
- `images/default/` — forge instructions and the `forge-quick-intro` skill
  say when to hand a job over.
- `openspec/changes/idle-container-reaper` — a watched job counts as lane
  activity (one sentence in that change's idle definition).
- Depends on, and does not duplicate: the GPU queue (1955-rjv3, 1957-emar),
  sleep and wake (2014-slpw), deterministic wake (2012-kuw4), the wake
  classifier measurement (2012-sc0l), fleet messaging (1506-ssb5,
  2011-amqd), the NPU container rows (481, 542, 543).

Non-goals: a general agent runtime in a container (the gated zeroclaw row
is untouched); letting the model run commands, write files or compose
messages; supervising the agent harness itself (1913-q2z4); attending jobs
on another host; any cloud resource.
