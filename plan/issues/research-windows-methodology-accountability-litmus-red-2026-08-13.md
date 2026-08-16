# methodology-accountability litmus: 5 red on windows, 1 of them intermittent

Filed 2026-08-13 (windows host, meta-orchestration cycle). Captured, not fixed —
this cycle's batch was elsewhere and none of these are caused by its changes
(verified by running the suite with the cycle's diff stashed).

`scripts/run-litmus-test.sh methodology-accountability --phase pre-build --size quick`
on this host, 20 tests executed:

| test | verdict | first observation |
|---|---|---|
| `litmus:methodology-accountability-shape` | FAIL | step 4 output is `bash: line 1: rg: command not found` — a **host tooling gap**, not a product defect. The step shells out to ripgrep, which is absent in the WSL builder distro. |
| `litmus:cycle-metrics-answer-rate-shape` | FAIL | not diagnosed |
| `litmus:cycle-flow-telemetry-shape` | FAIL | not diagnosed |
| `litmus:build-test-timing-telemetry-shape` | FAIL | not diagnosed |
| `litmus:loop-status-fragment-overlay` | FAIL | step 12/13, the stale-count negative control |
| `litmus:timing-telemetry-implausible-guard-shape` | **INTERMITTENT** | failed in one run of the suite and passed in the next two, same tree |

Two separate things are worth someone's time here, and they should not be
conflated:

1. **The ripgrep dependency.** A litmus step that invokes `rg` is testing the
   host's package set as much as the repo. Either vendor the check onto `grep`
   (which every lane has) or make the absence an explicit `SKIP: rg absent`
   rather than a FAIL — a red that means "this host lacks a tool" trains agents
   to read red as noise, which is how the genuinely red ones survive.

2. **The intermittent one.** `timing-telemetry-implausible-guard-shape` flipped
   verdict across runs on an unchanged tree. Per the meta-orchestration skill's
   own rule, an intermittent failure is a defect with a schedule, not noise, and
   the last time this host treated one as noise it cost two cycles (637-df4z
   closed mis-diagnosed, real cause found in 638-ehzi: two tests racing on
   `$HOME` and a shared fixture directory). The telemetry litmi all read
   per-host append logs under `/tmp`, which is exactly the shape that races.
   `target/convergence/check-logs.jsonl` is the place to start, not scrollback.

Not filed as plan packets: the four undiagnosed FAILs need one diagnosis pass
first, and filing four packets off an undiagnosed symptom would be the
"packet on a false premise" mistake 637-df4z already recorded.

## Update 2026-08-16 (windows, meta-orchestration cycle 2)

Re-measured on the instant subset (16 executed): **15/16 green**. Of the
2026-08-13 reds, `litmus:cycle-metrics-answer-rate-shape`,
`litmus:cycle-flow-telemetry-shape` and
`litmus:build-test-timing-telemetry-shape` now PASS on this host, and
`litmus:timing-telemetry-implausible-guard-shape` passed both runs tonight.

The one remaining red, `litmus:methodology-accountability-shape` step 4, has
CHANGED failure mode: the `rg` dependency is gone (the step now uses
`grep -rnIE`), and the step instead hits its 10s TIMEOUT — deterministically,
two suite runs in a row — while the identical command completes in 0.6-2.5s
standalone in native Git Bash. Diagnosis: it is the only step in the suite
that greps the full `crates/` tree, and on this host the runner executes
steps inside the WSL builder distro where the checkout is a /mnt/c 9p mount;
a recursive grep there is an order of magnitude slower. Fixed this cycle by
raising that step's `timeout_ms` to 60000 (the check is discoverability, not
latency; expected_behavior unchanged). If the step is red again after this,
it is a real discoverability regression, not the host.
