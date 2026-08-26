# Cross-host performance probe — the yoga (Silverblue) leg

- **Classification:** `research/`
- **Host:** yoga — AMD Ryzen AI 5 340 w/ Radeon 840M, 12 physical / 12 logical, 14 GiB, btrfs, Fedora Silverblue 44
- **Date:** 2026-08-25
- **Tree:** 4614 tracked files, 214 `.rs`, 23 workspace crates
- **Related:** order 890-nkdz (macbook, `cross-host-measurement-practice-lives-only-in-transcripts`) — currently on `osx-next` and NOT merged to `linux-next`
- **Orders touched:** 888-92iu (freshness litmus repetition), 795-5itp (framing)

## Why this file exists

The measurements below were produced over cross-session coordination and
recorded in a fragment on `osx-next`. Until that branch merges, a reader on
`linux-next` finds the conclusions cited and the numbers absent. The
capture obligation for this host's half is this host's, so this is that half,
in this host's own words, with the replicate counts and spreads that the
conclusions actually rest on.

## Method

`/usr/bin/time -p`, never a hand-rolled timer. Gate numbers are
`TILLANDSIAS_FORCE_CHECK=1` only — since order 765-tkq2 an unchanged tree
returns `ok:gate-fresh` in ~0.4s, so a mean over mixed memoised and forced
runs measures how many no-op runs a host happened to do.

Cargo probe: warm twice with `cargo check --workspace --all-targets` and
discard, then time 20 iterations of the same no-op.

## Numbers

**Local gate, forced.** n=15, mean **28.6s**, range **13.4–40.4s**.
Sorted: 13.4 25.6 27.4 28.3 28.4 29.5 30.3 30.5 31.7 32.0 32.7 35.2 40.3 40.4.
A 3x spread on one host — quote the range, never the mean alone.
(One further 3.2s run took the plan-only push lane and is not a gate run.)

**Where that gate time goes.** Mean over 12 forced runs, slowest first:

| ms | step |
| ---: | --- |
| 9034 | plan archiver preserves the ready set (831-ezea) |
| 6100 | plan ledger tests (`cargo test -p tillandsias-plan`) |
| 1824 | surface parity railguard fixture |
| 1726 | plan binary resolution probe |
| 1454 | groundtruth mutable status pins |

Archiver plus ledger tests are **15.1s of 28.6s — 53% ledger work, not
compilation.** calmecacpilli independently measured the archiver at ~45% of a
107–122s gate on another immutable host: different absolute scale, same shape.

**Cargo no-op, 20 iterations, native host rustup.** n=5:

| real | user | sys | user share |
| ---: | ---: | ---: | ---: |
| 3.59 | 2.89 | 0.72 | 80.1% |
| 3.39 | 2.72 | 0.69 | 79.8% |
| 3.40 | 2.68 | 0.74 | 78.4% |
| 3.43 | 2.72 | 0.73 | 78.8% |
| 3.43 | 2.73 | 0.72 | 79.1% |

Means: real 3.448 (**172.4 ms per no-op**), user 2.748, sys 0.720,
user share **79.2%** (range 78.4–80.1).

**Toolbox boundary.** The same probe inside the `tillandsias-builder` podman
toolbox that `./build.sh` re-execs into on Silverblue:

- cargo no-op: **+2.8%** (n=3; native 3.60/3.41/3.46, toolbox 3.62/3.56/3.58).
  Ranges **overlap** — treat as small, possibly noise.
- fork+exec floor (`/bin/true` x1000): **+31%** (n=5; native 0.32/0.30/0.30/0.31/0.30,
  toolbox 0.40/0.39/0.39/0.42/0.41). Ranges **do not overlap** — a real effect.

Both figures with their n and spread, or neither. **Anything that spawns
per-file pays the 31%, not the 2.8%.**

**Spawn costs, native.** `/bin/true` x1000 → **0.306 ms/spawn** (n=5).
`sha256sum` x1000 → 0.80 ms/spawn, so hash work ≈ **0.494 ms**.

## What these numbers killed

- **The warm-toolbox velocity lever for immutable hosts.** Premise was a
  131.9s cold-toolbox construction cost. Against a ~2.8% steady-state boundary
  cost, optimising rebuild *frequency* optimises a rare event whose alternative
  is nearly free. Reported as a non-finding; no packet filed. The immutable-host
  lever is the ledger work above, which is calmecacpilli's to own.
- **A shasum-dispatch cost I proposed to macbook.** I reasoned from 4614 files
  to "potentially minutes"; order 675-dkif removed the per-file spawn loop in
  August, so there was nothing left to multiply. macbook measured 90ms across
  the whole tree and declined to file.

## Corrections to my own reporting, recorded deliberately

Both toolbox figures were first published at **n=1** and both were wrong: I
reported +5% and +25%, the replicated values are +2.8% and +31%. My single
native cargo trial was the fastest of its three and my single native spawn
trial the slowest of its five, so both n=1 draws landed in the direction that
made the two regimes look **more alike** than they are. The n=1 pair also
travelled to three hosts via the coordinator and became "the container
boundary costs almost nothing" before it was corrected.

Separately, I replicated those totals while leaving the **user/sys components**
at n=1 — on the very trial whose total I had just discredited. macbook caught
it. The components turned out to be a fair draw even though their total was an
outlier, which is the non-obvious part: **replicating a total tells you nothing
about whether its components were a fair draw, and vice versa.**

Both replications cost under two minutes each, against more than an hour of
propagation.
