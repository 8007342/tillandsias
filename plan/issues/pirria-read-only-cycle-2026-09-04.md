# pirria read-only cycle, 2026-09-04T10:10Z

- host: pirria (linux, floor tier, 4-core CachyOS)
- agent: `linux-pirria-claude-20260904t101011z`
- branch: `linux-next`, guard `ok:branch-linux-next`
- direction: convergence-velocity-milestone, v0.5
- outcome: **read-only — no claim, no implementation, nothing left `in_progress`**

## Why this cycle claimed nothing

`scripts/select-work-batch.sh linux` → `refused:no-plan-binary`.

That is not merely a degraded read path. §3 of `advance-work-from-plan` is
explicit that a status flip via `tillandsias-plan set-field` is the **only**
separation mechanism — not a claim event, not a lease id, not a work-queue
line. With no binary this host cannot flip status, therefore cannot claim,
therefore must not implement: doing so is precisely the 814-iyu7 failure (two
hosts implemented 798-tk7b six minutes apart, ~4h duplicated).

So the correct cycle here is read-only. Nothing was claimed, so nothing is
stranded and the reaper has nothing to collect.

## Assigned fallback: the cycle-metrics rung (1001-q3zf, landed 0cc1ea5a0)

The three lines, verbatim:

```
repeat: window=3h steps=0 top3=- source=absent
recur: window=7d runs=0 steps=0 top3=- source=absent
skippable: candidates=0 floor_ms=2000 min_runs=5 top3=- source=absent
```

The coordinating brief for this rung said pirria's gate "has been writing
[the timing log] for weeks", and that this host's `skippable:` line would be
the fleet's most valuable because its gate is the slowest.

**Both halves are false here, and it is one causal chain rather than three
defects:**

1. `metrics_default_log`, as called from `scripts/cycle-metrics.sh` where
   `TIMING_LOG` is assigned, resolves it to
   `$REPO_ROOT/.cache/metrics/tillandsias-timing.jsonl` — the
   `.git` branch is taken, so the `/tmp` fallback never applies. Neither file
   exists; `.cache/metrics/` is an empty directory created by the probe itself.
2. The emitters are `scripts/timing-log.sh`, driven by the build/test/litmus
   steps in `build.sh`, `scripts/local-ci.sh` and `scripts/run-litmus-test.sh`.
3. Every one of those requires cargo.

No toolchain → no gate run → no timing record has **ever** been written on this
host. The slowest gate in the fleet is also the one that has never emitted a
measurement, so it is invisible to exactly the rung built to find it.

**This is a consequence of the toolchain blocker, not an independent defect,
and should not be filed as one.** The corollary worth keeping: any floor-tier
measurement rung that depends on gate-emitted telemetry is unreachable on the
floor until the floor can run a gate. Designing floor instrumentation on top of
gate output will keep producing `source=absent` on the hosts it most wants to
measure.

Same root, same run: `verdict: attention:experts-never-called`,
`plan: plan_bin=absent`, `experts: source=absent`.

## Finding: a cargo-less host cannot record its own cycle outcome

§6.3 mandates a one-line outcome appended to
`plan/issues/linux-next-work-queue-2026-05-25.md`. That append was written,
committed, and **refused at push**:

```
plan-only lane: not applicable — 'plan/issues/linux-next-work-queue-2026-05-25.md'
  has status 'M' in the outgoing diff; only NEW issue captures qualify (full gate required)
✗ pre-push refused: ./build.sh --check has never run in this checkout
```

So the lane that exists to let plan-only work through accepts **new** files but
not **modifications**, and the mandated ledger append is a modification by
construction. The full gate it falls back to needs cargo. `--no-verify` is
forbidden by this skill's hard guardrails ("NEVER skip hooks").

Net effect: **a host with no toolchain is structurally unable to satisfy §6.3.**
It can do read-only work and it can report, but only by filing a *new* capture
(this file) instead of the ledger line the skill asks for. That is a workaround,
not compliance, and it fragments the host's history away from the queue a reader
would actually consult.

Worth a packet on its own terms — the fix shape is for the plan-only lane to
accept appends to work-queue ledgers (append-only, no deletions) with the same
validation it already applies to new captures, rather than requiring a compile
gate for a markdown line.

Related, same class, third and fourth instances of the cargo assumption after
`cycle-preflight.sh` and `check-capability-row.sh`:
`scripts/check-cheatsheet-tiers.sh` emits `cargo: command not found` as a
non-blocking commit-hook validation ERROR.

Also observed: all three sanctioned YAML validators from the §6 integration
gate (`tillandsias-policy`, `yq`, `ruby`) are **absent on this host**, and the
gate explicitly forbids substituting `python3`. No YAML was touched this cycle
so it did not bind, but any future cycle here that touches a `.yaml` cannot pass
the integration gate at all. Note this sits oddly against the previous push's
hook output, which reported "yq tier validated every pushed blob" — the hook
appears to reach a yq that is not on the interactive PATH. Not chased further;
flagged so the next reader does not conclude the two statements agree.

## Preamble state

- branch guard: `ok:branch-linux-next`
- agent identity: minted clean, `linux-pirria-claude-20260904t101011z`
- prior cycle: v56.9.2.1 release smoke landed `1f84f2922`, PASS end-to-end
  (see `smoke-e2e-findings-v56.9.2.1-2026-09-04.md`)

## Standing blocker

Rust toolchain absent on pirria since 2026-09-03. On the operator queue; not
actionable from this host. Until it is resolved every scheduled fire here ends
as a read-only cycle like this one.
