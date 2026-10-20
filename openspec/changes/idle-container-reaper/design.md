# Design: idle-container-reaper

Code is cited by symbol. Timeouts are the defaults; every one is overridable
by an environment variable so a fixture can run the whole life cycle in
seconds (`TILLANDSIAS_IDLE_BUDGET_<CLASS>_SECS`, `TILLANDSIAS_REAP_SWEEP_SECS`).

## What exists (survey, 2026-10-19, origin/linux-next 4e4fd5925)

Each line: mechanism — what it guarantees — the gap against the requirement.

- `main.rs` `cleanup_shared_stack_if_no_running_forge` /
  `cleanup_stack_containers` / `SHARED_STACK_SCOPES` — on a foreground
  lane's exit, removes the lane's git container and the `LaneScoped`
  inference container when no `tillandsias-*-forge` is alive; `Core`
  (vault, proxy, router, nix-cache) lives for the application lifetime.
  Gap: runs only from the exiting launcher; a killed launcher never reaches
  it; forges themselves are never reaped.
- `main.rs` `is_active_lane_container` — counts a lane alive while its
  container is in any non-terminal podman state. Gap: "alive" means
  "exists", never "someone is using it".
- `main.rs` `acquire_launch_in_flight_marker` / `foreign_launches_in_flight`
  — pid-named flocks protect a sibling's pre-create window from teardown.
  Kept: the reaper must honour them.
- `local_web_preview.rs` `cleanup_departed_lane` (called from the two lane
  exit paths in `main.rs`) — removes `tillandsias-<project>-web` and its
  route under the `preview-<project>` and `preview-router` locks. Gap:
  same trigger problem; and it removes a preview whose agent may be back in
  five minutes, while the operator wants a 3 h budget.
- `local_web_preview.rs` `reload_inner` (1723-2fiq) — recreates an exited
  preview from the `tillandsias.preview.runtime` / `.app-dir` labels.
  Kept: this is the relaunch primitive. Gap: a removed container has no
  labels to read, so a reaped preview answers `not_running`, which agents
  read as an error.
- `tray-ux` "Stale container cleanup" (tray startup sweep) — removes
  untracked `tillandsias-*` on tray start. Gap: only on start; nothing
  during the session.
- `main.rs` `[liveness]` supervisor + `container_deps::LivenessProbe::run_check`
  — re-ensures missing Core containers in the Ready phase, nudged by podman
  down events, 60 s / 300 s backstops. Kept: the natural host for the sweep
  while the tray runs. Gap: it only adds, never removes.
- `window_registry.rs` `WindowEntry::is_idle_timeout` (24 h) /
  `is_lifetime_exceeded` (48 h) / `find_timed_out_windows` — Gap: no caller
  outside tests; the clock is never driven.
- `host-shell/lifecycle.rs` drain (`DEFAULT_FORGE_DRAIN_TIMEOUT_MS` 10 s,
  `HARD_STOP_DEADLINE` 30 s), `graceful-shutdown` spec (30 s then kill),
  `runtime_phase::container_mutations_allowed` — the stop sequence and the
  "no mutations while draining" gate. Kept and reused.
- `image_ensure_marker.rs` `RETRY_BUDGET`, `busy_retry_after_secs` —
  image-build backoff and the `retry_after` contract (operator ruling).
  Kept: a relaunch that needs an image goes through `ensure_image_exists`
  and inherits it.
- `control-wire` `crashloop` (guest VM only), `scripts/forge-liveness-probe.sh`
  (classifies, kills nothing), `container-teardown-straggler-probe.sh`
  (post-teardown check), 1560-73zh (guest powers off when the tray
  heartbeat stops; ready, unimplemented). None is a per-container idle
  reaper.
- Labels today: `tillandsias.preview.{lane,forge,runtime,config,app-dir}`,
  `tillandsias.lane`, `tillandsias.role`, `tillandsias.browser-window`,
  `tillandsias.toolchain`. Gap: no class, no owner pid, no idle budget.
- Events: `forge-diagnostics-scope` names `gc.reap {resource, count}` as a
  curated `GlobalEvent` kind; nothing in `crates/` implements `GlobalEvent`
  yet (1779-sq9g). The GC paths `eprintln!`.

## Container classes and idle budgets

One table, `CONTAINER_CLASSES`, declared next to `SHARED_STACK_SCOPES` and
read by the launcher (to label), the reaper (to budget) and the status
reporters (to explain). Every container Tillandsias creates is labelled at
launch with `tillandsias.class=<class>`, `tillandsias.owner-pid=<pid>` (the
launcher: tray or CLI process), `tillandsias.lane=<project>/<instance>` (as
1779-sq9g 1.1 already requires), and `tillandsias.launched-at=<unix>`.

| class | members (name patterns) | idle budget | idle means |
|---|---|---|---|
| `lane` | `tillandsias-<p>-forge`, `tillandsias-<p>-<i>-forge`, `ssh-sidecar-*`, `browser-*` windows and forwarders, `tillandsias.toolchain` containers, `status-check-*` | **30 min** | no PTY/control-wire session attached, no MCP request on the lane socket, no `podman exec` started by us, and no browser-window activity, for the whole budget |
| `preview` | `tillandsias-<p>-web` (static or wrangler, the "baby web container") | **3 h** | no request routed to its route by the router, and no `publish_local`/`service_reload`/`service_status` from its lane, for the whole budget |
| `project-infra` | `tillandsias-git-<p>` (mirror), `tillandsias-inference` (`LaneScoped`) | **30 min after the last `lane` container of its project (or of any project for inference) is gone** | refcount, as today, plus the grace |
| `core` | `tillandsias-vault`, `tillandsias-proxy`, `tillandsias-router`, `tillandsias-nix-cache`, `tillandsias-github-login-*` | **never idle-reaped while an owner lives**; orphan rule below | — |
| `foreign` | `tillandsias-builder`, `tillandsias-dev-*`, anything not minted by us (`is_stack_managed_name` false) | never touched | — |

Browser windows keep their 24 h / 48 h registry caps as an upper bound; the
`lane` budget is what actually drives `find_timed_out_windows` now. A window
with activity keeps its lane alive.

A lane is the unit of reaping: when a forge is reaped, its labelled children
go with it in the same sweep, so the forge-log scope (own + children) and
the reap unit coincide.

## How idle is measured

- `lane`: the headless process keeps `last_activity[lane]`, touched by: PTY
  attach/data, control-wire session open, an accepted lane MCP connection or
  request (`mcp_socket.rs`), an exec we start, a browser-window
  `touch_window_activity`. It is persisted to
  `$XDG_RUNTIME_DIR/tillandsias/idle/<lane>` (guest: its runtime dir) as a
  unix timestamp on each touch (write-once-per-minute coalesced), so a
  restarted tray reads the real clock instead of resetting it to "now".
  A missing file means "launched-at" from the label — conservative, never
  earlier.
- `preview`: the router sidecar records `last_request[route]` and exposes it
  on its control socket (`route_activity` query). Reaper reads that; if the
  router cannot answer, the preview is treated as active (fail to keep).
- `project-infra` and `core`: no clock; refcount of live `lane` containers
  plus the grace.

## Orphans (unclean terminal exit)

A container is **orphaned** when `tillandsias.owner-pid` is not a live
process (`/proc/<pid>` on Linux, `kill -0` in the guest) and no live
Tillandsias process has adopted the lane (the tray adopts every lane it can
see on start). An orphaned container is not reaped at once: its class
budget still applies, counted from the later of its last activity and the
moment the orphan was first observed. So a forge whose terminal died keeps
running for 30 min of silence (a detached agent may still be finishing
work), and a preview for 3 h. Orphaned `core` containers — no tray, no CLI
lane, no live lane container — are reaped 30 min after the last lane
container is gone, the same as `project-infra`. This is the only case where
`core` is reaped outside tray shutdown.

## The watchdog

- While the tray (or the guest headless) runs: the `[liveness]` supervisor
  runs `reap_sweep()` on its existing cadence (at most every
  `TILLANDSIAS_REAP_SWEEP_SECS`, default 300 s).
- Linux, no tray (CLI lane killed with its terminal): every CLI lane launch
  arms a transient `systemd --user` timer
  (`systemd-run --user --unit=tillandsias-reap --on-active=300 --on-unit-active=300 tillandsias --internal-reap-sweep`,
  idempotent: an existing unit is left alone). Without systemd (toolbox,
  container-in-container) the launch spawns a detached
  `tillandsias --internal-reap-sweep --loop` whose own exit condition is
  "nothing of ours is left". Operator ruling honoured: this is the product
  arming its own transient unit, never a persistent cron the operator did
  not ask for; the unit disappears with the last container.
- macOS and Windows: the headless process in the guest is the watchdog and
  is alive whenever the VM is; a dead host tray is the 1560-73zh case (guest
  powers off), which is stricter than a reap.

`reap_sweep()` is one idempotent pass: list our containers, classify, decide
per container, act, and print one verdict line per decision
(`reap: <class> <name> idle=<secs> budget=<secs> owner=<alive|gone> -> keep|stop|skip:<why>`).
It takes the `reaper` resource lock (skip, never wait, if held), refuses to
act while `runtime_phase::container_mutations_allowed()` is false, skips any
lane with a launch-in-flight marker, and re-reads the idle clock under the
per-lane lock just before stopping (TOCTOU). A sweep that cannot list
containers acts on nothing and says so.

## Graceful stop sequence

1. `lane` forge: `podman stop -t 10` (SIGTERM reaches the agent harness,
   which flushes its own state — the forge's pre-stop hook writes
   `.forge-heartbeat` final), wait, `podman rm`; then its children with
   `rm -f -t 0` (windows, forwarders, toolchain, sidecar).
2. `preview`: `remove_now` (`rm -f -t 0`, 1723-2fiq: the static server is
   PID 1 and ignores SIGTERM) and `remove_route`; a **reap record** is
   written under the lane's state dir (`preview/<project>/reaped.json`:
   `reaped_at`, `reason`, `runtime`, `app_dir`, `config`) so the status can
   explain and the relaunch can rebuild without the labels.
3. `project-infra`, `core`: as `cleanup_stack_containers` today.
4. Nothing is force-killed before its stop timeout; the escalation and the
   30 s cap are the `graceful-shutdown` ones.

## Idempotent relaunch-on-demand (local serving)

- `publish_local` is already "start or reconcile". After a reap it finds no
  container and the reap record; it relaunches from the request (or, with
  no `runtime`, from the record) on the live source and returns `running`
  with the same URL. No error, no special call.
- `service_reload` on a reaped preview relaunches from the record (today it
  says `not_running: no preview to reload`).
- `service_status` on a reaped preview returns `state: "reaped"`,
  `reaped_at`, `reason: "idle:<budget>"`, `relaunch: "publish_local"`,
  `url` (the URL it will have again). `serving: false`, `route_ready: false`.
- `service_logs` on a reaped preview returns `state: "reaped"` and the
  retained tail if the reap kept one (last 64 KiB), else an empty tail — a
  success frame.
- A relaunch that needs a missing image goes through `ensure_image_exists`
  and inherits the image-retry contract: `state: "preparing"`,
  `retry_after_s` from `busy_retry_after_secs`, never a retry the end user
  sees.
- The forge's instructions (default-image welcome, `forge-quick-intro`)
  carry one sentence: "Idle containers get terminated — a web preview after
  3 h without requests, a forge after 30 min without activity. Calling
  `publish_local` again relaunches the preview with the current source."

## Announcing the reap

- Global: `GlobalEvent::GcReap { resource: "<class>", count, reason }` to
  every live lane ring (kind `gc.reap`, fields within the 1779-sq9g
  allowlist). One event per sweep per class, never per container, so a
  sibling learns that a reap happened and not what a sibling ran.
- Scoped: the owning lane's ring gets `container.reaped {name, class,
  idle_secs, budget_secs, relaunch}`; a lane started after the reap does not
  see it (session-only ring), which is why the reap record exists.
- Until `GlobalEvent` lands: the verdict line goes through
  `tillandsias-logging` as a `runtime-logging` "Container lifecycle logging"
  stop event with `reason=idle`.

## Tray

The icon does not change on a reap: blushing is reserved for container
creation and pups for finished work (`tray_icon_state_machine`). The single
status line may show the latest reap verdict ("reaped 1 idle preview
(3 h)") until the next status event replaces it. A relaunch triggered by
`publish_local` blushes like any creation.

## Cross-platform

- Linux rootless: `podman` as the user; the transient unit is
  `systemd --user`; owner liveness via `/proc`; runtime dir
  `$XDG_RUNTIME_DIR/tillandsias/`.
- macOS (Virtualization.framework guest) and Windows (WSL2): the guest
  headless runs the sweep; owner pid is the guest-side lane process (the
  host tray's pid is meaningless in the guest), so "owner gone" is "no
  control-wire session and no host heartbeat for the lane"; `core` orphan
  reaping in the guest is subsumed by 1560-73zh's power-off.
- Labels, the reap record and the status contract are identical on all
  three.

## Alternatives considered

- Reap previews with the lane (today's `cleanup_departed_lane`): rejected,
  the operator wants cheap containers to outlive a flaky agent session by
  hours.
- A persistent user service: rejected, a peer cannot commit operator spend;
  the transient unit arms per launch and vanishes with the last container.
- `--rm` on forges: rejected, exit-code and log retention for the agent's
  own diagnostics (`forge_logs`) need the container row until the reaper
  removes it.

## Operator rulings (2026-10-19)

1. **Browser windows are reaped with their lane.** A window has no idle clock of its own: an active browser app keeps its server busy, so a window whose server is idle is a forgotten window and is reaped with it. A development browser window is one of the most expensive things to leave running. `window_registry.rs` `is_idle_timeout` (24 h) is retired in favour of the lane's clock.
2. **The watchdog for tray-less CLI lanes is a transient `systemd --user` timer**, not a detached process. It must run confined under the project's SELinux policy: the target is properly hardened Linux hosts, so the unit and the sweep it runs need policy, not just a unit file.
3. **Infra containers (vault, proxy, router, inference) are measured first, then reaped if cheap.** Record each one's cold start-up time. Those that restart quickly on demand are reaped on the same idle rules, on the condition that every start-up sequence is idempotent. Until both the measurement and the idempotency are shown, they are left running.
