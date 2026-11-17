# Tasks: job-admission-and-host-watch (story 2094-65yz)

Nothing is built. The operator reviews design.md section 10 first. The
pressure cadence (question 1) needs their approval before 2094-mzap or
2094-dyvk is claimed.

Depends on `openspec/changes/local-job-watchdog`: 2081-v7qx (the watch
registry and rules) lands before anything here is built, and 2081-bdss
before any message is sent.

Order of pickup: ay52 → mzap and y2bb (parallel) → dyvk. The five hardware
packets are independent measurements and may run at any time on a host of
their kind.

- [ ] 2094-65yz: operator review of the design and its eight questions;
      amend this change with the rulings.
- [ ] 2094-ay52: the queue, rules only — `queue.submit`, `queue.status`,
      `queue.cancel`, `queue.list` on the lane socket; classes as data; the
      pure admission function; round-robin and the reserve rule; an admitted
      job registered as a watch; the `queue.*` index row and descriptions.
      Pressure is a fixture input.
- [ ] 2094-mzap: pressure as an event — pressure-stall triggers and
      `memory.events` held without root; the three levels; stop one
      queue-started job and requeue it; the notification when nothing is
      left to stop.
- [ ] 2094-y2bb: `until` conditions and the declared `retry` policy on a
      watch, with the built-in never-retried literals as data.
- [ ] 2094-dyvk: the host lane, the bridge subcommand, the `.mcp.json` row,
      host jobs in transient scopes with a ceiling, and `watch.wait`.
- [ ] 2094-s3ub: desktop with an Intel NPU and a discrete GPU — the
      placement table as data with its CPU row measured (threads, priority,
      context, resident size beside a running build); the NPU row wired to
      2081-4cpi's result.
- [ ] 2094-p3i3: Linux laptop with an XDNA2 NPU and an integrated GPU — the
      integrated-GPU row measured; the NPU row left blocked on order 543.
- [ ] 2094-zzg9: Windows host with an XDNA2 NPU — the guest CPU row
      measured; the host-judge rows recorded as blocked or, after the
      rulings, proved offline and measured.
- [ ] 2094-7t4f: Linux laptop with an integrated and a discrete GPU — the
      integrated row pinned to its device and measured with the discrete
      card busy.
- [ ] 2094-3r2k: Apple Silicon — the guest CPU row measured; Metal on the
      host measured and its offline proof made, after the ruling.
- [ ] Replace one `until`/`sleep` waiter under `scripts/` with a queued job
      in the PR that lands 2094-dyvk, and count the rest as backlog items.
- [ ] Sync the delta into `openspec/specs/` after `local-job-watchdog` has
      been synced, and archive this change once 2094-ay52, 2094-mzap and
      2094-dyvk have passed on Linux.
