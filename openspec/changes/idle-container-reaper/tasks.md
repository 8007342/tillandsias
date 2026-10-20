# Tasks: idle-container-reaper (epic 1800-465n)

Order of pickup: haat → qgu5 → xdcx; mvmc may run in parallel with xdcx;
dav6 waits for 1779-sq9g's `GlobalEvent`; 6yyp last.

- [ ] 1799-haat: `CONTAINER_CLASSES` table and launch labels
      (`tillandsias.class`, `.owner-pid`, `.launched-at`, `.lane`) on every
      container we mint; the per-lane activity clock persisted under the
      runtime dir; the router's `route_activity` query.
- [ ] 1799-qgu5: `reap_sweep()` — classify, idle/orphan decision, graceful
      stop per class, reap record for previews, one verdict line per
      decision; `tillandsias --internal-reap-sweep [--dry-run]`.
- [ ] 1799-xdcx: the watchdog that outlives the launcher — the `[liveness]`
      supervisor calls the sweep; CLI lane launches arm the transient
      `systemd --user` timer (or the detached `--loop` fallback); guest
      headless runs it on macOS/Windows.
- [ ] 1799-mvmc: idempotent local serving — `state: "reaped"` in
      `service_status`/`service_logs`, relaunch-from-record in
      `publish_local` and `service_reload`, the "idle containers get
      terminated" sentence in the forge instructions.
- [ ] 1799-dav6: `gc.reap` global event + lane-scoped `container.reaped`
      through `forge_diagnostics::GlobalEvent` (after 1779-sq9g); tray
      status line carries the latest reap verdict; no icon change.
- [ ] 1799-6yyp: live acceptance — kill a CLI lane's terminal uncleanly;
      with budgets shortened by env, the forge, its git mirror and the
      preview are reaped in class order; `publish_local` from a new lane
      relaunches the preview and serves an edited file; litmus binding.
- [ ] Sync the deltas into `openspec/specs/` and archive this change once
      1799-6yyp passes on Linux and on one guest platform.
