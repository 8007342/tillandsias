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

**Cargo no-op, 20 iterations, native host rustup.**

SUPERSEDED — the n=5 set first recorded here was NOT QUIESCENT. This host was
merging `origin/linux-next` every few minutes, so cargo re-checked genuinely
changed crates and some trials were measuring compile work rather than
fingerprint traffic. Its 6% spread (3.39–3.60) was the signature. macbook
caught it after their own numbers failed the same way.

Quiescent re-run, HEAD hashed before and after and verified unmoved
(`60b4e0d923f0b7eb13cb3f06a41590db41fb5510`), clean worktree, n=3:

| real | user | sys | CPU% |
| ---: | ---: | ---: | ---: |
| 3.35 | 2.71 | 0.66 | 100.6 |
| 3.41 | 2.75 | 0.68 | 100.6 |
| 3.40 | 2.73 | 0.69 | 100.6 |

Means: real 3.387 (**169.3 ms per no-op**), user 2.730, sys 0.677,
user share **80.1%**. Spread 1.8% (six ulps of the instrument's 0.01s
resolution, so a real signal, not rounding).

The contaminated figures were 172.4 ms / user 2.748 / sys 0.720. The
correction is small in magnitude and large in what it invalidates: a
replicated number produced under drifting conditions converges on the average
of whatever was happening, while carrying the authority of replication.

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

## The cross-host result this leg fed into

Final table, every native leg quiescent and verified (macbook assembled):

| lane | ms/no-op | CPU share | n | spread |
| --- | ---: | ---: | ---: | --- |
| darwin M5 / APFS | 161.0 | 65.6% user | 3 | ≤0.31% (instrument floor) |
| yoga bare metal | 169.3 | 80.1% user | 3 | 1.8% |
| yolanda WSL2 ext4 | 238.2 | 101.1% | 3 | 1.1% |
| yolanda WSL2 9P bridge | 9185.0 | **15.0%** | 3 | 3.0% |

**The isolating measurement is 38.6x**, bridge vs ext4 on ONE machine with one
variable. The WSL2 *lane* is not slow — ext4 is 1.41x this host — the 9P
bridge is. And the strongest single number anyone produced is yolanda's
**15.0% CPU**: 85% of that run's wall time was not CPU at all. It is
believable without a baseline because it is a statement about one
measurement's internal structure rather than a ratio between hosts — a ratio
is wrong if either host is wrong; "85% of this run was not CPU" can only be
wrong if that run was wrong.

**The one result that never moved** across n=1, contaminated n=5/n=6, and
verified-quiescent n=3: darwin's sys is ~60% higher and its user ~25% lower
than this host's, with user shares 65.6% vs 80.1%. Every magnitude in this
exercise was corrected at least once; only the shape held.

## Two rules this leg earned

- **Replication is only valid under a held condition.** Replicating while the
  condition drifts converges on the average of whatever you were doing, and
  wears the authority of a replicated number while doing it — strictly worse
  than n=1, which carries no false confidence. macbook's, after they replaced
  a clean n=1 with an average of contaminated trials and cited it as a
  replication lesson. It supersedes rather than accompanies "replicate before
  a number travels": that rule is necessary and insufficient.
- **Report your instrument's resolution as a percentage of the measurement,
  and never claim a spread below it.** macbook's reported "0% spread" was
  three identical two-decimal readings of a 3.22s value — one ulp is 0.31%, so
  the honest claim is "agreed to within the resolution limit". Left
  unqualified it would have sent the next Linux host hunting contamination
  behind a 1.8% spread that is a real property of its hardware.

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
