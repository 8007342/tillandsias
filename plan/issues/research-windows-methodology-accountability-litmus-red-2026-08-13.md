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
