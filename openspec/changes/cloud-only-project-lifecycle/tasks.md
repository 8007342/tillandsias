# Tasks (ordered; each maps to a row that stays the unit of claim)

- [ ] T1 — **Mirror exported heads track upstream** (git-mirror-service; owner:
      the mirror's maintainer, after 1340-tzsx A1/A5): fast-forward-only sync of
      `refs/heads/*` from `refs/remotes/origin/*` on demand (`tillandsias --sync
      <project>` and a tray action) and on a cadence; a `sync-state` the forge
      can read (last sync time, cadence, per-ref behind/absent); accountability
      log lines. Closes 1338-tkfh's mirror half. Pre-fix: heads move only at
      startup and on a relay.
- [ ] T2 — **Relay records the pusher** (git-mirror-service; 1340-tzsx A5): one
      log line per ref transaction with principal, serial, key id.
- [ ] T3 — **Cloud-only project list** (tray-ux; pirria, in flight as 591-33s6
      and 997-e4v2): the remote list only, idempotent from remote state, paged
      overflow, the dead local-list scaffolding removed.
- [ ] T4 — **Forge seeds from any ref, and the workflow is named** (forge-welcome,
      join-the-fleet, initialize-bare-metal-host): the salvage-or-work-ref →
      sync → seed sequence documented where a worker looks; a litmus that seeds
      a forge from a `salvage/*` ref.
- [ ] T5 — **Host mount removal** (forge-as-only-runtime, cli-mode; 591-x7ws;
      after T1 and T4 so the replacement exists): `TILLANDSIAS_PROJECT_HOST_MOUNT`
      and `TILLANDSIAS_FORGE_HOST_MOUNT` removed from the launcher, the
      entrypoints, the podman client, the cheatsheets and their staged copies
      in one commit; the bind-mount audit scenario loses its exception.
- [ ] T6 — **Retire the host scanner and the mirror-to-host sync**
      (host-shell-architecture, git-mirror-service): the `~/src` watcher, the
      local project events, the working-copy fast-forward on push and the
      tray's startup sweep of host working copies are removed; the tray's
      startup sweep keeps only its mirror-side duties.
- [ ] T7 — **Forge acceptance of the lane** (1340-tzsx dogfood; T11 stays
      closed until it passes): the arms in the audited design, A2–A4.
