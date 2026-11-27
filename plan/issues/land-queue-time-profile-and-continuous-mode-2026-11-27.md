# Land-queue time profile and a continuous-queue design (2431-lprf), 2026-11-27

Filed by doris-windows from macuahuitl's run logs (runs 96–105, 8 runs carrying timing marks) and a read of
`scripts/land-queue.sh`.

## What the logs say

The marked phases, per candidate:

| phase | seconds |
|---|---|
| merge+door | 2–8 |
| preflight | 2–3 |
| plan-refresh | 2–3, but 60–63 on about one candidate in five |
| gate (full) | 470–710 |
| gate (plan-only) | 4 |
| post-gate+push | 10–12 |

The marked overhead outside the gate is under 30 s per candidate. So the "17 of 30 minutes outside the
gate" figure is not in-run overhead. It is time BETWEEN runs: a run starts only when the coordinator starts
one after a peer reports READY, and runs carry 1–6 candidates. The logs can't show this, because there is
no run start or end stamp, and trains and the gaps between candidates aren't marked.

## Packet 2431-lprf-a (p2): stamp runs, trains and the gaps between candidates

Add `timing:land-queue:run=<id>:start=<epoch>` and `:end=<epoch>:candidates=<n>:landed=<n>:evicted=<n>`
lines, plus `timing:land-queue:train=<id>:<phase>=<s>` for train-checks, train-gate and train-diagnose.
Also add a `gap=<s>` between the end of one candidate's last phase and the start of the next one's
merge+door. Then the profile can be computed rather than inferred: the time from a PR becoming READY
(its last push, or leaving draft) to the run that lands it, split into the wait before the run and the
time inside it. Predicted saving: none directly. It is the instrument that measures 2431-lprf-c.

## Packet 2431-lprf-b (p2): the 60 s plan-refresh is a correct rebuild, not a cache miss

The refresh key (`plan_refresh_key`) hashes the plan binary's dep-info inputs, plus Cargo.lock,
rust-toolchain.toml and the binary. Each of the three 60 s candidates changed a file under
`crates/tillandsias-plan/`:

- #1656: `src/safe_roots.rs`
- #1668: `tests/support/fixture_child.rs`
- #1676: `src/session_tokens.rs`

So the key changed and the rebuild was required: about 60 s is an incremental release build of the crate.
The only avoidable case is a tests-only change like #1668. build.rs reruns on `tests/` so that build-id
keeps matching source-revision, and that costs a full rebuild of the binary for a test edit. Possible
fix: hash `tests/` into a separately embedded stamp, so a tests-only change does not relink. Predicted
saving: about 60 s on roughly 1 candidate in 15. Small, so this packet records the finding; the fix is
optional.

## Packet 2431-lprf-c (p2, the big one): a continuous queue on macuahuitl — DESIGN, for the operator

**Goal.** A run starts when a landable PR appears (non-draft, into linux-next), not when the coordinator
notices a READY message. The wait between runs is the 17 minutes.

**Constraint (standing operator rule).** It must not poll fast: a polling cadence needs operator approval.
It reuses the existing systemd user unit machinery or flock, and adds no new crons.

**Design.**

1. **Event source: `gh event listen`, not a poll.** It holds one subscription and blocks until GitHub sends
   an event. Listen for `com.github.pull_request.state.changed.v1` (opened, ready_for_review, reopened)
   and new commits on non-draft PRs into linux-next. It exits on the first event, prints one JSON line, and
   the loop re-arms it. No request is made while nothing happens. The feature is in preview: gh says
   "may not be enabled for your account", so step 0 is to check it on macuahuitl's account. If it is not
   enabled, fall back to (3) only.
2. **Runner: a systemd user service, `tillandsias-land-queue-listen.service`.**
   - Built from `packaging/systemd/user/*.service.in`, like `tillandsias-cycle.service`.
   - Its ExecStart is a small loop: `gh event listen --resource <repo> --event ... --timeout 60m`, then
     on an event (or the timeout) `scripts/land-queue.sh`.
   - The queue's own lock already makes a second start a `skip:land-queue:in-flight`. After a run ends,
     the loop runs the queue once more before re-arming, so a PR that arrived mid-run is not stranded.
   - `Restart=on-failure`, with `RestartSec` set in minutes.
3. **Safety net: the `--timeout 60m` above.** The listen returns at least hourly even if an event was
   missed, and the queue runs once. That is the only time-based trigger. Its cadence (60 min proposed) is
   the operator's to approve, and so is turning the unit on at all.
4. **What does not change.** Merge order, the gate, eviction, trains, and "one landing at a time". The
   coordinator keeps the stop switch: `systemctl --user stop tillandsias-land-queue-listen`. A
   `TILLANDSIAS_LAND_QUEUE_PAUSED` file the loop checks before each run can hold the queue without
   stopping the unit.
5. **Measuring it.** With 2431-lprf-a in place: the median time from READY to landed, before and after.
   Predicted: the wait between runs (about 17 min per land) falls to the event delay plus whatever run is
   already in flight.

**Open questions for the operator.**

- May the listener run unattended on macuahuitl?
- Is the 60 min safety-net cadence acceptable?
- Should a run start on a draft leaving draft only, or also on every new push to a non-draft PR? The
  first is quieter; the second re-gates updated PRs sooner.
