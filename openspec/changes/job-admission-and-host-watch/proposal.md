# Proposal — jobs wait their turn, host sessions get the watchdog, and the judge runs where each host has room (2094-65yz)

Status: **design only; the eight questions were ruled on 2026-11-17**
(design.md section 10). Nothing is built.

@trace order:2094-65yz, order:2081-z7sh

This change extends `openspec/changes/local-job-watchdog` (2081-z7sh). It
repeats none of it. Research and today's measurements are in
`plan/issues/local-babysitter-fleet-hardware-and-admission-research-2026-11-17.md`.

## Why

Operator direction, 2026-11-17: babysitting long-running tasks moves off
cloud-model minutes and off `until grep ... ; sleep` loops onto small local
models on the fleet's own hardware. The babysitter checks status, retries
sensibly, minds memory, and queues work so several forges share one computer
fairly. It must serve forges and agent sessions running directly on the host.

The watchdog designed on 2026-11-13 attends one job in one forge. Four things
are outside it:

1. **Nothing decides whether a job may start.** On the night of 2026-11-15 a
   forge's runaway tests starved macuahuitl of memory and froze the desktop.
   systemd-oomd marked the forge's scope for killing every 15 seconds and the
   kill never landed (2093-gfak). `memory_stall_watch.rs` warns and does not
   act. Three forges and a host gate can each start a 20-thread build in the
   same minute.
2. **A host session has no tool.** The release gates run on the host. Their
   waiters are shell loops: 314 `sleep` lines across 135 files under
   `scripts/` and `skills/`. The harness reaps a background waiter under
   memory pressure and kills a foreground one at its 10-minute limit.
3. **One host was probed.** The fleet has two AMD XDNA2 NPUs, an Apple M5 and
   an idle integrated GPU beside a discrete one. The 2026-11-13 design runs
   the judge on CPU on macOS and Windows because the accelerator is outside
   the guest.
4. **A watch ends on a progress file only.** Most host waits are "this line
   appears in that log" or "this command exits".

## What Changes

- **ADDED** capability `job-admission-queue`:
  - `queue.submit` takes a declared job (an argv, a class, optional needs)
    and returns a ticket at once. `queue.status`, `queue.cancel` and
    `queue.list` answer for the calling lane only.
  - A job starts when the host has memory headroom for its class, no
    memory-pressure event is active, and its lane's turn has come. Lanes are
    served round-robin; a lane cannot starve another by submitting more.
  - Memory pressure arrives as a kernel event, not a poll. Under pressure
    the queue stops admitting. Under sustained pressure it stops one job
    that it started itself and puts it back in line with a back-off.
  - It never kills a forge, an agent, or a job it did not start. As the
    last resort, with no queued job left to stop, the tray freezes (does not
    kill) the forge using the most memory and tells the operator.
  - An admitted job is a watch: the 2026-11-13 rules, restart budget and
    escalation apply to it unchanged.
- **ADDED** capability `host-session-job-tools`:
  - A host agent session reaches `watch.*` and `queue.*` through a host lane
    of the same tray socket, with a stdio bridge that is a subcommand of the
    installed binary. No shell is added.
  - A host job runs in its own transient systemd user scope with a memory
    ceiling, so it outlives the session's tool call and cannot take the
    desktop down with it.
  - `watch.wait` blocks until the job's next event or a bound, so a session
    waits inside one tool call instead of sleeping and looking.
- **ADDED** capability `watchdog-judge-placement`:
  - Where the judge runs is a data table keyed by hardware capability, not
    by host name: CPU everywhere; Intel NPU, AMD XDNA2 NPU, an integrated
    GPU beside a discrete one, and Apple Metal each when measured usable.
  - The judge has a memory ceiling by host size and does not load under
    memory pressure.
  - On macOS and Windows the accelerator is outside the guest. A judge
    outside a container is offered only behind an operator ruling, with its
    own offline proof.
- **ADDED** requirements on `local-job-watchdog`:
  - A watch may end on a declared condition from a closed set (a literal
    marker line in a declared log, a file that exists, an exit), not only a
    progress file.
  - A registration may declare its retry policy as data, inside the ceiling
    the 2026-11-13 design fixes.

## Impact

- `crates/tillandsias-headless/src/` — a `job_queue` module beside the
  `watchdog` module of 2081-v7qx (tickets, the admission function, the
  pressure listener); a `queue.*` row in `host_tools.rs` `GROUPS`; dispatch
  in `mcp_socket.rs` beside the `gpu.*` arm; a host lane listener; a bridge
  subcommand in `main.rs`; the tool-set assertions in `tray/mod.rs`.
- `crates/tillandsias-core/src/forge_budget.rs` — the class table reads
  `ForgeBudget::for_this_host` for host size. No new sizing rule.
- `images/inference/tiers/` — one placement table as data.
- `.mcp.json` — one more stdio server for host sessions.
- `openspec/changes/local-job-watchdog` — amended in place only by the
  operator's rulings on its own seven questions; the requirements added here
  merge into that capability when both are synced.
- Depends on: 2081-v7qx (the watch registry and rules), 2081-bdss
  (escalation channels), `gpu_queue.rs` for GPU turns. Related, not
  replaced: 2093-gfak (the oomd defect still has to be found), 2067-dwqd
  (the stall warning stays), 1913-ebv8 and 1913-fh6l (oomd posture and
  `memory.low`).
- No bash is added. Jobs, classes, retry policies and placements are
  declared data. Language: Rust, because the babysitter lives in the tray.
  The operator's language order is Lua, then Rust, then Go (relayed
  2026-11-17); nothing here needs Go.

Non-goals: fixing systemd-oomd (2093-gfak); governing a job that was not
submitted through the queue; killing a forge; a scheduler across
hosts; any cloud resource; a judge that takes a GPU from a render; the Apple
Neural Engine; replacing `gpu_queue.rs` or `scripts/land-queue.sh`.
