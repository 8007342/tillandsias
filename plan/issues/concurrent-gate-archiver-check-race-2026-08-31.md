# Concurrent gates corrupt each other through the archiver's check helper

Filed 2026-08-31 from linux/pirria, at macuahuitl's direction, after the race
was first mistaken for a trunk break during the v0.4.260830.5 smoke.

### Work Packet: archiver/concurrent-check-fixed-path-race

- id: `archiver/concurrent-check-fixed-path-race`
- owner_host: any
- capability_tags: [testing, release]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260830.5`, incidentally
- evidence:
  - observed failure: `scripts/archive-plan-packets-check.rb: No such file or directory @ rb_check_realpath_internal`, followed by `[build] the plan archiver would CHANGE THE READY SET, orphan events, or leave archived rows unanswerable — do not sweep` — i.e. the gate reports a **ledger-integrity verdict** for what is actually a missing-file race.
  - `scripts/archive-plan-packets.sh:97` generates the helper at a FIXED path in the working tree: `sed 's|plan/|plan_tmp/|g' scripts/archive-plan-packets.rb > scripts/archive-plan-packets-check.rb`
  - `scripts/archive-plan-packets.sh:88` (`_archiver_cleanup`, trapped on `EXIT INT TERM` at :93) deletes that same fixed path, along with `plan_tmp`, `plan_tmp_bak`, `plan_tmp_*.txt`
  - confirmed race window on this host: a stray `build.sh --check` (PID 1340530) survived a killed background task; its trap fired while a second, foreground `--check` was between generation (:97) and use (:182), deleting the file out from under the running gate. `pgrep -af build.sh` showed the stray; killing it made the identical gate pass in 154s.
- repro:
  - run two `./build.sh --check` invocations concurrently on one checkout, or kill one mid-run while a second is between `archive-plan-packets.sh:97` and `:182`
- next_action: >
    Generate the check helper into a per-run path — `mktemp` under `target/`,
    or a name keyed by PID — and scope `_archiver_cleanup` to that run's own
    path. `plan_tmp`, `plan_tmp_bak` and `plan_tmp_*.txt` share the same
    fixed-path exposure and should move with it. A PID/mktemp key also fixes
    the asymmetric case observed here, where the trap fires from the LOSING
    run and destroys the WINNER's file.
    Consider separately whether a missing helper should be able to surface as
    a ledger-integrity verdict at all: the operator-visible message accused the
    plan archiver of corrupting the ready set, which sent the first reader
    (me) looking for a trunk break. A missing-file condition should report
    itself as one.
- events:
  - type: discovered
    ts: `2026-08-31T02:04:26Z`
    agent_id: `linux-pirria-claude-20260831t020425z`
    host: linux

## Why this is trunk-worthy and not one host's mistake

The stray process was mine, and I reported it as self-inflicted rather than as
a trunk break. macuahuitl's ruling is that the underlying exposure is not:
**any** two concurrent gates on one checkout corrupt each other through this
fixed path, and tonight demonstrated that hosts do in fact run background gates
they have forgotten about — a killed task here, racing pushes on macuahuitl.
The precondition is not exotic, and the failure it produces accuses the ledger
rather than naming the race, so the next host to hit it will also start by
looking in the wrong place.
