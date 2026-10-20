# Proposal: idle-container-reaper

Row `1800-465n` (epic) and its six slices `1799-haat`, `1799-qgu5`,
`1799-xdcx`, `1799-mvmc`, `1799-dav6`, `1799-6yyp`.

## Why

On 2026-10-19 a terminal running a CLI lane was killed uncleanly. The
launcher process died with it, and the containers it had created — the forge,
its git mirror, the web preview it had published — stayed up with nobody
attached and nothing scheduled to notice. The operator's requirement
(verbatim in essence):

> Make sure our infrastructure includes the necessary watchdogs and services
> to gracefully shut down leftover containers when idling after a while. Let
> agents launching sibling web containers know that "idle containers get
> terminated". Serving local content must then become an idempotent service:
> a terminated container is just relaunched on demand and serves new content.
> Grace period at least 30 minutes; for cheap containers like baby web
> containers much longer, like 3 hours. There might already be services and
> watchdogs sprinkled in a few places, but that doesn't mean the requirement
> is fulfilled.

The survey (design.md, "What exists") confirms the last sentence. Every
cleanup the tree has today runs **from the launcher's own exit path** or
**from the tray's own shutdown**: `cleanup_shared_stack_if_no_running_forge`,
`cleanup_departed_lane`, `cleanup_stack_containers`, the tray startup sweep
(`tray-ux` "Stale container cleanup"). When the launcher is killed, none of
them runs. The one idle clock in the tree (`WindowRegistry::is_idle_timeout`,
24 h) has no caller outside its own tests. No container carries an idle
budget, an owner, or a class label. No log event says a reap happened.

## What Changes

- **ADDED** capability `container-idle-reaper`: every container Tillandsias
  creates belongs to a class with a declared idle budget and an idle
  definition; a host watchdog that outlives any one launcher sweeps the
  classes, detects orphans (owner gone), and stops idle containers through a
  graceful sequence; one sweep is idempotent and lock-protected.
- **MODIFIED** `local-web-preview` "Existing MCP lifecycle contract": a
  reaped preview is a defined `state: "reaped"` in `service_status` and
  `service_logs`, never an error; `publish_local` and `service_reload`
  relaunch it from its recorded labels and serve the current source. The
  forge's instructions tell agents that idle containers are terminated.
- **ADDED** `runtime-diagnostics-stream` "Reaps are announced as curated
  global events": every reap publishes a `gc.reap` `GlobalEvent` to all live
  lanes and a scoped `container.reaped` event to the owning lane's ring.
- **ADDED** `tray-progress-and-icon-states` "A reap never blushes": the icon
  does not change on a reap; the single status line may carry the latest
  reap verdict.

## Impact

- `crates/tillandsias-headless/src/main.rs` — class table next to
  `SHARED_STACK_SCOPES`, launch labels, the `[liveness]` supervisor gains the
  sweep, a new `--internal-reap-sweep` verb.
- `crates/tillandsias-headless/src/local_web_preview.rs` — reap record,
  `state: "reaped"`, relaunch from labels in `publish_local`/`reload_inner`.
- `crates/tillandsias-router-sidecar/` — per-route last-request timestamp on
  the control socket (the preview class's idle signal).
- `crates/tillandsias-headless/src/mcp_socket.rs` — lane activity clock;
  `gc.reap` producer once `forge_diagnostics::GlobalEvent` lands
  (1779-sq9g).
- `images/default/` forge instructions, `forge-quick-intro` skill text.
- `scripts/` — a Lua/shell fixture and a litmus binding.

Non-goals: changing the stop semantics of the shared stack while the tray
runs (vault, proxy, router, nix-cache stay `Core`); image eviction; changing
browser-window lifetimes beyond driving the existing clock.

## Follows

Log-awareness alignment (`gc.reap` as a typed `GlobalEvent`, the lane ring)
is specified by `openspec/changes/forge-diagnostics-scope/` and row
`1779-sq9g`. Slice `1799-dav6` depends on it and is filed as such; until it
lands the reaper logs its verdict line through the existing runtime logger
and nothing else.
