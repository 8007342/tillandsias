## ADDED Requirements

### Requirement: Every Tillandsias container has a class with a declared idle budget

Every container the product creates MUST be labelled at launch with
`tillandsias.class`, `tillandsias.owner-pid`, `tillandsias.launched-at` and
`tillandsias.lane`. The classes and their idle budgets MUST come from one
table read by the launcher, the reaper and the status reporters:
`lane` (forge, its browser windows and forwarders, toolchain and sidecar
containers) at least 30 minutes; `preview` (the project's web preview) at
least 3 hours; `project-infra` (git mirror, lane-scoped inference) 30
minutes after the last `lane` container they serve is gone; `core` (vault,
proxy, router, nix-cache, GitHub login) never while an owner lives. A
container not minted by the product MUST NOT be classified and MUST NOT be
touched. Every budget MUST be overridable by environment for fixtures only.

> Delta: on 2026-10-19 no container carried a class, an owner or a budget;
> `SHARED_STACK_SCOPES` knew only `Core` and `LaneScoped`.

#### Scenario: A forge launch labels itself and its children
- **WHEN** a lane launches a forge and the forge opens a browser window
- **THEN** both containers carry `tillandsias.class=lane`, the launcher's pid as `tillandsias.owner-pid` and the same `tillandsias.lane`
- **AND** the web preview the lane publishes carries `tillandsias.class=preview`

#### Scenario: A foreign container is never classified
- **WHEN** `tillandsias-builder` or a `tillandsias-dev-*` container exists
- **THEN** a sweep lists it as `skip:foreign` and never stops it

### Requirement: Idle is measured per class from real activity

A `lane` container's idle time MUST be the time since the last PTY or
control-wire session activity, the last request accepted on its lane MCP
socket, the last exec the product started in it, or the last browser-window
activity, whichever is latest. The clock MUST survive a restart of the
measuring process (persisted under the runtime dir); a missing clock MUST
fall back to `tillandsias.launched-at`, never to "now". A `preview`'s idle
time MUST be the time since the router last served its route or its lane
last called a preview tool; when the router cannot answer, the preview MUST
count as active. `project-infra` and `core` MUST use the live-lane refcount
plus the grace, with no clock of their own.

#### Scenario: A silent forge with an attached session is not idle
- **WHEN** a forge has an open PTY session and produces no output for longer than the budget
- **THEN** the sweep reports it `keep` because the session is attached

#### Scenario: A preview that is being read is not idle
- **WHEN** a browser requests the preview's route once within every budget window
- **THEN** the sweep never stops it

#### Scenario: The clock survives a tray restart
- **WHEN** the tray restarts 20 minutes into a lane's silence
- **THEN** the lane is reaped 10 minutes later, not 30

### Requirement: Orphans are detected and reaped after their class budget

A container whose `tillandsias.owner-pid` is not a live process and whose
lane no live Tillandsias process has adopted MUST be recorded as orphaned at
the first sweep that observes it. It MUST NOT be stopped at once: its class
budget applies from the later of its last activity and the orphan
observation. `core` containers MUST be reaped only when orphaned and no
`lane` container has existed for 30 minutes.

> Delta: a terminal killed on 2026-10-19 left a forge, a git mirror and a
> preview running with no process that would ever stop them.

#### Scenario: The launcher's terminal is killed
- **WHEN** a CLI lane's terminal is killed with SIGKILL
- **THEN** within one sweep the forge is listed `owner=gone`
- **AND** the forge is stopped only once its `lane` budget of silence has elapsed
- **AND** the preview is stopped only once its `preview` budget has elapsed

### Requirement: A watchdog that outlives any launcher sweeps the classes

The sweep MUST run while the tray or the guest headless runs, from the
existing liveness supervisor, at a bounded cadence. On Linux a CLI lane
launch with no tray MUST arm a transient `systemd --user` timer that runs
`tillandsias --internal-reap-sweep` (or, without systemd, a detached sweep
loop); the unit MUST be idempotent across launches and MUST end when no
product container remains. On macOS and Windows the guest headless MUST run
the sweep. No persistent service or cron MUST be installed.

#### Scenario: No tray, launcher dead, sweep still runs
- **WHEN** a CLI lane was launched with no tray and its launcher is killed
- **THEN** a sweep still runs within one cadence
- **AND** `systemctl --user list-timers` shows no `tillandsias-reap` timer once the last product container is gone

### Requirement: One sweep is idempotent, lock-protected and loud

`reap_sweep` MUST take the `reaper` resource lock and skip (not wait) when
it is held; MUST act on nothing while container mutations are refused by the
runtime phase; MUST skip a lane with a launch-in-flight marker; MUST re-read
the idle clock under the lane's lock immediately before stopping; and MUST
print one verdict line per container
(`reap: <class> <name> idle=<secs> budget=<secs> owner=<alive|gone> -> keep|stop|skip:<why>`).
A sweep that cannot list containers MUST act on nothing and say so.
`--dry-run` MUST print the same verdicts and stop nothing.

#### Scenario: Two sweeps overlap
- **WHEN** a timer-driven sweep starts while the tray's sweep holds the lock
- **THEN** the second prints `skip:locked` and exits 0 without stopping anything

#### Scenario: A sweep during drain
- **WHEN** the runtime phase refuses container mutations
- **THEN** every verdict reads `skip:draining`

### Requirement: Reaping is graceful per class

A `lane` forge MUST be stopped with `podman stop -t 10`, then removed, then
its labelled children removed with no grace (they are stateless); a
`preview` MUST be removed with no grace (1723-2fiq) and its route removed,
and a reap record (`reaped_at`, `reason`, `runtime`, `app_dir`, `config`)
MUST be written for its lane; `project-infra` and `core` MUST follow the
existing stack cleanup. The force-kill escalation and the 30 s cap are the
`graceful-shutdown` ones.

#### Scenario: A reaped preview leaves a record and no route
- **WHEN** the sweep stops an idle preview
- **THEN** the container and its router route are gone
- **AND** the lane's reap record names the runtime and app_dir it ran with
