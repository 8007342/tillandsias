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

**Correction (2026-11-27).** The first draft of this design said `gh event listen` could watch the
repository for new PRs. It was checked against `gh event listen --help` on doris, where gh is 2.106.0, and
that is wrong in two ways:

- The command is newer than macuahuitl's gh 2.97.0 ("unknown command \"event\"").
- `--resource` takes ONE pull request URL, so it cannot see a PR that does not exist yet.

Per-PR events it does offer: state.changed (merged, closed, reopened, ready for review, converted to
draft), head.changed (a push), review, merge-conflict and check-suite. Subscriptions expire after 24 h,
each account may hold only a limited number, and it is in preview.

**Options for the operator, no-timer options first.**

- **A. Re-run on exit — ALREADY THE BEHAVIOUR (measured 2026-11-27).** Pass 1 re-reads the queue before
  every candidate, including the pick after the last one (2143-z5uj). In a fixture where the stub gate adds
  #2 while #1, the only candidate, gates, unmodified trunk lands both in one invocation (landed=2), and
  three arrivals in a row land too (landed=3). So nothing that arrives during a run is stranded, and the
  ~17 min is time the queue sits IDLE. Only B or D addresses that. The original proposal, kept for the
  record: When a run ends, land-queue lists the non-draft PRs into
  linux-next once more. If any PR is new or updated since the run's start snapshot, it starts another run
  under the same lock. That is one check per run, not a timer. It drains everything that arrives while a
  run is busy, which is where most of the backlog builds. It cannot start an idle queue.
- **B. Peer-triggered start.** The READY report a worker already sends at the end of a step becomes the
  trigger: a handler on macuahuitl starts the queue under its lock, with no coordinator turn in between.
  It is event-driven, and reuses the existing fleet message channel (tillandsias-msg). This is the one
  option that starts an idle queue without a timer.
- **C. Per-PR listening for drafts.** For each open draft PR, `gh event listen --resource <pr>
  --event com.github.pull_request.state.changed.v1` wakes when it is marked ready. This needs gh >= 2.106
  on macuahuitl, depends on the preview feature, and is capped by the subscription limit and the 24 h
  expiry. It cannot see brand-new PRs opened as non-draft. It is fragile, so it is not recommended.
- **D. A slow timer.** A systemd user timer that runs land-queue every N minutes. It is the simplest, but
  it is the polling cadence the standing rule reserves for the operator. Offered only if A and B are not
  enough.

**Recommended: B.** A turned out to be existing behaviour, and B is the only no-timer option that starts an idle queue. Both reuse the existing lock
(`skip:land-queue:in-flight` on overlap) and add no cron or timer.

**What does not change.** Merge order, the gate, eviction, trains, and "one landing at a time". A
`TILLANDSIAS_LAND_QUEUE_PAUSED` file, checked before each self-started run, lets the coordinator hold the
queue.

**Measuring it.** With 2431-lprf in place: the median time from READY to landed, before and after.

**Open questions for the operator.**

- May B (a peer's READY message starts a run without the coordinator) be enabled?
- Is D wanted at all, and at what cadence?
