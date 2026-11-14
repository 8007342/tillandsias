# Tasks: local-job-watchdog (story 2081-z7sh)

Nothing is built. The operator reviews design.md section 10 first; the
cadence in section 3 needs their approval before 2081-v7qx is claimed.

Order of pickup: v7qx → ic4j and bdss (parallel) → ngd8 → bgh8 → fqw3.
4cpi is independent research and may run at any time.

- [ ] 2081-z7sh: operator review of the design and its seven questions;
      amend this change with the rulings.
- [ ] 2081-v7qx: the hands, rules only — `watch.register`, `watch.status`,
      `watch.cancel`, `watch.list` on the lane socket; the registry,
      persisted; exit events and the one deadline timer; the rules table;
      restart by the declared argv within the budget. No model. Ambiguous
      episodes escalate.
- [ ] 2081-ic4j: the `watch.*` row in the host tool index and the tool
      descriptions as written in design.md section 7; the forge instructions
      and the `forge-quick-intro` skill name `watch.register` for long jobs.
- [ ] 2081-bdss: escalation and done messages — the lane notification, the
      lane inbox with its receipt, the desktop sentence; once per episode.
- [ ] 2081-ngd8: the labelled set of bundles (from the 2026-11-13 render
      batch's failure shapes) and each model tier's score, latency and
      memory on CPU; names the default tier or says none passes.
- [ ] 2081-bgh8: the judge lane — no network, no credential, read-only, a
      UNIX socket, the schema-bound answer, the pinned model; enabled only
      for a tier 2081-ngd8 passed.
- [ ] 2081-fqw3: GPU placement that never evicts and never queues; the
      judge listed in `gpu.status` while loaded; CPU threads and priority.
- [ ] 2081-4cpi: the Intel NPU compiles and runs a pinned model from a
      rootless container on macuahuitl, with tokens per second against CPU;
      or a record of what blocks it. Feeds orders 481, 542 and 543.
- [ ] Add "a lane with a live watch is active" to
      `openspec/changes/idle-container-reaper` in the PR that lands
      2081-v7qx.
- [ ] Sync the delta into `openspec/specs/` and archive this change once
      2081-v7qx, 2081-ic4j and 2081-bdss have passed on Linux.
