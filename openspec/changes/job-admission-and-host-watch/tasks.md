# Tasks: job-admission-and-host-watch (story 2094-65yz)

Nothing is built. The operator's rulings on the eight questions are recorded
in design.md section 10 (2026-11-17) and as an event on 2094-65yz.

Depends on `openspec/changes/local-job-watchdog`: 2081-v7qx (the watch
registry and rules) lands before anything here is built, and 2081-bdss
before any message is sent. That change's own seven questions were ruled
on 2026-11-17 (design.md section 10).

Order of pickup: ay52 → kgdj, mzap and y2bb (parallel) → wq8z → dyvk. The
five hardware packets are independent measurements and may run at any time
on a host of their kind. 9igs is independent of all of them.

- [x] 2094-65yz: operator review of the design and its eight questions;
      this change amended with the rulings (2026-11-17).
- [ ] 2094-ay52: the queue, rules only — `queue.submit`, `queue.status`,
      `queue.cancel`, `queue.list` on the lane socket; classes as data; the
      pure admission function; round-robin and the reserve rule; an admitted
      job registered as a watch; the `queue.*` index row and descriptions.
      Pressure is a fixture input.
- [ ] 2095-kgdj: affordances — every restriction in the descriptions,
      schemas and responses (design section 11); the required `idempotent`
      field and the run-once rule; one refusal shape with `reason`,
      `retry_after_seconds` and class limits; the affordance test; the
      bundle-splitting arm with an agent that reads only the tool list.
- [ ] 2095-kgdj, same PR: add the three sentences (queue heavy work; make it
      idempotent and bundle it; wait with `watch.wait`) to
      `images/default/config-overlay/mcp/forge-agent-guidance.md` and to the
      `forge-quick-intro` skill, so in-forge agents see them.
- [ ] 2094-mzap: pressure as an event — pressure-stall triggers and
      `memory.events` held without root; the three levels; stop one
      queue-started job and requeue it.
- [ ] 2095-wq8z: the last resort — with no queued job left, freeze (never
      kill) the forge holding the most memory, notify the operator, report
      `frozen`, thaw from the tray.
- [ ] 2094-y2bb: `until` conditions and the declared `retry` policy on a
      watch, with the built-in never-retried literals as data.
- [ ] 2094-dyvk: the host lane, the bridge subcommand, the `.mcp.json` row,
      host jobs in transient scopes with a ceiling, and `watch.wait`.
- [ ] 2094-s3ub: desktop with an Intel NPU and a discrete GPU — the
      placement table as data with its CPU row measured (threads, priority,
      context, resident size beside a running build); the NPU row wired to
      2081-4cpi's result.
- [ ] 2094-p3i3: Linux laptop with an XDNA2 NPU and an integrated GPU — the
      integrated-GPU row measured; the NPU row not taken (licence undecided).
- [ ] 2094-zzg9: Windows host with an XDNA2 NPU — the guest CPU row
      measured; the host-judge rows recorded as later.
- [ ] 2094-7t4f: Linux laptop with an integrated and a discrete GPU — the
      integrated row pinned to its device and measured with the discrete
      card busy.
- [ ] 2094-3r2k: Apple Silicon — the guest CPU row measured; Metal on the
      host later, behind its offline proof.
- [ ] 2095-9igs: the embedded-script ratchet — a counter that only falls
      over heredoc-to-interpreter sites in `.sh` and multi-line inline
      awk/jq/python bodies; ported blocks become files with real exit codes
      that emit log events a watch can read. Not part of this change's spec
      delta; listed because the watchdog reads what the ported files emit.
- [ ] Replace one `until`/`sleep` waiter under `scripts/` with a queued job
      in the PR that lands 2094-dyvk, and count the rest as backlog items.
- [ ] Make queueing mandatory for heavy commands in forges once the queue
      has proved itself (ruling 5); the measure of "proved" is recorded by
      2094-ay52's claimer and put to the operator.
- [ ] Sync the delta into `openspec/specs/` after `local-job-watchdog` has
      been synced, and archive this change once 2094-ay52, 2095-kgdj,
      2094-mzap and 2094-dyvk have passed on Linux.
